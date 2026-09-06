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
        let platform = parts.first { platforms.contains($0) }
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

    /// Validates an export request against the installed Xcode and host. Returns warnings; throws on blockers.
    public func preflightExport(_ req: ExportRequest, freeBytesAtDestination: UInt64?) throws -> [String] {
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: req.destination, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeOperationError("Destination \(req.destination) is not an existing directory.")
        }
        guard FileManager.default.isWritableFile(atPath: req.destination) else {
            throw RuntimeOperationError("Destination \(req.destination) is not writable.")
        }
        if let free = freeBytesAtDestination, free < 12_000_000_000 {
            w.append("Only \(ByteCount.format(free)) free at the destination; runtime images are 5–25 GB.")
        }
        if host.dataVolumeFreeBytes < 15_000_000_000 {
            w.append(
                "Only \(ByteCount.format(host.dataVolumeFreeBytes)) free on the internal volume. Downloads may stage internally before export (E11 — unverified); watch for ENOSPC."
            )
        }
        return w
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
        // E11: installation stages on the internal volume. Require headroom of at least 2× the image (reported need ~40 GB for a 9–12 GB runtime).
        let need = size * 2
        if host.dataVolumeFreeBytes < need {
            throw RuntimeOperationError(
                "Installing needs internal staging space: image is \(ByteCount.format(size)), only \(ByteCount.format(host.dataVolumeFreeBytes)) free (want ≥ \(ByteCount.format(need))). Free space first (`xcodevaultctl clean`)."
            )
        }
        if host.dataVolumeFreeBytes < size * 4 {
            w.append(
                "Internal free space is tight for staging (\(ByteCount.format(host.dataVolumeFreeBytes))); the reported requirement is ~40 GB for a 9–12 GB runtime (E11, unverified)."
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

    public static func library(at dir: String) throws -> [RuntimeInstaller] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        var out: [RuntimeInstaller] = []
        for n in names where n.lowercased().hasSuffix(".dmg") {
            let p = dir + "/" + n
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
            let parsed = RuntimeInstaller.parse(fileName: n)
            out.append(
                RuntimeInstaller(
                    path: p, fileName: n, sizeBytes: (attrs[.size] as? UInt64) ?? 0,
                    modifiedAt: (attrs[.modificationDate] as? Date) ?? .distantPast,
                    platform: parsed.platform, version: parsed.version, build: parsed.build))
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
