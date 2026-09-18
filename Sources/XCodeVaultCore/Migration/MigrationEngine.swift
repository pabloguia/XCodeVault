import Foundation

/// The transactional copy engine behind `externalize` (cold storage) and `restore`
/// (MIGRATION_ENGINE.md). One migration = copy a catalog path to `<vault>/XCodeVault/<category>/…`
/// (or back), verify beyond file counts, and only ever remove the source on an explicit,
/// separate, re-verified step. Every transition is journaled under one operation id so a
/// crash leaves a resumable/abortable record that `doctor` and `migration status` surface.
public struct MigrationPlan: Sendable, Codable, Equatable {
    public enum Direction: String, Sendable, Codable { case externalize, restore }
    public var operationID: String
    public var direction: Direction
    public var categoryID: String
    public var source: String
    public var destination: String  // final path of the copy
    public var vaultUUID: String?
    public var sourceBytes: UInt64
    public var sourceFiles: UInt64
    public var deepVerify: Bool  // SHA-256 (always for non-regenerable data)
    public var warnings: [String]
}

public struct MigrationOutcome: Sendable, Codable, Equatable {
    public var plan: MigrationPlan
    public var verification: TreeVerifier.Report
    public var sourceRemoved: Bool
}

public struct MigrationError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct MigrationEngine: Sendable {
    public var runner: CommandRunning
    public var journal: Journal
    public var verifier: VaultVerifier
    public var home: String
    public var isXcodeRunning: @Sendable () -> Bool
    /// Test hook: called between COPY and VERIFY (fault injection).
    public var afterCopy: (@Sendable (MigrationPlan) throws -> Void)?
    /// Test hook: called after the source has been renamed aside, before the final verify+delete.
    public var afterRenameAside: (@Sendable (String) throws -> Void)?
    /// The volume identity of the filesystem containing a path. Injected for the same reason
    /// `isMountPoint` is injected elsewhere in this codebase: a test's vault is a directory in
    /// `/tmp` with an invented UUID, and the real lookup correctly answers with the boot volume's.
    public var volumeUUIDAt: @Sendable (String) -> String?

    public init(
        runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal(), verifier: VaultVerifier = VaultVerifier(),
        home: String = NSHomeDirectory(), isXcodeRunning: @escaping @Sendable () -> Bool = CleanExecutor.xcodeIsRunning,
        afterCopy: (@Sendable (MigrationPlan) throws -> Void)? = nil, afterRenameAside: (@Sendable (String) throws -> Void)? = nil,
        volumeUUIDAt: @escaping @Sendable (String) -> String? = MountStatus.volumeUUID(at:)
    ) {
        self.runner = runner; self.journal = journal; self.verifier = verifier; self.home = home
        self.isXcodeRunning = isXcodeRunning; self.afterCopy = afterCopy; self.afterRenameAside = afterRenameAside
        self.volumeUUIDAt = volumeUUIDAt
    }

    /// Journal phases; `abort` refuses anything at or past VERIFIED because the vault copy may be
    /// the only complete copy by then (crash during CLEANUP).
    static let phasesWhereAbortIsUnsafe: Set<String> = ["VERIFIED", "CLEANUP", "DONE"]

    // MARK: PREFLIGHT + PLAN

    /// Plans externalizing one catalog path into a verified vault volume.
    public func planExternalize(categoryID: String, source: String, vaultRef: String) throws -> MigrationPlan {
        guard let c = StorageCatalog.category(categoryID) else { throw MigrationError("Unknown category \(categoryID).") }
        guard c.allowedStrategies.contains(.coldStorage) else {
            throw MigrationError("\(c.name) has no coldStorage strategy (outcome: \(c.outcomeLabel)). Nothing is moved.")
        }
        try refuseIfInterrupted()
        let (vault, vaultDir) = try verifier.resolveUsable(vaultRef)
        try preflightSource(source, category: c)
        let source = try PathSafety.canonicalize(source)
        let dest = vaultDir + "/" + c.id + "/" + (source as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: dest) {
            if let leftover = try leftoverPartialCopies().first(where: { $0.paths[1] == dest }) {
                throw MigrationError(
                    "Destination \(dest) holds the partial copy of failed migration \(leftover.id). Run `migration abort \(leftover.id)` to remove it, then retry."
                )
            }
            throw MigrationError("Destination \(dest) already exists. Verify or remove it first; the engine never merges into existing data.")
        }
        // No `isLowerBound` check here: `preflightSource` above now refuses that first, and two
        // checks with different wording for one condition read as two conditions.
        let usage = DiskUsage.measure(source) ?? .zero
        let free = MountStatus.space(at: vaultDir)?.free ?? 0
        guard free > usage.allocatedBytes + 1_000_000_000 else {
            throw MigrationError("Vault has \(ByteCount.format(free)) free; need \(ByteCount.format(usage.allocatedBytes)) plus headroom.")
        }
        var warnings: [String] = []
        if c.regenerability == .nonRegenerable {
            warnings.append("\(c.name) is non-regenerable: deep (SHA-256) verification is mandatory and the source is never removed automatically.")
        }
        if let fs = MountStatus.filesystem(containing: vaultDir), fs.ignoresOwnership {
            warnings.append("Vault volume ignores ownership; owners will not be preserved.")
        }
        return MigrationPlan(
            operationID: UUID().uuidString, direction: .externalize, categoryID: c.id, source: source, destination: dest,
            vaultUUID: vault.volumeUUID, sourceBytes: usage.allocatedBytes, sourceFiles: usage.fileCount,
            deepVerify: true, warnings: warnings)
    }

    /// Plans restoring a vault copy back to its original location.
    public func planRestore(categoryID: String, vaultRef: String, name: String, to destination: String) throws -> MigrationPlan {
        guard let c = StorageCatalog.category(categoryID) else { throw MigrationError("Unknown category \(categoryID).") }
        // The same gate `planExternalize` applies, and for a sharper reason: containment here is a
        // prefix test against `pathTemplates`, which for some categories is a whole live tree owned
        // by a daemon (the CoreSimulator device set). Without this, a hand-made directory in the
        // vault could be restored *into* that tree at a canonical path — our own engine manufacturing
        // the shadow data rule 6 exists to prevent. Nothing may be restored into a category that was
        // never eligible to leave.
        guard c.allowedStrategies.contains(.coldStorage) else {
            throw MigrationError("\(c.name) has no coldStorage strategy (outcome: \(c.outcomeLabel)) and cannot be a restore destination. Nothing is written.")
        }
        try refuseIfInterrupted()
        let (vault, vaultDir) = try verifier.resolveUsable(vaultRef)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw MigrationError("Invalid vault entry name.") }
        let source = vaultDir + "/" + c.id + "/" + name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            throw MigrationError("\(source) does not exist in the vault.")
        }
        guard c.containsPath(destination, home: home) else {
            throw MigrationError("\(destination) is not a path of \(c.name).\(c.containmentShapeHint) Nothing is written.")
        }
        let destination = try PathSafety.canonicalize(destination)
        var dst = stat()
        if lstat(destination, &dst) == 0 { throw MigrationError("\(destination) already exists; refusing to overwrite. Move it aside first.") }
        let parent = (destination as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw MigrationError("\(parent) is not writable.") }
        let usage = DiskUsage.measure(source) ?? .zero
        let free = MountStatus.space(at: parent)?.free ?? 0
        guard free > usage.allocatedBytes + 1_000_000_000 else {
            throw MigrationError("Only \(ByteCount.format(free)) free at \(parent); need \(ByteCount.format(usage.allocatedBytes)) plus headroom.")
        }
        return MigrationPlan(
            operationID: UUID().uuidString, direction: .restore, categoryID: c.id, source: source, destination: destination,
            vaultUUID: vault.volumeUUID, sourceBytes: usage.allocatedBytes, sourceFiles: usage.fileCount, deepVerify: true, warnings: [])
    }

    func preflightSource(_ source: String, category: StorageCategory) throws {
        var st = stat()
        guard lstat(source, &st) == 0 else { throw MigrationError("\(source) does not exist.") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw MigrationError("\(source) is not a directory (symlink?). Fix with doctor first.") }
        guard !MountStatus.isMountPoint(source) else { throw MigrationError("\(source) is a mount point; refusing.") }
        // `containsPath`, not a prefix test against `pathTemplates`: for a per-device category the
        // templates name the enclosing device set, so a prefix test accepted the set, every device
        // root, and every app container inside them as "a path of this category".
        guard category.containsPath(source, home: home) else {
            throw MigrationError("\(source) is not a path of \(category.name).\(category.containmentShapeHint)")
        }
        let canonical = try PathSafety.canonicalize(source)
        let forbidden = CatalogRules.neverSymlink.compactMap { try? PathSafety.canonicalize($0.expandingTilde(home: home)) }
        guard !forbidden.contains(canonical) else { throw MigrationError("\(source) is a protected directory.") }
        if let u = DiskUsage.measure(source) {
            if !u.skippedMountPoints.isEmpty {
                throw MigrationError("\(source) contains mount points (\(u.skippedMountPoints.joined(separator: ", "))); refusing.")
            }
            // `planExternalize` has refused a partially unreadable tree since M3, but this function —
            // the one `removeSource` calls immediately before it deletes — did not, so a permission
            // change arriving after the plan was made was never noticed on the path that matters
            // most. `TreeVerifier` now reports unreadable entries as mismatches too; this is the
            // cheaper check that stops the operation before any of that work is done.
            if u.isLowerBound {
                throw MigrationError("Parts of \(source) are unreadable; refusing to act on a tree we cannot fully read.")
            }
        }
    }

    func refuseIfInterrupted() throws {
        let interrupted = try journal.interrupted().filter { $0.kind == .migration }
        guard interrupted.isEmpty else {
            throw MigrationError(
                "An earlier migration was interrupted (\(interrupted.map(\.id).joined(separator: ", "))). Run `migration status` and abort or complete it before starting another."
            )
        }
    }

    // MARK: COPY → VERIFY

    /// Re-asserts, at the moment of use, that the vault volume is still the volume under the path
    /// this operation is about to write to or read from.
    ///
    /// `resolveUsable` runs at plan time, in `removeSource` and in `resume` — but not around the one
    /// step that writes the bytes, which can run for many minutes. When an enclosure sleeps or is
    /// pulled mid-copy, macOS can leave `/Volumes/<name>` behind as an ordinary directory: `ditto`
    /// goes on writing into the **internal disk** at a path that reads like the drive, VERIFY then
    /// compares the source against that local copy and passes, and the journal records VERIFIED.
    /// That is CLAUDE.md rule 6's shadow data, manufactured by the engine that exists to prevent it.
    /// `removeSource` still refuses afterwards — the vault reads `.ambiguous` — so it was never data
    /// loss; it was a full duplicate of the data on the disk the operation was freeing.
    ///
    /// `volumeUUID(at:)` answers about the volume *containing* the path, which is exactly what is
    /// wanted: if the mount is gone, the answer is the boot volume's UUID and the comparison fails.
    /// Its own documentation describes this use — "is the volume I verified a moment ago still the
    /// volume under my feet?" — and until now nothing asked it.
    ///
    /// **Fails closed**: an identity that cannot be read at all refuses.
    func assertVaultVolumeStillPresent(_ plan: MigrationPlan, before phase: String) throws {
        // Not `return`. `MigrationPlan` is a public struct with public vars and `copyAndVerify` is
        // public API, so a plan can arrive without a vault UUID; skipping the check there would be
        // the only fail-open path in a function documented as failing closed.
        guard let expected = plan.vaultUUID else {
            throw MigrationError("This migration plan names no vault volume; refusing to copy without being able to confirm the destination volume.")
        }
        // Externalizing writes to the vault; restoring reads from it.
        let side = plan.direction == .externalize ? plan.destination : plan.source
        // Canonicalize first. `fileExists` resolves symlinks; `MountStatus.volumeUUID` passes
        // FSOPT_NOFOLLOW and does not. Without this, a symlink under the vault directory pointing
        // into internal storage made the probe stop at the link, read the vault's UUID and pass —
        // and then `createDirectory`/`mkdir` resolved the same link and wrote to the internal disk.
        var probe = (try? PathSafety.canonicalize(side)) ?? side
        while !FileManager.default.fileExists(atPath: probe) {
            let parent = (probe as NSString).deletingLastPathComponent
            guard parent != probe, !parent.isEmpty else { break }
            probe = parent
        }
        // `PathSafety.canonicalize` realpaths the parent and re-appends the last component verbatim,
        // so the two still disagreed at exactly one place: a symlinked *final* component. The walk
        // above ends on something that exists, so resolve that fully.
        probe = URL(fileURLWithPath: probe).resolvingSymlinksInPath().path
        guard let actual = volumeUUIDAt(probe) else {
            throw MigrationError("Cannot read the volume identity at \(probe) before \(phase); refusing rather than guessing.")
        }
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw MigrationError(
                "The vault volume is not mounted at \(probe) before \(phase): expected \(expected), found \(actual). "
                    + "Refusing — continuing would write to the internal disk under a path that reads like the drive.")
        }
    }

    /// Executes COPY and VERIFY. Never touches the source. On any failure the partial copy is
    /// removed (it is ours) and the journal records `failed`.
    public func copyAndVerify(_ plan: MigrationPlan) throws -> MigrationOutcome {
        let op = plan.operationID
        try journal.record(
            id: op, kind: .migration, state: .planned, summary: "\(plan.direction.rawValue) \(plan.categoryID): \(plan.source) → \(plan.destination)",
            paths: [plan.source, plan.destination], bytes: plan.sourceBytes,
            // `category` is the field `resume` reads. It used to recover the id by splitting the
            // `summary` above on spaces and taking the second word — a parser over prose standing
            // between a journal line and a `removeItem`, with `?? "archives"` when it failed.
            detail: [
                "vault": plan.vaultUUID ?? "", "phase": "PLAN", "category": plan.categoryID,
                // `abort` needs this to know which way the copy went. An externalize's partial copy
                // is on the vault; a restore's is at the canonical home path. Inferring it from the
                // paths would be the same guessing the `category` field was added to stop.
                "direction": plan.direction.rawValue,
            ])
        try journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [plan.source, plan.destination], detail: ["phase": "COPY"])
        var claimed = false
        // Whether the enclosing directory was already there. `createDirectory` below succeeds
        // silently on an existing one, so without this the failure path cannot tell a directory it
        // made from a canonical developer directory it merely wrote into — and a failed *restore*
        // would rmdir `~/Library/Developer/Xcode`.
        let parentPath = (plan.destination as NSString).deletingLastPathComponent
        let parentPreexisted = FileManager.default.fileExists(atPath: parentPath)
        do {
            try assertVaultVolumeStillPresent(plan, before: "COPY")
            try FileManager.default.createDirectory(atPath: (plan.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // Atomically claim the destination: mkdir fails if anything is already there, so a
            // failure path can only ever delete a directory this operation created.
            guard mkdir(plan.destination, 0o755) == 0 else {
                throw MigrationError("Destination \(plan.destination) appeared since planning (\(String(cString: strerror(errno)))); refusing to merge.")
            }
            claimed = true
            // ditto copies the *contents* of the source into the existing destination directory,
            // preserving resource forks, xattrs, ACLs, ownership (when permitted) and timestamps; no shell.
            try runner.check(Tools.ditto, [plan.source, plan.destination])
            // ditto copied the contents into our claimed directory; replicate the root's mode.
            var srcStat = stat()
            if lstat(plan.source, &srcStat) == 0 { _ = chmod(plan.destination, srcStat.st_mode & 0o7777) }
            try afterCopy?(plan)
            // Again, because the copy above can run for many minutes and this is the window in which
            // the volume actually goes away. Verifying a copy that landed on the internal disk
            // against its own source passes, and the journal then records VERIFIED.
            try assertVaultVolumeStillPresent(plan, before: "VERIFY")
            try journal.record(id: op, kind: .migration, state: .started, summary: "VERIFY", paths: [plan.destination], detail: ["phase": "VERIFY"])
            let report = verifierFor(plan).verify(source: plan.source, destination: plan.destination)
            guard report.isIdentical else {
                throw MigrationError(
                    "Verification failed with \(report.mismatches.count)\(report.truncated ? "+" : "") mismatch(es): "
                        + report.mismatches.prefix(5).map(\.description).joined(separator: "; "))
            }
            try journal.record(
                id: op, kind: .migration, state: .completed,
                summary: "copied and verified \(report.sourceFiles) files, \(ByteCount.format(report.sourceBytes)); source intact",
                paths: [plan.source, plan.destination], bytes: report.destinationBytes, detail: ["phase": "VERIFIED", "hashedFiles": "\(report.hashedFiles)"])
            return MigrationOutcome(plan: plan, verification: report, sourceRemoved: false)
        } catch {
            // `try?` swallowed the one failure worth reporting: when the partial copy cannot be
            // removed, every retry is then refused by `planExternalize`, which points at `abort` —
            // and `abort` could not remove it either. The reason for that has to reach both the
            // journal and the person reading the error, or the operation looks merely failed rather
            // than stuck. Only the directory this operation created is ever removed.
            var cleanupNote = ""
            if claimed {
                do { try FileManager.default.removeItem(atPath: plan.destination) } catch {
                    cleanupNote = "; the partial copy at \(plan.destination) could not be removed: \(error.localizedDescription)"
                }
                // And the category directory, but only when this operation created it, and only
                // when externalizing. In the disconnect case that directory sits on the internal
                // disk under a path that reads like the drive — the artifact the volume assertion
                // exists to avoid — but on the restore side the same path is a canonical developer
                // directory that was here before us. `rmdir` refuses a non-empty directory, which
                // bounds the damage; it does not make the decision correct.
                if cleanupNote.isEmpty, !parentPreexisted, plan.direction == .externalize {
                    _ = rmdir(parentPath)
                }
            }
            try journal.record(
                id: op, kind: .migration, state: .failed, summary: "\(error)\(cleanupNote)", paths: [plan.source, plan.destination],
                detail: cleanupNote.isEmpty ? ["phase": "FAILED"] : ["phase": "FAILED", "cleanupFailed": "1"])
            if cleanupNote.isEmpty { throw error }
            throw MigrationError("\(error)\(cleanupNote)")
        }
    }

    /// Ownership can only be compared when both filesystems honour it.
    func verifierFor(_ plan: MigrationPlan) -> TreeVerifier {
        let srcOwners = !(MountStatus.filesystem(containing: plan.source)?.ignoresOwnership ?? true)
        let dstOwners = !(MountStatus.filesystem(containing: (plan.destination as NSString).deletingLastPathComponent)?.ignoresOwnership ?? true)
        return TreeVerifier(deep: plan.deepVerify, compareOwnership: srcOwners && dstOwners)
    }

    // MARK: CLEANUP (separate, explicit, re-verified)

    /// Removes the source of a previously verified externalization. Sequence: refuse while Xcode
    /// runs (it could be writing an archive) → rename the source aside atomically (nothing can
    /// mutate it after this) → deep re-verify the renamed tree against the vault copy → delete.
    /// If verification fails the rename is undone. Non-regenerable categories additionally
    /// require `confirmNonRegenerable`.
    public func removeSource(_ outcome: MigrationOutcome, confirmNonRegenerable: Bool) throws -> MigrationOutcome {
        let plan = outcome.plan
        guard plan.direction == .externalize else { throw MigrationError("Source removal applies to externalizations only.") }
        guard let c = StorageCatalog.category(plan.categoryID) else { throw MigrationError("Unknown category.") }
        // A no-op for every legitimate flow: the only way to hold an externalize plan is to have
        // passed the same check in `planExternalize`. It is here because this is the one function in
        // the product that deletes a source directory, and until now the argument that it could not
        // be aimed at a live tree ran through four functions and a user-writable journal file —
        // `resume` recovers `categoryID` by splitting a free-text summary string. An invariant that
        // a reader has to reconstruct is not one they can rely on. Checked here instead.
        guard c.allowedStrategies.contains(.coldStorage) else {
            throw MigrationError("\(c.name) has no coldStorage strategy; nothing of it was ever externalized. Nothing is removed.")
        }
        if c.regenerability == .nonRegenerable && !confirmNonRegenerable {
            throw MigrationError("\(c.name) is non-regenerable; pass the explicit confirmation to remove the original.")
        }
        if isXcodeRunning() { throw MigrationError("Xcode.app is running and may be writing into \(plan.source). Quit Xcode before removing the original.") }
        if let uuid = plan.vaultUUID {
            let (_, vaultDir) = try verifier.resolveUsable(uuid)
            guard PathSafety.isContained(plan.destination, in: vaultDir) else {
                throw MigrationError("Destination is not on the verified vault volume any more.")
            }
        }
        try preflightSource(plan.source, category: c)
        let op = plan.operationID
        let aside = plan.source + ".xcodevault-removing-" + String(op.prefix(8))
        try journal.record(
            id: op, kind: .migration, state: .started, summary: "CLEANUP rename \(plan.source) → \(aside)", paths: [plan.source, plan.destination],
            detail: ["phase": "CLEANUP", "aside": aside])
        guard rename(plan.source, aside) == 0 else {
            let msg = "Could not rename the source aside: \(String(cString: strerror(errno))). Nothing removed."
            try journal.record(id: op, kind: .migration, state: .failed, summary: msg, paths: [plan.source, plan.destination], detail: ["phase": "VERIFIED"])
            throw MigrationError(msg)
        }
        try afterRenameAside?(aside)
        let report = verifierFor(plan).verify(source: aside, destination: plan.destination)
        guard report.isIdentical else {
            _ = rename(aside, plan.source)
            try journal.record(
                id: op, kind: .migration, state: .failed, summary: "re-verification failed after rename; source restored, NOT removed",
                paths: [plan.source, plan.destination], detail: ["phase": "VERIFIED"])
            throw MigrationError(
                "Re-verification failed; source NOT removed (restored to \(plan.source)). \(report.mismatches.prefix(3).map(\.description).joined(separator: "; "))"
            )
        }
        try journal.record(
            id: op, kind: .migration, state: .started, summary: "CLEANUP delete \(aside)", paths: [aside, plan.destination],
            detail: ["phase": "CLEANUP", "aside": aside])
        try FileManager.default.removeItem(atPath: aside)
        try journal.record(
            id: op, kind: .migration, state: .completed, summary: "source removed after re-verification", paths: [plan.source, plan.destination],
            detail: ["phase": "DONE"])
        var o = outcome; o.sourceRemoved = true; o.verification = report
        return o
    }

    /// Completes a CLEANUP interrupted by a crash. Cases, from the journal's last `aside` entry:
    /// - the aside directory exists → deep re-verify it against the vault copy; delete it (DONE) or
    ///   rename it back to the source path and record `failed`;
    /// - no aside but the source exists → the rename never happened; re-run the full removal;
    /// - neither exists → the delete finished before the journal did; record DONE.
    /// Never touches the vault copy. Refuses while Xcode runs.
    public func resume(operationID: String, confirmNonRegenerable: Bool) throws -> String {
        let entries = try journal.entries().filter { $0.id == operationID && $0.kind == .migration }
        // The PLAN line specifically. This is no longer what stops a forged line from aiming the
        // deletion — `vault`/`direction`/`category` are read from this entry too, and the lines
        // `copyAndVerify` writes after PLAN carry none of them, so a non-PLAN line cannot satisfy
        // the containment check below whatever paths it names. What this guard buys now is that the
        // refusal names the real problem instead of misreporting a truncated journal as an old one
        // (`Journal.read` drops undecodable lines silently). It becomes load-bearing again the
        // moment any of those keys is copied onto a later line.
        guard let planned = entries.first(where: { $0.state == .planned }), planned.paths.count == 2 else {
            guard entries.isEmpty else {
                throw MigrationError(
                    "Migration \(operationID) has journal lines but no readable PLAN line, so its source, destination and category cannot be established. "
                        + "Nothing was touched. The journal may be truncated or edited; compare the two copies by hand before deleting either.")
            }
            throw MigrationError("No migration \(operationID) in the journal.")
        }
        let phases = Set(entries.compactMap { $0.detail["phase"] })
        guard phases.contains("CLEANUP") || phases.contains("VERIFIED") else {
            throw MigrationError("Migration \(operationID) was interrupted before verification; use `migration abort`.")
        }
        // ...and it must actually be *interrupted*, the same test `abort` applies. `copyAndVerify`
        // ends at VERIFIED/`completed` with the source deliberately intact, waiting for an explicit
        // removal; without this guard `resume` would delete the original of a healthy, finished copy
        // — a deletion reachable from a command whose whole abstract is "finish interrupted work".
        guard let last = entries.last, last.state == .started || last.state == .failed else {
            throw MigrationError(
                "Migration \(operationID) is \(entries.last?.state.rawValue ?? "?"), not interrupted; there is no cleanup to finish. "
                    + "To remove the original of a completed copy, do it as its own explicit step.")
        }
        let source = planned.paths[0], destination = planned.paths[1]
        // Derived, never read from the journal. `removeSource` computes this same name from the
        // source and the operation id, so there is nothing to recover — and reading it back was the
        // more dangerous half of this function: it is the path that reaches `removeItem`, and a
        // single appended line setting it to the destination would have had `resume` delete the
        // vault copy (a tree verifies as identical against itself).
        let aside = source + ".xcodevault-removing-" + String(operationID.prefix(8))

        // State is established BEFORE any refusal, so that every message below can name what is
        // actually on disk instead of asserting it. A refusal that tells the user "your copy is at
        // X" without stat-ing X is how a wrong sentence turns into a hand-deleted original.
        var st = stat()
        let destinationPresent = lstat(destination, &st) == 0
        let asidePresent = lstat(aside, &st) == 0
        let sourcePresent = lstat(source, &st) == 0
        func stateSentence() -> String {
            var held: [String] = []
            if destinationPresent { held.append("the vault copy is at \(destination)") } else { held.append("the vault copy is NOT present at \(destination)") }
            if asidePresent { held.append("the original was renamed aside to \(aside)") }
            if sourcePresent { held.append("the original is at \(source)") }
            if !asidePresent && !sourcePresent { held.append("no original is present at \(source) or alongside it") }
            return held.joined(separator: "; ")
        }

        guard let categoryID = planned.detail["category"], !categoryID.isEmpty else {
            throw MigrationError(
                "Migration \(operationID) predates the journal's `category` field, so the category cannot be established without guessing. "
                    + "Nothing was removed: \(stateSentence()). Compare the two by hand; do not delete either copy until you have. "
                    + "Once you are satisfied, `xcodevaultctl migration forget \(operationID)` clears the entry so migrations can run again.")
        }
        guard let c = StorageCatalog.category(categoryID) else { throw MigrationError("Unknown category \(categoryID) in journal.") }
        // Needed here in its own right: the `aside` branch below deletes directly rather than through
        // `removeSource`, so that function's identical guard does not cover it.
        guard c.allowedStrategies.contains(.coldStorage) else {
            throw MigrationError("\(c.name) has no coldStorage strategy; no migration of it can be legitimate. Nothing is removed.")
        }
        if c.regenerability == .nonRegenerable && !confirmNonRegenerable {
            throw MigrationError("\(c.name) is non-regenerable; pass the explicit confirmation to complete the removal.")
        }
        if isXcodeRunning() { throw MigrationError("Xcode.app is running; quit it before completing the cleanup.") }

        // Re-establish that `destination` is still the verified vault volume, by UUID and sentinel —
        // not merely that *something* exists at that path. After a crash and a reboot the external
        // volume can lose the mount race, and a directory holding an older copy can sit at the mount
        // point; `lstat` cannot tell those apart, and deleting against the wrong one leaves shadow
        // data on the internal disk as the only survivor (MIGRATION_ENGINE.md §Split-brain safety).
        let vaultUUID = planned.detail["vault"].flatMap { $0.isEmpty ? nil : $0 }
        guard let vaultUUID else {
            throw MigrationError(
                "Migration \(operationID) records no vault volume, so the copy at \(destination) cannot be confirmed to be on it. "
                    + "Nothing was removed: \(stateSentence()).")
        }
        let (_, vaultDir) = try verifier.resolveUsable(vaultUUID)
        guard PathSafety.isContained(destination, in: vaultDir) else {
            throw MigrationError("\(destination) is not on the verified vault volume any more. Nothing is removed: \(stateSentence()).")
        }
        guard destinationPresent else { throw MigrationError("Vault copy \(destination) is not present (volume disconnected?). Nothing changed.") }

        // Read, not assumed. A restore cannot reach here today (the phase and interrupted guards
        // both exclude it), but `direction` is a field now and asserting it costs one line.
        let direction = planned.detail["direction"].flatMap { MigrationPlan.Direction(rawValue: $0) } ?? .externalize
        guard direction == .externalize else {
            throw MigrationError("Migration \(operationID) is a restore; `resume` completes the cleanup of an externalization only. Nothing is removed.")
        }
        let plan = MigrationPlan(
            operationID: operationID, direction: .externalize, categoryID: c.id, source: source, destination: destination,
            vaultUUID: vaultUUID, sourceBytes: 0, sourceFiles: 0, deepVerify: true, warnings: [])

        if asidePresent {
            try journal.record(
                id: operationID, kind: .migration, state: .started, summary: "RESUME re-verify \(aside)", paths: [aside, destination],
                detail: ["phase": "CLEANUP", "aside": aside, "category": c.id, "vault": vaultUUID])
            var asidePlan = plan; asidePlan.source = aside
            let report = verifierFor(asidePlan).verify(source: aside, destination: destination)
            guard report.isIdentical else {
                _ = rename(aside, source)
                try journal.record(
                    id: operationID, kind: .migration, state: .failed, summary: "resume: re-verification failed; source restored to \(source)",
                    paths: [source, destination], detail: ["phase": "VERIFIED", "category": c.id, "vault": vaultUUID])
                throw MigrationError(
                    "Re-verification failed; the original was restored to \(source). \(report.mismatches.prefix(3).map(\.description).joined(separator: "; "))")
            }
            // The non-aside branch gets this through `removeSource` → `preflightSource`; this branch
            // deletes directly, so it would otherwise be the one `removeItem` in the product whose
            // target was never checked against the category that is supposed to own it. Checked on
            // `source` rather than `aside`, because the aside is a sibling of the templated path.
            guard c.containsPath(source, home: home) else {
                throw MigrationError("\(source) is not a path of \(c.name).\(c.containmentShapeHint) Nothing is removed.")
            }
            try FileManager.default.removeItem(atPath: aside)
            try journal.record(
                id: operationID, kind: .migration, state: .completed, summary: "resume: source removed after re-verification", paths: [source, destination],
                detail: ["phase": "DONE", "category": c.id, "vault": vaultUUID])
            return "Completed: \(aside) verified against the vault copy and removed."
        }
        if sourcePresent {
            // Rename never happened (or was undone): run the normal removal path.
            let report = verifierFor(plan).verify(source: source, destination: destination)
            let outcome = MigrationOutcome(plan: plan, verification: report, sourceRemoved: false)
            _ = try removeSource(outcome, confirmNonRegenerable: confirmNonRegenerable)
            return "Completed: \(source) re-verified and removed."
        }
        try journal.record(
            id: operationID, kind: .migration, state: .completed, summary: "resume: source already removed; vault copy present", paths: [source, destination],
            detail: ["phase": "DONE", "category": c.id, "vault": vaultUUID])
        return "Nothing to do: the source was already removed and the vault copy is present."
    }

    /// Abandons a migration that never reached verification — interrupted (crash) or **failed**
    /// (e.g. the vault volume vanished mid-copy, so the partial destination could not be removed
    /// at the time and now blocks a retry). Removes only the partial destination copy and journals
    /// the abort. Refuses once VERIFIED/CLEANUP/DONE was reached: from then on the vault copy may be
    /// the only complete one. Never deletes a source.
    /// Closes out a migration the engine will not finish itself, **touching no files at all**.
    ///
    /// It exists because refusing is not free. When `resume` declines — an old journal with no
    /// `category`, an unreadable PLAN line, a vault it cannot re-confirm — the operation's last
    /// state stays `started`, so `interrupted()` keeps returning it, so `refuseIfInterrupted` blocks
    /// every future `planExternalize` and `planRestore`; and `abort` refuses too, because the phase
    /// is past verification. The data was safe and the product was wedged, leaving hand-editing the
    /// journal as the only way out — which is the exact threat the refusals were added to close.
    ///
    /// The caller asserts they have compared both copies themselves. That is the whole contract:
    /// this records the assertion and writes nothing else, so the worst it can do is let a later
    /// migration proceed.
    public func forget(operationID: String, confirmComparedBothCopies: Bool) throws {
        guard confirmComparedBothCopies else {
            throw MigrationError("`forget` records that you verified both copies yourself; pass the explicit confirmation.")
        }
        let entries = try journal.entries().filter { $0.id == operationID && $0.kind == .migration }
        guard let last = entries.last else { throw MigrationError("No migration \(operationID) in the journal.") }
        guard last.state == .started || last.state == .failed else {
            throw MigrationError("Migration \(operationID) is already \(last.state.rawValue); nothing to forget.")
        }
        // Exactly the complement of what `abort` accepts. Without this, `forget` takes the
        // pre-verification failures that belong to `abort` — and since `leftoverPartialCopies`
        // filters on `started`/`failed`, recording `.rolledBack` here would drop the operation out
        // of `doctor`, out of `migration status`, and out of the retry hint in `planExternalize`,
        // leaving a partial copy on the vault that nothing in the product can name again. An escape
        // hatch that manufactures shadow data is worse than the wedge it was added to relieve.
        let phases = Set(entries.compactMap { $0.detail["phase"] })
        // `forget` and `abort` divide the space between them, and they have to be read together —
        // designing them separately is what produced a pair that both refused the same operation.
        // The rule: `forget` declines anything `abort` can still clean up. The one exception is an
        // externalize whose vault volume is gone, because there `abort` refuses too (it will not
        // claim "no partial copy present" about a disk it cannot see) and the user would otherwise
        // have no verb at all.
        // One exception to that division, for the wedge the two verbs used to create between them:
        // when `abort` ran and its removal failed, `abort` cannot succeed however many times it is
        // repeated, while `forget` would decline for the very reason that `abort` is the right verb.
        // Nothing in the product could then close the operation. `abort` now records the failure,
        // and this is what reads it.
        // Keyed on the PHASE, not on `cleanupFailed`. Two different producers set that marker, and
        // only one of them means what this exception is for: `abort` tried and could not. The other
        // is `copyAndVerify`'s own opportunistic cleanup, which means abort has not been *offered*
        // yet — and accepting that case here would record `.rolledBack` on a live partial copy,
        // dropping it out of `leftoverPartialCopies` and therefore out of `doctor`, out of
        // `migration status` and out of `planExternalize`'s retry hint, while writing a journal line
        // saying no file was touched. That is the hole `testForgetRefusesPreVerificationFailures…`
        // exists to guard, and keying on the marker punched straight through it.
        // `ABORT_FAILED` is a record of the past; whether `abort` can act is a question about the
        // present, and the two diverge as soon as the obstacle is removed. But the redirect has to
        // be **bounded**, and the first version was not: it asked `isDeletableFile`, which consults
        // POSIX mode on the parent and is blind to ACLs and file flags — measured on this machine, a
        // `deny delete` ACL gives `isDeletableFile == true` while `removeItem` fails. That is
        // precisely the obstacle class this whole feature exists for, so `abort` failed, `forget`
        // sent the user back to `abort`, and the pair did not terminate.
        //
        // So: one past failure still hands it back, because the obstacle may genuinely be gone and
        // `abort` succeeding keeps the copy visible to `doctor`. A *second* failure on the same
        // operation is proof the prediction was wrong, and `forget` closes it. At most one round
        // trip, and no prediction about deletability is needed to guarantee termination.
        //
        // The guarantee is conditional, and the condition is worth stating because the earlier
        // wording did not: it holds over a WRITABLE journal. `abort` records its failure before
        // rethrowing, so if the journal itself cannot be written the failure count never advances
        // and nothing closes. That mode is loud rather than silent — every verb errors — which is
        // why it is recorded in KNOWN-ISSUES-AT-PUBLICATION.md rather than defended against here.
        let abortFailures = entries.filter { $0.detail["phase"] == "ABORT_FAILED" }.count
        var abortRemovalFailed = abortFailures > 0
        if abortRemovalFailed, abortFailures < 2, case .cleanable(let planned) = abortDisposition(entries: entries, operationID: operationID) {
            var st = stat()
            if lstat(planned.paths[1], &st) != 0 {
                abortRemovalFailed = false  // nothing left to remove; the normal path applies
            } else {
                throw MigrationError(
                    "Migration \(operationID) failed to abort earlier. Try `xcodevaultctl migration abort \(operationID)` once more: "
                        + "if the obstacle is gone it will remove the partial copy at \(planned.paths[1]), and if it fails again "
                        + "`forget` will close the entry and record that a copy may remain there.")
            }
        }
        if abortRemovalFailed {
            // Its own record, naming the path. This is the only line that survives the operation,
            // and a copy demonstrably remains on disk — "no file was touched" would be false.
            let location = entries.first(where: { $0.state == .planned })?.paths.last ?? "the recorded destination"
            try journal.record(
                id: operationID, kind: .migration, state: .rolledBack,
                summary: "forgotten by the user after `abort` failed to remove the partial copy; it may still be at \(location)",
                paths: entries.first(where: { $0.state == .planned })?.paths ?? last.paths)
            return
        }
        if phases.isDisjoint(with: MigrationEngine.phasesWhereAbortIsUnsafe) {
            // Pre-verification: `abort`'s territory. Ask `abort` what it would do rather than
            // guessing — the previous version re-derived "abort cannot act" as "externalize with an
            // absent vault", which is one of several ways it declines, so a failed restore on an
            // unplugged drive was refused by both verbs and its residue sat at a canonical developer
            // path with nothing in the product able to remove it.
            let why: String
            // Both forms below name the path. This record is the only thing that survives the
            // operation, so "a copy may remain" without a location is a note nobody can act on.
            let location = entries.first(where: { $0.state == .planned })?.paths.last ?? "the recorded destination"
            switch abortDisposition(entries: entries, operationID: operationID) {
            case .cleanable(let planned):
                var st = stat()
                let present = lstat(planned.paths[1], &st) == 0
                throw MigrationError(
                    "Migration \(operationID) never reached verification, so there is nothing here that needs your judgement: "
                        + (present
                            ? "`xcodevaultctl migration abort \(operationID)` removes the partial copy at \(planned.paths[1]) and closes it out."
                            : "the partial copy at \(planned.paths[1]) is already gone, and `xcodevaultctl migration abort \(operationID)` closes the entry."))
            case .unreachable(let reason):
                why = "a partial copy may remain at \(location) — \(reason)"
            case .declined(let reason):
                why = "\(location) was left untouched — \(reason)"
            }
            try journal.record(
                id: operationID, kind: .migration, state: .rolledBack,
                summary: "forgotten by the user; abort could not close this one: \(why)",
                paths: entries.first(where: { $0.state == .planned })?.paths ?? last.paths)
            return
        }
        try journal.record(
            id: operationID, kind: .migration, state: .rolledBack,
            summary: "forgotten by the user after comparing both copies by hand; no file was touched",
            paths: entries.first(where: { $0.state == .planned })?.paths ?? last.paths)
    }

    /// Whether `abort` can clean up after a pre-verification failure, and if not, why.
    ///
    /// Factored because the rule it encodes — **`forget` declines anything `abort` can still clean
    /// up** — has to hold across two functions, and stating it in a comment while deriving it twice
    /// is how the pair ended up refusing the same operation. `forget` consumes this rather than
    /// re-deciding: any case that is not `.cleanable` is one it may close out, and the reason string
    /// travels with it into the journal.
    enum AbortDisposition {
        /// `abort` will remove the partial copy described by this PLAN entry. Carried rather than
        /// re-looked-up, so no caller has to establish for itself that a PLAN line exists.
        case cleanable(planned: JournalEntry)
        /// We cannot see whether a copy is there — the volume holding it is not present. Nothing may
        /// be recorded about it, because "no partial copy present" would be a claim about a disk
        /// that is not here. The string is the *reason* only: the remedy belongs to whoever throws,
        /// because `forget` writes this into a permanent record and an embedded "run `migration
        /// forget`" would tell the reader to do the thing that produced the record.
        case unreachable(String)
        /// We can see, and this is not where this migration's copy belongs. Refusing is the answer;
        /// the path is left exactly as it is.
        case declined(String)
    }

    func abortDisposition(entries: [JournalEntry], operationID: String) -> AbortDisposition {
        // Decided here, not by each caller. This case used to be a `guard` in both `abort` and
        // `forget` — the same duplication the enum exists to remove, one level up, and it left a
        // migration with a torn PLAN line refused by both verbs and owned by neither.
        guard let planned = entries.first(where: { $0.state == .planned }), planned.paths.count == 2 else {
            return .declined(
                "Migration \(operationID) has no readable PLAN line, so its paths, direction and category cannot be established; "
                    + "refusing to act on the strength of the remaining lines.")
        }
        let source = planned.paths[0], destination = planned.paths[1]
        let direction = planned.detail["direction"].flatMap { MigrationPlan.Direction(rawValue: $0) }
        let category = planned.detail["category"].flatMap { StorageCatalog.category($0) }
        // The gate `planExternalize`, `planRestore`, `removeSource` and `resume` all apply, missing
        // only here — and `abort` deletes directly, so nothing else covers it. A journal entry
        // naming a category that was never eligible to leave cannot describe a migration of ours,
        // which is exactly the entry not to act on.
        if let c = category, !c.allowedStrategies.contains(.coldStorage) {
            return .declined(
                "Migration \(operationID) names \(c.name), which has no coldStorage strategy, so no migration of it can be legitimate. Nothing is removed.")
        }
        let vaultDir = planned.detail["vault"].flatMap { $0.isEmpty ? nil : $0 }.flatMap { try? verifier.resolveUsable($0).1 }
        let onVault = vaultDir.map { PathSafety.isContained(destination, in: $0) } ?? false
        // Same correction as `preflightSource`, and it matters more here: this decides whether a
        // destination counts as "back at its own home", and for a per-device category the old
        // prefix test said yes for anything anywhere in the device set.
        let atOwnHome = category.map { $0.containsPath(destination, home: home) } ?? false
        func sourcePresent() -> Bool { var st = stat(); return lstat(source, &st) == 0 }

        // Also here rather than at the deletion site, for the same reason: a refusal `abort` makes
        // that the disposition does not know about is a row where the two verbs disagree again.
        //
        // UNPINNED, knowingly. Moving this back out of the disposition fails no test, because
        // nothing distinguishes it: `MountStatus.isMountPoint` reads the real mount table and the
        // fixtures cannot make a temp directory into a mount point, while every path that could be
        // one fails the containment checks above it first. It is here for consistency — one place
        // decides — and not because a test proves it must be. Said out loud rather than left for
        // someone to discover with a mutation run.
        guard !MountStatus.isMountPoint(destination) else {
            return .declined("\(destination) is a mount point; refusing.")
        }

        switch direction {
        case .externalize:
            // The source is the live tree. If it is gone the vault copy may be the only one left,
            // and nothing may delete it. (Direction-scoped on purpose: for a restore the "source" is
            // the vault copy, and its absence says nothing about the local partial copy.)
            guard sourcePresent() else {
                return .declined("Source \(source) is gone; not removing \(destination) — it may be the only copy.")
            }
            guard let vaultDir else {
                return .unreachable(
                    "the vault volume for migration \(operationID) is not present, so whether a partial copy remains on it cannot be determined")
            }
            guard PathSafety.isContained(destination, in: vaultDir) else {
                return .declined(
                    "\(destination) is not inside the vault directory \(vaultDir); it is not the partial copy this externalization made. Nothing is removed.")
            }
            return .cleanable(planned: planned)
        case .restore:
            // The partial copy is at the canonical path — the containment `planRestore` applied when
            // it accepted the destination. The vault is not needed to see it, which is what makes an
            // unplugged drive an ordinary case here rather than a dead end.
            guard atOwnHome else {
                return .declined(
                    "\(destination) is not inside \(category?.name ?? "the category")'s own location; it is not the partial copy this restore made. Nothing is removed."
                )
            }
            return .cleanable(planned: planned)
        case .none:
            // A PLAN line from before the `direction` key. Accept whichever containment holds; both
            // targets are structurally constrained, so this cannot aim a deletion anywhere a
            // legitimate plan could not have.
            if atOwnHome { return .cleanable(planned: planned) }
            if onVault {
                guard sourcePresent() else {
                    return .declined("Source \(source) is gone; not removing \(destination) — it may be the only copy.")
                }
                return .cleanable(planned: planned)
            }
            guard vaultDir != nil else {
                return .unreachable(
                    "migration \(operationID) predates the journal's `direction` field and its vault volume is not present, so \(destination) cannot be confirmed to be a copy this tool made"
                )
            }
            return .declined("\(destination) is not where this migration would have put its copy. Nothing is removed.")
        }
    }

    public func abort(operationID: String) throws {
        let entries = try journal.entries().filter { $0.id == operationID && $0.kind == .migration }
        guard !entries.isEmpty else { throw MigrationError("No migration \(operationID) in the journal.") }
        // Optional on purpose: whether a usable PLAN line exists is `abortDisposition`'s decision,
        // not one this function re-makes. It is read here only to word the post-verification
        // refusal, which deletes nothing either way.
        let plannedForMessage = entries.first(where: { $0.state == .planned }).flatMap { $0.paths.count == 2 ? $0 : nil }
        let phases = Set(entries.compactMap { $0.detail["phase"] })
        if !phases.isDisjoint(with: MigrationEngine.phasesWhereAbortIsUnsafe) {
            let aside = plannedForMessage.map { $0.paths[0] + ".xcodevault-removing-" + String(operationID.prefix(8)) }
            let asideExists = aside.flatMap { a in
                {
                    var st = stat(); return lstat(a, &st) == 0
                }() ? a : nil
            }
            throw MigrationError(
                "Migration \(operationID) reached \(phases.sorted().joined(separator: "/")): the vault copy at \(plannedForMessage?.paths[1] ?? "the recorded destination") was verified and may be the only complete copy. Not deleting anything.\(asideExists.map { " The original was renamed to \($0); if it is intact, rename it back manually." } ?? "")"
            )
        }
        guard let last = entries.last, last.state == .started || last.state == .failed else {
            throw MigrationError("Migration \(operationID) is in state \(entries.last?.state.rawValue ?? "?"); nothing to abort.")
        }
        let planned: JournalEntry
        switch abortDisposition(entries: entries, operationID: operationID) {
        case .cleanable(let p): planned = p
        case .declined(let why): throw MigrationError(why)
        case .unreachable(let why):
            // The remedy is appended here rather than carried in the reason, because `forget` writes
            // that same reason into a permanent record and must not tell its reader to run `forget`.
            throw MigrationError(
                "Nothing was removed and nothing was recorded: \(why). Reconnect the volume and re-run; if it is gone for good, "
                    + "`xcodevaultctl migration forget \(operationID) --i-verified-both-copies-myself` closes the entry and records that a copy may remain on it."
            )
        }
        let source = planned.paths[0], destination = planned.paths[1]

        var st = stat()
        var removed = false
        if lstat(destination, &st) == 0 {
            do {
                try FileManager.default.removeItem(atPath: destination)
                removed = true
            } catch {
                // Record the failure before rethrowing. This throw used to happen *before* any
                // journal line, so the operation stayed exactly as it was: `abort` could not clean
                // it up however many times it ran, and `forget` declined it precisely because
                // `abort` is the verb that should. The demonstrated route is a file carrying a
                // `deny delete` ACL — the temp file `ditto` leaves behind inherits it — and the only
                // exit was editing the journal by hand, which is the wedge this pair of verbs was
                // designed to eliminate, reached through a different door.
                try journal.record(
                    id: operationID, kind: .migration, state: .failed,
                    summary: "abort could not remove the partial copy at \(destination): \(error.localizedDescription)",
                    paths: [source, destination], detail: ["phase": "ABORT_FAILED", "cleanupFailed": "1"])
                throw MigrationError(
                    "Could not remove the partial copy at \(destination): \(error.localizedDescription). "
                        + "Run `xcodevaultctl migration abort \(operationID)` again once it is removable — by hand, or after lifting "
                        + "whatever denies the delete. If it fails a second time, "
                        + "`xcodevaultctl migration forget \(operationID) --i-verified-both-copies-myself` closes the entry and records "
                        + "that a copy may remain at that path.")
            }
        }
        try journal.record(
            id: operationID, kind: .migration, state: .rolledBack,
            summary: removed ? "aborted; partial copy removed, source intact" : "aborted; no partial copy present, source intact", paths: [source, destination])
    }

    /// Failed or interrupted pre-verification migrations whose destination still exists on disk —
    /// partial copies that block a retry (`doctor` surfaces them; `abort` removes them).
    public func leftoverPartialCopies() throws -> [JournalEntry] {
        var last: [String: JournalEntry] = [:]
        var planned: [String: JournalEntry] = [:]
        var unsafe: Set<String> = []
        for e in try journal.entries() where e.kind == .migration {
            // The PLAN line, for the same reason `resume` and `abort` insist on it: these paths are
            // what `doctor` reports and what `abort` will delete.
            if planned[e.id] == nil, e.state == .planned, e.paths.count == 2 { planned[e.id] = e }
            last[e.id] = e
            if let ph = e.detail["phase"], MigrationEngine.phasesWhereAbortIsUnsafe.contains(ph) { unsafe.insert(e.id) }
        }
        return last.values.filter { e in
            guard !unsafe.contains(e.id), e.state == .failed || e.state == .started, let p = planned[e.id] else { return false }
            var st = stat(); return lstat(p.paths[1], &st) == 0
        }.map { planned[$0.id]! }.sorted { $0.sequence < $1.sequence }
    }
}
