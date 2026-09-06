import Foundation

/// The transactional copy engine behind `externalize` (cold storage) and `restore`
/// (MIGRATION_ENGINE.md). One migration = copy a catalog path to `<vault>/XcodeVault/<category>/…`
/// (or back), verify beyond file counts, and only ever remove the source on an explicit,
/// separate, re-verified step. Every transition is journaled under one operation id so a
/// crash leaves a resumable/abortable record that `doctor` and `migration status` surface.
public struct MigrationPlan: Sendable, Codable, Equatable {
    public enum Direction: String, Sendable, Codable { case externalize, restore }
    public var operationID: String
    public var direction: Direction
    public var categoryID: String
    public var source: String
    public var destination: String          // final path of the copy
    public var vaultUUID: String?
    public var sourceBytes: UInt64
    public var sourceFiles: UInt64
    public var deepVerify: Bool             // SHA-256 (always for non-regenerable data)
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

    public init(runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal(), verifier: VaultVerifier = VaultVerifier(),
                home: String = NSHomeDirectory(), isXcodeRunning: @escaping @Sendable () -> Bool = CleanExecutor.xcodeIsRunning,
                afterCopy: (@Sendable (MigrationPlan) throws -> Void)? = nil, afterRenameAside: (@Sendable (String) throws -> Void)? = nil) {
        self.runner = runner; self.journal = journal; self.verifier = verifier; self.home = home
        self.isXcodeRunning = isXcodeRunning; self.afterCopy = afterCopy; self.afterRenameAside = afterRenameAside
    }

    /// Journal phases; `abort` refuses anything at or past VERIFIED because the vault copy may be
    /// the only complete copy by then (crash during CLEANUP).
    static let phasesWhereAbortIsUnsafe: Set<String> = ["VERIFIED", "CLEANUP", "DONE"]

    // MARK: PREFLIGHT + PLAN

    /// Plans externalizing one catalog path into a verified vault volume.
    public func planExternalize(categoryID: String, source: String, vaultRef: String) throws -> MigrationPlan {
        guard let c = StorageCatalog.category(categoryID) else { throw MigrationError("Unknown category \(categoryID).") }
        guard c.allowedStrategies.contains(.coldStorage) else { throw MigrationError("\(c.name) has no coldStorage strategy (outcome: \(c.outcomeLabel)). Nothing is moved.") }
        try refuseIfInterrupted()
        let (vault, vaultDir) = try verifier.resolveUsable(vaultRef)
        try preflightSource(source, category: c)
        let source = try PathSafety.canonicalize(source)
        let dest = vaultDir + "/" + c.id + "/" + (source as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: dest) { throw MigrationError("Destination \(dest) already exists. Verify or remove it first; the engine never merges into existing data.") }
        let usage = DiskUsage.measure(source) ?? .zero
        if usage.isLowerBound { throw MigrationError("Parts of \(source) are unreadable; refusing to migrate a tree we cannot fully read.") }
        let free = MountStatus.space(at: vaultDir)?.free ?? 0
        guard free > usage.allocatedBytes + 1_000_000_000 else { throw MigrationError("Vault has \(ByteCount.format(free)) free; need \(ByteCount.format(usage.allocatedBytes)) plus headroom.") }
        var warnings: [String] = []
        if c.regenerability == .nonRegenerable { warnings.append("\(c.name) is non-regenerable: deep (SHA-256) verification is mandatory and the source is never removed automatically.") }
        if let fs = MountStatus.filesystem(containing: vaultDir), fs.ignoresOwnership { warnings.append("Vault volume ignores ownership; owners will not be preserved.") }
        return MigrationPlan(operationID: UUID().uuidString, direction: .externalize, categoryID: c.id, source: source, destination: dest,
                             vaultUUID: vault.volumeUUID, sourceBytes: usage.allocatedBytes, sourceFiles: usage.fileCount,
                             deepVerify: true, warnings: warnings)
    }

    /// Plans restoring a vault copy back to its original location.
    public func planRestore(categoryID: String, vaultRef: String, name: String, to destination: String) throws -> MigrationPlan {
        guard let c = StorageCatalog.category(categoryID) else { throw MigrationError("Unknown category \(categoryID).") }
        try refuseIfInterrupted()
        let (vault, vaultDir) = try verifier.resolveUsable(vaultRef)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw MigrationError("Invalid vault entry name.") }
        let source = vaultDir + "/" + c.id + "/" + name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { throw MigrationError("\(source) does not exist in the vault.") }
        try PathSafety.requireContained(destination, in: c.pathTemplates, home: home, what: c.name)
        let destination = try PathSafety.canonicalize(destination)
        var dst = stat()
        if lstat(destination, &dst) == 0 { throw MigrationError("\(destination) already exists; refusing to overwrite. Move it aside first.") }
        let parent = (destination as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw MigrationError("\(parent) is not writable.") }
        let usage = DiskUsage.measure(source) ?? .zero
        let free = MountStatus.space(at: parent)?.free ?? 0
        guard free > usage.allocatedBytes + 1_000_000_000 else { throw MigrationError("Only \(ByteCount.format(free)) free at \(parent); need \(ByteCount.format(usage.allocatedBytes)) plus headroom.") }
        return MigrationPlan(operationID: UUID().uuidString, direction: .restore, categoryID: c.id, source: source, destination: destination,
                             vaultUUID: vault.volumeUUID, sourceBytes: usage.allocatedBytes, sourceFiles: usage.fileCount, deepVerify: true, warnings: [])
    }

    func preflightSource(_ source: String, category: StorageCategory) throws {
        var st = stat()
        guard lstat(source, &st) == 0 else { throw MigrationError("\(source) does not exist.") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw MigrationError("\(source) is not a directory (symlink?). Fix with doctor first.") }
        guard !MountStatus.isMountPoint(source) else { throw MigrationError("\(source) is a mount point; refusing.") }
        do { try PathSafety.requireContained(source, in: category.pathTemplates, home: home, what: category.name) }
        catch { throw MigrationError("\(source) is not under a \(category.name) path (\(error)).") }
        let canonical = try PathSafety.canonicalize(source)
        let forbidden = CatalogRules.neverSymlink.compactMap { try? PathSafety.canonicalize($0.expandingTilde(home: home)) }
        guard !forbidden.contains(canonical) else { throw MigrationError("\(source) is a protected directory.") }
        if let u = DiskUsage.measure(source), !u.skippedMountPoints.isEmpty { throw MigrationError("\(source) contains mount points (\(u.skippedMountPoints.joined(separator: ", "))); refusing.") }
    }

    func refuseIfInterrupted() throws {
        let interrupted = try journal.interrupted().filter { $0.kind == .migration }
        guard interrupted.isEmpty else {
            throw MigrationError("An earlier migration was interrupted (\(interrupted.map(\.id).joined(separator: ", "))). Run `migration status` and abort or complete it before starting another.")
        }
    }

    // MARK: COPY → VERIFY

    /// Executes COPY and VERIFY. Never touches the source. On any failure the partial copy is
    /// removed (it is ours) and the journal records `failed`.
    public func copyAndVerify(_ plan: MigrationPlan) throws -> MigrationOutcome {
        let op = plan.operationID
        try journal.record(id: op, kind: .migration, state: .planned, summary: "\(plan.direction.rawValue) \(plan.categoryID): \(plan.source) → \(plan.destination)",
                           paths: [plan.source, plan.destination], bytes: plan.sourceBytes, detail: ["vault": plan.vaultUUID ?? "", "phase": "PLAN"])
        try journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [plan.source, plan.destination], detail: ["phase": "COPY"])
        var claimed = false
        do {
            try FileManager.default.createDirectory(atPath: (plan.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // Atomically claim the destination: mkdir fails if anything is already there, so a
            // failure path can only ever delete a directory this operation created.
            guard mkdir(plan.destination, 0o755) == 0 else { throw MigrationError("Destination \(plan.destination) appeared since planning (\(String(cString: strerror(errno)))); refusing to merge.") }
            claimed = true
            // ditto copies the *contents* of the source into the existing destination directory,
            // preserving resource forks, xattrs, ACLs, ownership (when permitted) and timestamps; no shell.
            try runner.check(Tools.ditto, [plan.source, plan.destination])
            try afterCopy?(plan)
            try journal.record(id: op, kind: .migration, state: .started, summary: "VERIFY", paths: [plan.destination], detail: ["phase": "VERIFY"])
            let report = verifierFor(plan).verify(source: plan.source, destination: plan.destination)
            guard report.isIdentical else {
                throw MigrationError("Verification failed with \(report.mismatches.count)\(report.truncated ? "+" : "") mismatch(es): " + report.mismatches.prefix(5).map(\.description).joined(separator: "; "))
            }
            try journal.record(id: op, kind: .migration, state: .completed, summary: "copied and verified \(report.sourceFiles) files, \(ByteCount.format(report.sourceBytes)); source intact",
                               paths: [plan.source, plan.destination], bytes: report.destinationBytes, detail: ["phase": "VERIFIED", "hashedFiles": "\(report.hashedFiles)"])
            return MigrationOutcome(plan: plan, verification: report, sourceRemoved: false)
        } catch {
            if claimed { try? FileManager.default.removeItem(atPath: plan.destination) }   // only the directory this op created
            try journal.record(id: op, kind: .migration, state: .failed, summary: "\(error)", paths: [plan.source, plan.destination], detail: ["phase": "FAILED"])
            throw error
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
        if c.regenerability == .nonRegenerable && !confirmNonRegenerable {
            throw MigrationError("\(c.name) is non-regenerable; pass the explicit confirmation to remove the original.")
        }
        if isXcodeRunning() { throw MigrationError("Xcode.app is running and may be writing into \(plan.source). Quit Xcode before removing the original.") }
        if let uuid = plan.vaultUUID {
            let (_, vaultDir) = try verifier.resolveUsable(uuid)
            guard PathSafety.isContained(plan.destination, in: vaultDir) else { throw MigrationError("Destination is not on the verified vault volume any more.") }
        }
        try preflightSource(plan.source, category: c)
        let op = plan.operationID
        let aside = plan.source + ".xcodevault-removing-" + String(op.prefix(8))
        try journal.record(id: op, kind: .migration, state: .started, summary: "CLEANUP rename \(plan.source) → \(aside)", paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP", "aside": aside])
        guard rename(plan.source, aside) == 0 else { throw MigrationError("Could not rename the source aside: \(String(cString: strerror(errno))). Nothing removed.") }
        try afterRenameAside?(aside)
        let report = verifierFor(plan).verify(source: aside, destination: plan.destination)
        guard report.isIdentical else {
            _ = rename(aside, plan.source)
            try journal.record(id: op, kind: .migration, state: .failed, summary: "re-verification failed after rename; source restored, NOT removed", paths: [plan.source, plan.destination], detail: ["phase": "VERIFIED"])
            throw MigrationError("Re-verification failed; source NOT removed (restored to \(plan.source)). \(report.mismatches.prefix(3).map(\.description).joined(separator: "; "))")
        }
        try journal.record(id: op, kind: .migration, state: .started, summary: "CLEANUP delete \(aside)", paths: [aside, plan.destination], detail: ["phase": "CLEANUP", "aside": aside])
        try FileManager.default.removeItem(atPath: aside)
        try journal.record(id: op, kind: .migration, state: .completed, summary: "source removed after re-verification", paths: [plan.source, plan.destination], detail: ["phase": "DONE"])
        var o = outcome; o.sourceRemoved = true; o.verification = report
        return o
    }

    /// Abandons a migration interrupted during COPY/VERIFY: removes the partial destination copy
    /// and journals the abort. Refuses once the copy was verified (VERIFIED/CLEANUP/DONE phases):
    /// from then on the vault copy may be the only complete one. Never deletes a source.
    public func abort(operationID: String) throws {
        let entries = try journal.entries().filter { $0.id == operationID && $0.kind == .migration }
        guard let planned = entries.first, planned.paths.count == 2 else { throw MigrationError("No migration \(operationID) in the journal.") }
        let phases = Set(entries.compactMap { $0.detail["phase"] })
        if !phases.isDisjoint(with: MigrationEngine.phasesWhereAbortIsUnsafe) {
            let aside = entries.compactMap { $0.detail["aside"] }.last
            throw MigrationError("Migration \(operationID) reached \(phases.sorted().joined(separator: "/")): the vault copy at \(planned.paths[1]) was verified and may be the only complete copy. Not deleting anything.\(aside.map { " The original was renamed to \($0); if it is intact, rename it back manually." } ?? "")")
        }
        let source = planned.paths[0], destination = planned.paths[1]
        var st = stat()
        guard lstat(source, &st) == 0 else { throw MigrationError("Source \(source) is gone; not removing \(destination) — it may be the only copy.") }
        var removed = false
        if lstat(destination, &st) == 0 { try FileManager.default.removeItem(atPath: destination); removed = true }
        try journal.record(id: operationID, kind: .migration, state: .rolledBack, summary: removed ? "aborted; partial copy removed, source intact" : "aborted; no partial copy present, source intact", paths: [source, destination])
    }
}
