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

public struct RuntimeOperationError: Error, CustomStringConvertible, Sendable {
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
                    + "that installs internally first. Nothing local can tell the two apart — measured behaviour exists only for the case where they coincided (F11).")
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
                guard let dmg = (try? FileManager.default.contentsOfDirectory(atPath: restore))?.first(where: { $0.hasSuffix("_Cryptex.dmg") }) else { continue }
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
