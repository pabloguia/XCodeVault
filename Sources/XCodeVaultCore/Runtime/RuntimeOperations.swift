import Foundation

/// An installer image (.dmg) sitting in an external Runtime Library directory.
public struct RuntimeInstaller: Sendable, Codable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var fileName: String
    public var sizeBytes: UInt64
    public var modifiedAt: Date
    /// Best-effort parse of Apple's file name ("iOS 26.5 Simulator Runtime.dmg", "watchOS_26.5_Simulator_Runtime.dmg").
    public var platform: String?
    public var version: String?
    public var build: String?

    public static func parse(fileName: String) -> (platform: String?, version: String?, build: String?) {
        let base = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let parts = base.split(separator: " ").map(String.init)
        let platforms = ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"]
        // Xcode's own `-exportPath` names the file after the SDK, not the display name:
        // `iphonesimulator_26.5_23F77.dmg`, `appletvsimulator_26.5_23L470.exportedBundle`. Only the
        // display form was recognised, so a real export parsed to `platform == nil`,
        // `installer(for:in:)` matched nothing, and `runtime offload` reported "NO installer in
        // library — export first" with the installer sitting right there. That is the whole point of
        // the command: it refuses to delete a runtime it cannot prove is recoverable, so an unparsed
        // name silently blocks every offload. Found by running the real export, not the fixtures —
        // the test fixtures used hand-written display names and passed throughout.
        // The same platform vocabulary is spelled out in `installer(for:in:)`; keep the two in step.
        let sdkNames = [
            "iphonesimulator": "iOS", "watchsimulator": "watchOS", "appletvsimulator": "tvOS",
            "xrsimulator": "visionOS", "visionsimulator": "visionOS",
        ]
        let platform = parts.first { platforms.contains($0) } ?? parts.lazy.compactMap { sdkNames[$0.lowercased()] }.first
        let version = parts.first { $0.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil }
        let build = parts.first { $0.range(of: #"^\d{2}[A-Z]\d{2,4}[a-z]?$"#, options: .regularExpression) != nil }
        return (platform, version, build)
    }
}

public struct RuntimeOperationError: DescribedError, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Apple's supported runtime mechanisms, driven end to end with feature detection and
/// journaling. Nothing here touches the MobileAsset store directly; every change goes through
/// `simctl` or `xcodebuild` (CLAUDE.md rule 2, research F1/F2).
public struct RuntimeOperations: Sendable {
    public var runner: CommandRunning
    public var journal: Journal
    public var xcode: XcodeInstallation
    public var host: HostEnvironment

    public init(runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal(), xcode: XcodeInstallation, host: HostEnvironment) {
        self.runner = runner; self.journal = journal; self.xcode = xcode; self.host = host
    }

    var xcodebuild: String { xcode.developerDirectory + "/usr/bin/xcodebuild" }
    var env: [String: String] { ["DEVELOPER_DIR": xcode.developerDirectory] }

    // MARK: delete (simctl runtime delete)

    /// Deletes an installed runtime through `simctl runtime delete`. `dryRun` asks simctl for its own dry run.
    @discardableResult
    public func delete(identifier: String, keepAsset: Bool = false, dryRun: Bool = false) throws -> CommandResult {
        guard xcode.capabilities.simctlRuntimeDelete else { throw RuntimeOperationError("This Xcode's simctl has no `runtime delete` verb.") }
        var args = ["simctl", "runtime", "delete", identifier]
        if dryRun { args.append("--dry-run") }
        if keepAsset { args.append("--keep-asset") }
        let op = UUID().uuidString
        if !dryRun {
            try journal.record(id: op, kind: .runtimeDelete, state: .started, summary: "simctl runtime delete \(identifier)\(keepAsset ? " --keep-asset" : "")")
        }
        let r = try runner.run(Tools.xcrun, args, environment: env)
        if !dryRun {
            try journal.record(
                id: op, kind: .runtimeDelete, state: r.succeeded ? .completed : .failed,
                summary: r.succeeded ? "deleted \(identifier)" : "failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard r.succeeded else { throw CommandError(executable: Tools.xcrun, arguments: args, result: r, underlying: nil) }
        return r
    }

    // MARK: export (xcodebuild -downloadPlatform … -exportPath)

    public struct ExportRequest: Sendable, Equatable {
        public var platform: String  // iOS | watchOS | tvOS | visionOS
        public var buildVersion: String?  // OS version, e.g. 26.5
        public var architectureVariant: String?  // universal | arm64
        public var destination: String
        public init(platform: String, buildVersion: String? = nil, architectureVariant: String? = nil, destination: String) {
            self.platform = platform; self.buildVersion = buildVersion; self.architectureVariant = architectureVariant; self.destination = destination
        }
    }

    /// `installedRuntimes` decides which of two very different cost stories the caller is told, so
    /// pass the real list whenever it is available (an empty list only loses the cheap-path note).
    /// True when `destination` sits under `/Volumes/<name>` and `<name>` is **not a mount point** —
    /// the shape macOS leaves behind when a volume goes away uncleanly and its mount-point directory
    /// survives as an ordinary directory on the internal disk. `fileExists` cannot tell that apart
    /// from the volume being mounted, and the difference is whether a 10 GB installer lands on the
    /// disk this operation exists to free.
    ///
    /// **Do not reimplement this as a `statfs` mount-point comparison.** The first version asked
    /// `MountStatus.filesystem(containing: destination)?.mountPoint == "/"` and was completely inert:
    /// `/Volumes` is a firmlink onto the Data volume, so `statfs` reports `/System/Volumes/Data` for
    /// it and for every ordinary directory inside it — never `/`. Measured on macOS 26.6.2:
    /// `/Volumes → /System/Volumes/Data`, `/ → /`. The condition was unsatisfiable for the only case
    /// it existed to catch, and its tests passed because they hand-built a `FilesystemInfo` that
    /// `statfs` cannot produce for any path under `/Volumes`.
    ///
    /// `ATTR_DIR_MOUNTSTATUS` asks the question directly, and `Doctor+Vault.checkLocationsPointAtPresentVolumes`
    /// already had this exact check. **Fails closed**: `isMountPoint` is false when the attribute
    /// cannot be read at all, so "I cannot tell whether a volume is mounted here" refuses. The cost
    /// of a wrong refusal is an error message; the cost of a wrong pass is 10.6 GB of shadow data.
    ///
    /// Both the literal path and its symlink-resolved form are checked: a symlink *into* a vault
    /// (`~/lib → /Volumes/VAULT/…`) never mentions `/Volumes` literally, while `/Volumes/<bootname>`
    /// — a symlink to `/` — never mentions it after resolution. Either shape alone misses one.
    public static func isNotOnAMountedVolume(destination: String, isMountPoint: (String) -> Bool = MountStatus.isMountPoint) -> Bool {
        let url = URL(fileURLWithPath: destination)
        // `standardizedFileURL` collapses `..`, `.`, doubled and trailing slashes — all of which
        // defeat a raw `hasPrefix`.
        // The literal spelling first, then the symlink-resolved one. `standardizedFileURL` on the
        // literal form is belt-and-braces: the resolved form standardizes too, so every `..`/`//`
        // shape tested is caught either way. It stays because the literal form is the *only* one that
        // sees a `/Volumes/<bootname>` symlink, and there it is the sole line of defence.
        for candidate in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path] {
            let parts = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // Case-insensitively, because the boot volume is case-insensitive by default and
            // `/volumes/VAULT/…` resolves there exactly as `/Volumes/VAULT/…` does.
            guard parts.count >= 2, parts[0].caseInsensitiveCompare("Volumes") == .orderedSame else { continue }
            if !isMountPoint("/" + parts[0] + "/" + parts[1]) { return true }
        }
        return false
    }

    // MARK: offload (the destructive one)

    /// Everything `preflightOffload` established, so `offload` re-derives nothing.
    ///
    /// The two halves are separate for the same reason `export` splits them: the checks have to be
    /// runnable, and printable, without performing the deletion. `offload` takes this value rather
    /// than the raw arguments precisely so it cannot be called on a request that was never checked.
    public struct OffloadPlan: Sendable, Equatable {
        public let identifier: String
        public let installerPath: String
        public let installerFileName: String
        public let installerSizeBytes: UInt64
        /// The volume UUID of the filesystem holding the installer, resolved at preflight (#26).
        ///
        /// The safety argument for `runtime offload` is "delete the installed runtime only because
        /// an installer exists to restore it from", and `doctor` re-states that argument to the
        /// user later — from the journal. Restating it from a **path** is what this field replaces.
        /// On a machine with two external drives, or with one that comes back as `/Volumes/VAULT 1`
        /// after an unclean eject and leaves the original mount-point directory behind, the path
        /// can resolve to a file that is not the installer this operation verified. `doctor` would
        /// then tell the user their devices are recoverable from an image nobody checked.
        ///
        /// The rest of the project already treats volume identity this way: `VaultVolume` is keyed
        /// by `volumeUUID` with a sentinel, and `MIGRATION_ENGINE.md` requires UUID + sentinel
        /// rather than `/Volumes/<name>` precisely because mount points are not identities. The
        /// offload path predates that discipline and was not brought in line when its policy moved
        /// into Core.
        ///
        /// Optional because the lookup can fail — a filesystem that reports no UUID, or a path that
        /// cannot be read. `nil` means "this entry predates the field, or the volume had no
        /// identity to record", and `Doctor` treats that as *unverifiable* rather than as matching.
        public let installerVolumeUUID: String?
        public let runtimeIdentifier: String?
        public let version: String?
        public let build: String?
        /// The installed runtime's size, when simctl reported one. A floor, not the total: deleting
        /// a runtime also drops its MobileAsset copy.
        public let sizeBytes: UInt64?

        /// Private on purpose, and `private` at type scope still reaches the extensions in this
        /// file — so `preflightOffload` can build one and nothing else in `XCodeVaultCore` can.
        ///
        /// Without this the implicit memberwise initialiser is `internal`: a review hand-built a
        /// plan naming `/nonexistent/never-checked.dmg`, passed it to `offload`, and it compiled.
        /// Every guard skipped, 12 GB deleted, and the journal recording `.completed` against an
        /// installer that was never there — which `Doctor` then reads as "merely unreachable" and
        /// reassures the user their Unavailable devices are recoverable. The doc below promised a
        /// capability the access level did not deliver.
        private init(
            identifier: String, installerPath: String, installerFileName: String, installerSizeBytes: UInt64,
            installerVolumeUUID: String?, runtimeIdentifier: String?, version: String?, build: String?, sizeBytes: UInt64?
        ) {
            self.identifier = identifier
            self.installerPath = installerPath
            self.installerFileName = installerFileName
            self.installerSizeBytes = installerSizeBytes
            self.installerVolumeUUID = installerVolumeUUID
            self.runtimeIdentifier = runtimeIdentifier
            self.version = version
            self.build = build
            self.sizeBytes = sizeBytes
        }

        /// The only way to make one, so a plan cannot exist without the checks that justify it.
        fileprivate static func checked(
            identifier: String, installer: RuntimeInstaller, runtime: SimulatorRuntime, installerVolumeUUID: String?
        ) -> OffloadPlan {
            OffloadPlan(
                identifier: identifier, installerPath: installer.path, installerFileName: installer.fileName,
                installerSizeBytes: installer.sizeBytes, installerVolumeUUID: installerVolumeUUID,
                runtimeIdentifier: runtime.runtimeIdentifier,
                version: runtime.version, build: runtime.build, sizeBytes: runtime.sizeBytes)
        }

        /// What goes in the journal. The runtime's identity, not just the image UUID — `doctor` has
        /// to decide whether an unavailable *device* is recoverable, and devices are keyed by
        /// `runtimeIdentifier`. Without it the only link is the installer's filename, which for an
        /// `.exportedBundle` is `…/Restore/WatchOSSimulatorRuntime_Cryptex.dmg` and carries neither
        /// platform nor version.
        public var journalDetail: [String: String] {
            [
                "runtimeIdentifier": runtimeIdentifier ?? "", "version": version ?? "", "build": build ?? "",
                "installer": installerPath,
                // The identity, alongside the path rather than instead of it: the path is what a
                // user needs in order to find the file, and the UUID is what `doctor` needs in
                // order to know the file at that path is the one this operation verified.
                "installerVolumeUUID": installerVolumeUUID ?? "",
            ].filter { !$0.value.isEmpty }
        }
    }

    /// Everything that must be true before the most destructive verb in the product runs.
    ///
    /// This is the verb that deletes 5–25 GB against a copy, and until 2026-09-18 all four of its
    /// guards lived in `Sources/xcodevaultctl`, an executable target no test can import — the
    /// `getgrouplist` pattern this project has already paid for once. Moving them here is the whole
    /// point of the change; the seams below exist so the guards can be exercised without a real
    /// multi-gigabyte image.
    ///
    /// The order matters and is not alphabetical:
    ///
    /// 1. **Is the library actually on a mounted volume?** First, because it is the only check whose
    ///    failure means the user's mental model is wrong rather than their arguments. With the drive
    ///    absent and a stale installer in a leftover `/Volumes` directory on the internal disk,
    ///    `library(at:)` lists it, `hdiutil imageinfo` reads it, and the runtime is deleted — a
    ///    source removed against a copy that is not where the user believes it is, on a disk that
    ///    just lost the space twice over. Rule 6.
    /// 2. **Is there an installer for this runtime?** Nothing may be deleted without one.
    /// 3. **Can `hdiutil` actually read it?** A file of the right name and size is not an image.
    ///
    /// - Parameters:
    ///   - isMountPoint: seam. `/Volumes` is root-owned, so an unmounted-volume directory cannot be
    ///     staged for real without privilege this tool refuses to take.
    ///   - listLibrary: seam, so a test needs no directory of multi-gigabyte files.
    ///   - imageIsReadable: seam for `hdiutil imageinfo`, so a test needs no real disk image.
    public func preflightOffload(
        identifier: String,
        library: String,
        installedRuntimes: [SimulatorRuntime],
        isMountPoint: (String) -> Bool = MountStatus.isMountPoint,
        listLibrary: (String) throws -> [RuntimeInstaller] = RuntimeOperations.library(at:),
        imageIsReadable: ((String) throws -> Bool)? = nil,
        volumeUUIDAt: (String) -> String? = MountStatus.volumeUUID(at:)
    ) throws -> (plan: OffloadPlan, warnings: [String]) {
        guard let rt = installedRuntimes.first(where: { $0.identifier == identifier }) else {
            throw RuntimeOperationError("No installed runtime with identifier \(identifier).")
        }
        guard !RuntimeOperations.isNotOnAMountedVolume(destination: library, isMountPoint: isMountPoint) else {
            throw RuntimeOperationError(
                "\(library) is under /Volumes but no volume is mounted there — most likely a mount-point directory left behind by an unclean eject. "
                    + "The runtime is NOT deleted. Reconnect the drive and check `xcodevaultctl volumes`.")
        }
        let lib = try listLibrary(library)
        guard let inst = RuntimeOperations.installer(for: rt, in: lib) else {
            let platformArg = rt.platformName == "iphone" ? "iOS" : rt.platformName
            throw RuntimeOperationError(
                "No installer for \(rt.platformName) \(rt.version ?? "?") in \(library). "
                    + "Run `xcodevaultctl runtime export \(platformArg) --to \(library)` first — the runtime is NOT deleted.")
        }
        let readable = try (imageIsReadable ?? defaultImageIsReadable)(inst.path)
        guard readable else {
            throw RuntimeOperationError("hdiutil cannot read \(inst.path); refusing to delete the installed runtime.")
        }
        var warnings: [String] = []
        if rt.sizeBytes == nil {
            warnings.append("simctl did not report this runtime's size, so how much this frees cannot be stated up front.")
        }
        // Resolved here, at preflight, and not at journal-write time: this is the moment the
        // installer was verified readable, so it is the moment whose answer the journal should
        // carry. A lookup done later would describe whatever is mounted then.
        let volumeUUID = volumeUUIDAt(inst.path)
        if volumeUUID == nil {
            warnings.append(
                "The filesystem holding \(inst.path) reports no volume UUID, so the journal cannot record which drive this "
                    + "installer is on. Two consequences, and the first is about this deletion rather than a later diagnosis: "
                    + "the runtime will be deleted without any check that the installer is still on the same drive it was verified "
                    + "on, and `doctor` will later be able to say the image is unreachable but not whether a file found at that "
                    + "path is the same one.")
        }
        return (
            OffloadPlan.checked(identifier: identifier, installer: inst, runtime: rt, installerVolumeUUID: volumeUUID),
            warnings
        )
    }

    private var defaultImageIsReadable: (String) throws -> Bool {
        { path in try self.runner.run(Tools.hdiutil, ["imageinfo", path]).succeeded }
    }

    /// Performs the offload a `preflightOffload` already authorised: journal `started`, delete,
    /// journal `completed` or `failed`.
    ///
    /// Takes a plan rather than an identifier so it cannot be reached without the checks, and
    /// records `failed` before rethrowing so a deletion that did not happen is not left looking
    /// like one that is still in flight.
    /// How the user said yes. A value rather than a `Bool` so it cannot be satisfied by a
    /// stray `true`, and so the journal can record *what* was agreed to.
    ///
    /// The refactor that moved this verb's guards into Core initially moved four of the five and
    /// left this one — the one that encodes user intent — behind in the target no test can
    /// import. Safety rule 5 is about explicit, specific user intent; a plan that records only
    /// what was *checked* does not record what was *agreed*.
    public enum OffloadConfirmation: Sendable, Equatable {
        case explicitUserIntent(recordedAs: String)
        var recorded: String {
            switch self {
            case .explicitUserIntent(let s): return s
            }
        }
    }

    @discardableResult
    public func offload(
        _ plan: OffloadPlan, confirmedByUser confirmation: OffloadConfirmation,
        volumeUUIDAt: (String) -> String? = MountStatus.volumeUUID(at:),
        isMountPoint: (String) -> Bool = MountStatus.isMountPoint
    ) throws -> CommandResult {
        // Re-validated here, not just in the preflight. `OffloadPlan` is `Sendable` and all-`let`
        // — designed to be held and passed — so "was true when checked" is not "is true now". In
        // the CLI that window is microseconds; in the SwiftUI app it is however long the
        // confirmation sheet is on screen, which is long enough for a drive to be bumped, a Mac
        // to sleep, or the vault to come back as `/Volumes/VAULT 1`. Deleting 12 GB against an
        // installer that moved, and then journaling `.completed` with the stale path, is exactly
        // the state `Doctor` reads as "merely disconnected, devices recoverable".
        let installerDirectory = (plan.installerPath as NSString).deletingLastPathComponent
        // The seam `preflightOffload` has had all along. Without it this guard was unkillable: every
        // test runs under `NSTemporaryDirectory()`, which is never a `/Volumes` path, so the
        // predicate was constantly false and deleting these four lines left the suite green — on the
        // guard defending "the vault was unplugged between the preflight and the confirmation",
        // which is the #26 family.
        guard !RuntimeOperations.isNotOnAMountedVolume(destination: installerDirectory, isMountPoint: isMountPoint) else {
            throw RuntimeOperationError(
                "\(installerDirectory) is no longer a mounted volume. Nothing was deleted — the runtime is intact. "
                    + "Reconnect the drive and run the offload again.")
        }
        guard try defaultImageIsReadable(plan.installerPath) else {
            throw RuntimeOperationError(
                "\(plan.installerPath) is no longer readable by hdiutil. Nothing was deleted — the runtime is intact.")
        }
        // **Same volume, not merely the same path** (issue #26, review finding F1).
        //
        // The two guards above re-check that *something* mounted is at that path and that it is a
        // readable image. Neither establishes it is the same drive the preflight verified, and that
        // is the whole safety argument for this verb: delete the installed runtime only because an
        // installer exists to restore it from. Between the preflight and here the vault can be
        // unplugged and another drive can mount at `/Volumes/VAULT` — or the vault itself can return
        // as `/Volumes/VAULT 1` after an unclean eject, leaving the old mount-point directory for
        // something else to occupy. A 900 MB readable `.dmg` belonging to somebody else satisfies
        // both guards, and then 12 GB is deleted against it.
        //
        // This is the one place the recorded identity can prevent a **loss** rather than a wrong
        // sentence later, so it refuses on anything short of a match: an identity that was recorded
        // and cannot be read now is not a match either. `notRecorded` proceeds — an entry from before
        // the field existed, or a filesystem that reports no UUID, and refusing there would break
        // offload on those machines for a check that was never possible.
        switch MountStatus.compareVolumeIdentity(recorded: plan.installerVolumeUUID, found: volumeUUIDAt(plan.installerPath)) {
        case .notRecorded, .matches:
            break
        case .differs(let recorded, let found):
            throw RuntimeOperationError(
                "\(plan.installerPath) is on a different volume than the one this offload verified (recorded \(recorded), found "
                    + "\(found)). Nothing was deleted — the runtime is intact. Most likely another drive is mounted at that path, or the "
                    + "vault returned under a different name; check `xcodevaultctl volumes`, reconnect the original drive and run the offload again.")
        case .unreadable(let recorded):
            throw RuntimeOperationError(
                "\(plan.installerPath) is on a volume whose identity cannot be read, and this offload recorded \(recorded). Nothing was "
                    + "deleted — the runtime is intact. Refusing rather than deleting against an installer that cannot be confirmed to be the "
                    + "one that was verified.")
        }
        let op = UUID().uuidString
        var detail = plan.journalDetail
        detail["confirmation"] = confirmation.recorded
        try journal.record(
            id: op, kind: .runtimeOffload, state: .started,
            summary: "offload \(plan.identifier) (installer \(plan.installerPath))", paths: [plan.installerPath], detail: detail)
        let result: CommandResult
        do {
            result = try delete(identifier: plan.identifier)
        } catch {
            // `delete` throws on a non-zero exit as well as on a launch failure, so this one arm
            // covers both. An earlier draft added a second `guard result.succeeded` below for the
            // non-zero case; it was unreachable, and unreachable safety code is the kind a later
            // reader trusts.
            try journal.record(
                id: op, kind: .runtimeOffload, state: .failed,
                summary: "offload \(plan.identifier) failed: \(error)", paths: [plan.installerPath], detail: detail)
            throw RuntimeOperationError(
                "Could not delete runtime \(plan.identifier): \(error). The installer at \(plan.installerPath) is untouched, "
                    + "so nothing has been lost — re-run once the cause is cleared.")
        }
        try journal.record(
            id: op, kind: .runtimeOffload, state: .completed,
            summary: "offloaded \(plan.identifier)", paths: [plan.installerPath], detail: detail)
        return result
    }

    /// Validates an export request against the installed Xcode and host. Returns warnings; throws on
    /// blockers. `isMountPoint` is a seam for tests only: `/Volumes` is root-owned, so an unmounted-volume
    /// directory cannot be staged for real without privilege this tool refuses to take.
    public func preflightExport(
        _ req: ExportRequest, freeBytesAtDestination: UInt64?, installedRuntimes: [SimulatorRuntime] = [],
        isMountPoint: (String) -> Bool = MountStatus.isMountPoint
    ) throws -> [String] {
        var w: [String] = []
        let caps = xcode.capabilities
        guard caps.downloadPlatform, caps.exportPath else {
            throw RuntimeOperationError("Xcode \(xcode.version) does not support `-downloadPlatform … -exportPath` (feature-detected).")
        }
        guard ["iOS", "watchOS", "tvOS", "visionOS"].contains(req.platform) else {
            throw RuntimeOperationError("Unknown platform \(req.platform); use iOS, watchOS, tvOS or visionOS.")
        }
        if req.buildVersion != nil && !caps.buildVersion {
            throw RuntimeOperationError("This Xcode rejects -buildVersion (feature-detected); omit it to get the matching runtime.")
        }
        if let a = req.architectureVariant {
            guard caps.architectureVariant else { throw RuntimeOperationError("This Xcode has no -architectureVariant flag.") }
            guard ["universal", "arm64"].contains(a) else { throw RuntimeOperationError("-architectureVariant must be universal or arm64.") }
            if a == "arm64" && !host.isAppleSilicon {
                w.append("arm64-only runtimes cannot run on an Intel Mac; exporting anyway (useful only for an Apple Silicon machine).")
            }
        } else if host.isAppleSilicon && caps.architectureVariant {
            w.append("Tip: -architectureVariant arm64 produces a materially smaller image on Apple Silicon (F2).")
        }
        // Ahead of the existence check on purpose. A leftover mount-point directory *does* exist, so
        // that check passes and the export proceeds onto the internal disk; and when the volume is
        // gone entirely, `statfs` fails, the predicate is false, and the existence check answers. So
        // this ordering only ever replaces a vaguer message with a more precise one.
        if RuntimeOperations.isNotOnAMountedVolume(destination: req.destination, isMountPoint: isMountPoint) {
            throw RuntimeOperationError(
                "\(req.destination) is under /Volumes but no volume is mounted there — most likely a mount-point directory left behind by an unclean "
                    + "eject, or a name that is not a volume at all. Exporting here would write the installer to the internal disk under a path that "
                    + "reads like a drive. Check `xcodevaultctl volumes`.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: req.destination, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeOperationError("Destination \(req.destination) is not an existing directory.")
        }
        guard FileManager.default.isWritableFile(atPath: req.destination) else {
            throw RuntimeOperationError("Destination \(req.destination) is not writable.")
        }
        // Rule 6: a path is not a volume. When an external volume goes away uncleanly, macOS can
        // leave its mount-point directory behind on the boot volume — and `fileExists` cannot tell
        // that apart from the volume being present. Writing a 10 GB runtime installer into that
        // leftover puts it on the internal disk, at a path that reads like the external drive, which
        // is the split-brain case in MIGRATION_ENGINE.md: the bytes are somewhere nobody will look
        // for them, and the disk this whole operation exists to free just lost 10 GB.
        //
        // Refused rather than warned, because the whole point of exporting is to move bytes OFF the
        // internal volume; doing the opposite silently defeats the operation. A destination genuinely
        // on the boot volume is still reachable by any path outside /Volumes.
        if let fs = MountStatus.filesystem(containing: req.destination) {
            w.append("Destination resolves to \(fs.mountPoint) (\(fs.typeName)\(fs.isReadOnly ? ", read-only" : "")).")
        }
        if let free = freeBytesAtDestination, free < 12_000_000_000 {
            w.append("Only \(ByteCount.format(free)) free at the destination; runtime images are 5–25 GB.")
        }
        // The internal cost of an export is not one number: it depends entirely on whether the
        // runtime is already installed, and the two cases differ by four orders of magnitude.
        // Telling every caller the expensive story is what this branch fixes — it was scaring users
        // away from the one operation that is nearly free, which is also the one that frees the most
        // space (export the installer to a vault, then `runtime offload`).
        let downloadWarning =
            "Observed on Xcode 26.5 (E11): for a runtime that is NOT already installed, `-downloadPlatform -exportPath` downloads, INSTALLS it on the internal volume, then exports a copy. "
            + "Peak internal use was ~7 GB for a 5 GB image, and the installed runtime stays until `runtime delete`/`runtime offload`."
        func warnIfTight(_ why: String) {
            if host.dataVolumeFreeBytes < 15_000_000_000 {
                w.append("Only \(ByteCount.format(host.dataVolumeFreeBytes)) free on the internal volume, and \(why) (E11). Watch for ENOSPC.")
            }
        }
        switch exportCost(req, among: installedRuntimes) {
        case .copyOut:
            w.append(
                "This exact runtime is already installed, so `-exportPath` should copy the sealed image out rather than downloading and installing it: internal use stays flat. "
                    + "Budget the space at the DESTINATION, not internally. Both measurements behind this — 1 MB peak for iOS 26.5 (E11) and a 10.6 GB export on 2026-09-08 "
                    + "with internal free unchanged (F11) — were run WITHOUT -buildVersion, i.e. in the case where the latest happened to be the installed build. "
                    + "The pinned-build path is inferred from those, not separately measured.")
        case .unknownDependsOnWhatIsLatest:
            // Never the cheap story on its own: without -buildVersion, `-downloadPlatform` fetches the
            // latest, and nothing local knows whether that is the build already installed. Saying
            // "internal use stays flat" here — and suppressing the ENOSPC warning with it — is how a
            // user with 3 GB free gets told a 10 GB download is free.
            let why =
                req.architectureVariant.map {
                    "\(req.platform) is installed, but -architectureVariant \($0) may name a different image than the one installed"
                } ?? "\(req.platform) is installed, but no -buildVersion was given and `-downloadPlatform` fetches the LATEST"
            w.append(
                "\(why). If what Xcode fetches is the image you already have, this is a copy-out and internal use stays flat; otherwise it is a full download "
                    + "that installs internally first. Nothing local can tell the two apart — measured behaviour exists only for the case where they coincided (F11)."
            )
            warnIfTight("this may turn out to be a download that stages through an install first")
        case .download:
            w.append(downloadWarning)
            warnIfTight("this runtime is not installed, so the export has to stage through an install first")
        }
        return w
    }

    /// What an export will actually cost internally. Three states, not two, because "I cannot tell"
    /// is a real answer here and collapsing it into "free" is the one mistake in this file that can
    /// fill a user's disk.
    public enum ExportCost: Sendable, Equatable {
        /// The exact runtime is installed: `-exportPath` copies the sealed image out, internal use flat.
        case copyOut
        /// Not installed: a download that installs internally first, then exports.
        case download
        /// The platform is installed but no `-buildVersion` was given, and `-downloadPlatform` fetches
        /// the *latest*. If the installed build is already the latest this is a copy-out; if Apple has
        /// since shipped a newer one it is a full download. Nothing local can distinguish the two.
        case unknownDependsOnWhatIsLatest
    }

    /// Matched on the runtime identifier's `.SimRuntime.<platform>-` segment rather than
    /// `platformIdentifier`, whose `platformName` renders `com.apple.platform.iphonesimulator` as
    /// "iphone" and would never equal "iOS". The trailing `-` keeps `iOS` from matching a
    /// hypothetical `iOSSomething` platform.
    ///
    /// A `buildVersion` narrows the match: exporting 26.4 while 26.5 is installed is a real download.
    /// It accepts either an OS version (`26.5`) or a build string (`23F77`), so both are compared.
    /// Version strings are also matched against the dashed form CoreSimulator uses in identifiers
    /// (`iOS-26-5`), which is why the dots are substituted rather than matched literally.
    func exportCost(_ req: ExportRequest, among runtimes: [SimulatorRuntime]) -> ExportCost {
        let marker = ".SimRuntime.\(req.platform)-"
        let matchingPlatform = runtimes.filter { $0.runtimeIdentifier?.contains(marker) == true }
        guard !matchingPlatform.isEmpty else { return .download }
        guard let want = req.buildVersion else { return .unknownDependsOnWhatIsLatest }
        let matched = matchingPlatform.first { r in
            guard let rid = r.runtimeIdentifier else { return false }
            // Three forms because `-buildVersion` accepts more than one: the dashed suffix
            // CoreSimulator encodes in the identifier (`iOS-26-5`), the OS version as reported
            // (`26.5`), and the build string (`23F77`).
            return rid.hasSuffix(marker.dropFirst(".SimRuntime.".count) + want.replacingOccurrences(of: ".", with: "-"))
                || r.version == want || r.build == want
        }
        guard let matched else { return .download }
        // An architecture variant is a third axis, and answering a three-axis question on two axes is
        // how the no-`-buildVersion` hole got here. `-architectureVariant arm64` against a universal
        // installed image is a different image, hence a real download — and `supportedArchitectures`
        // describes what the installed image *runs*, not which variant it *is*, so a variant request
        // is only ever "unknown" unless it is unambiguous.
        if let variant = req.architectureVariant {
            let archs = Set(matched.supportedArchitectures ?? [])
            let unambiguous = (variant == "arm64" && archs == ["arm64"]) || (variant == "universal" && archs.count > 1)
            if !unambiguous { return .unknownDependsOnWhatIsLatest }
        }
        return .copyOut
    }

    /// Runs the export. Long-running; the caller should stream progress. Journaled.
    @discardableResult
    public func export(_ req: ExportRequest) throws -> CommandResult {
        var args = ["-downloadPlatform", req.platform, "-exportPath", req.destination]
        if let b = req.buildVersion { args += ["-buildVersion", b] }
        if let a = req.architectureVariant { args += ["-architectureVariant", a] }
        let op = UUID().uuidString
        try journal.record(id: op, kind: .runtimeExport, state: .started, summary: "xcodebuild \(args.joined(separator: " "))", paths: [req.destination])
        let r = try runner.run(xcodebuild, args, environment: env)
        try journal.record(
            id: op, kind: .runtimeExport, state: r.succeeded ? .completed : .failed,
            summary: r.succeeded
                ? "exported \(req.platform) to \(req.destination)" : "failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))",
            paths: [req.destination])
        guard r.succeeded else { throw CommandError(executable: xcodebuild, arguments: args, result: r, underlying: nil) }
        return r
    }

    // MARK: import (xcodebuild -importPlatform)

    public func preflightImport(dmg: String) throws -> [String] {
        guard xcode.capabilities.importPlatform else {
            throw RuntimeOperationError("Xcode \(xcode.version) does not support -importPlatform (feature-detected).")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dmg), let size = attrs[.size] as? UInt64 else {
            throw RuntimeOperationError("\(dmg) does not exist.")
        }
        guard dmg.lowercased().hasSuffix(".dmg") else { throw RuntimeOperationError("\(dmg) is not a .dmg installer.") }
        var w: [String] = []
        // E11 (2026-09-06, refused): 10.3 GB free, 4.9 GB image, 5.8 GB peak consumed before CoreSimulator
        // refused with SimDiskImageError 14 "disk is almost full". E8c (2026-09-07, succeeded): 26.5 GB
        // free, same 4.9 GB image, 4.8 GB peak, clean import + functional boot probe. Peak is ≈1.0–1.2×
        // the image across both runs; require 1.5× + 2 GB (clears both measured peaks) and warn below
        // 2× + 2 GB.
        let need = size * 3 / 2 + 2_000_000_000
        if host.dataVolumeFreeBytes < need {
            throw RuntimeOperationError(
                "Installing needs internal staging space: image is \(ByteCount.format(size)), only \(ByteCount.format(host.dataVolumeFreeBytes)) free (want ≥ \(ByteCount.format(need))). Free space first (`xcodevaultctl clean`, `doctor` for stranded downloads)."
            )
        }
        if host.dataVolumeFreeBytes < size * 2 + 2_000_000_000 {
            w.append(
                "Internal free space is tight: the import copies the whole image internally before installing (measured 1.0–1.2× the image across two runs), and CoreSimulator refuses when the disk is 'almost full'."
            )
        }
        return w
    }

    @discardableResult
    public func importRuntime(dmg: String) throws -> CommandResult {
        let args = ["-importPlatform", dmg]
        let op = UUID().uuidString
        try journal.record(id: op, kind: .runtimeImport, state: .started, summary: "xcodebuild -importPlatform", paths: [dmg])
        let r = try runner.run(xcodebuild, args, environment: env)
        try journal.record(
            id: op, kind: .runtimeImport, state: r.succeeded ? .completed : .failed,
            summary: r.succeeded ? "imported \(dmg)" : "failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))", paths: [dmg])
        guard r.succeeded else { throw CommandError(executable: xcodebuild, arguments: args, result: r, underlying: nil) }
        return r
    }

    // MARK: library

    /// Lists installers: bare `.dmg` files and Xcode 26's `<sdk>_<version>_<build>.exportedBundle`
    /// directories (observed 2026-09-06: `-exportPath` writes a bundle whose
    /// `Restore/<Platform>SimulatorRuntime_Cryptex.dmg` is the image `-importPlatform` takes).
    public static func library(at dir: String) throws -> [RuntimeInstaller] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        var out: [RuntimeInstaller] = []
        for n in names {
            let p = dir + "/" + n
            if n.lowercased().hasSuffix(".dmg") {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
                let parsed = RuntimeInstaller.parse(fileName: n)
                out.append(
                    RuntimeInstaller(
                        path: p, fileName: n, sizeBytes: (attrs[.size] as? UInt64) ?? 0,
                        modifiedAt: (attrs[.modificationDate] as? Date) ?? .distantPast,
                        platform: parsed.platform, version: parsed.version, build: parsed.build))
            } else if n.hasSuffix(".exportedBundle") {
                let base = String(n.dropLast(".exportedBundle".count))
                let parts = base.split(separator: "_").map(String.init)
                let sdkToPlatform = ["iphonesimulator": "iOS", "appletvsimulator": "tvOS", "watchsimulator": "watchOS", "xrsimulator": "visionOS"]
                let platform = parts.first.flatMap { sdkToPlatform[$0.lowercased()] }
                let restore = p + "/Restore"
                guard let dmg = (try? FileManager.default.contentsOfDirectory(atPath: restore))?.first(where: { $0.hasSuffix("_Cryptex.dmg") }) else {
                    continue
                }
                let dmgPath = restore + "/" + dmg
                let attrs = try? FileManager.default.attributesOfItem(atPath: dmgPath)
                out.append(
                    RuntimeInstaller(
                        path: dmgPath, fileName: n, sizeBytes: DiskUsage.measure(p)?.allocatedBytes ?? 0,
                        modifiedAt: (attrs?[.modificationDate] as? Date) ?? .distantPast,
                        platform: platform, version: parts.count > 1 ? parts[1] : nil, build: parts.count > 2 ? parts[2] : nil))
            }
        }
        return out.sorted { ($0.platform ?? "", $0.version ?? "") < ($1.platform ?? "", $1.version ?? "") }
    }

    /// Finds an installer in the library matching an installed runtime (platform + version).
    public static func installer(for runtime: SimulatorRuntime, in library: [RuntimeInstaller]) -> RuntimeInstaller? {
        let platformMap = ["iphone": "iOS", "watch": "watchOS", "appletv": "tvOS", "xr": "visionOS", "vision": "visionOS"]
        guard let plat = platformMap[runtime.platformName], let ver = runtime.version else { return nil }
        return library.first {
            $0.platform?.caseInsensitiveCompare(plat) == .orderedSame && $0.version == ver && $0.sizeBytes > 500_000_000
                && ($0.build == nil || runtime.build == nil || $0.build == runtime.build)
        }
    }
}
