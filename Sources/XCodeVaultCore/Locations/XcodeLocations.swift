import Foundation

/// Xcode ▸ Settings ▸ Locations as user defaults. Verified on Xcode 26.5 (E8b evidence):
/// `IDECustomDerivedDataLocation` is honoured by `xcodebuild` (it creates ModuleCache.noindex,
/// CompilationCache.noindex, SDKStatCaches.noindex and per-project folders under it), and an
/// explicit `-derivedDataPath` still overrides it. Archive/compilation-cache keys are recorded
/// as they are verified; unverified keys are refused rather than guessed.
public struct XcodeLocations: Sendable, Codable, Equatable {
    public var derivedData: String?          // nil = default (~/Library/Developer/Xcode/DerivedData)
    public var buildLocationStyle: String?   // Shared | Unique | Custom | … (informational)
    public var archives: String?             // nil = default (~/Library/Developer/Xcode/Archives)

    public static let domain = "com.apple.dt.Xcode"
    public static let derivedDataKey = "IDECustomDerivedDataLocation"       // verified E8b
    public static let buildLocationStyleKey = "IDEBuildLocationStyle"       // observed E8
    public static let archivesKey = "IDECustomDistributionArchivesLocation" // unverified — read-only until proven

    public static func read(runner: CommandRunning = ProcessCommandRunner()) -> XcodeLocations {
        func get(_ k: String) -> String? {
            guard let r = try? runner.run(Tools.defaults, ["read", domain, k]), r.succeeded else { return nil }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v
        }
        return XcodeLocations(derivedData: get(derivedDataKey), buildLocationStyle: get(buildLocationStyleKey), archives: get(archivesKey))
    }

    public struct Change: Sendable, Equatable {
        public var key: String
        public var newValue: String?   // nil = delete (reset to default)
        public init(key: String, newValue: String?) { self.key = key; self.newValue = newValue }
    }

    /// Preflight for pointing DerivedData at `path`. Returns warnings; throws on blockers.
    public static func preflightDerivedData(path: String?, volumes: [Volume], xcodeRunning: Bool, acknowledgeExternalTests: Bool) throws -> [String] {
        if xcodeRunning { throw RuntimeOperationError("Xcode.app is running; it caches Locations and may overwrite the change. Quit Xcode first.") }
        guard let path else { return [] }
        var isDir: ObjCBool = false
        guard path.hasPrefix("/") else { throw RuntimeOperationError("Use an absolute path.") }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw RuntimeOperationError("\(path) is not an existing directory.") }
        guard FileManager.default.isWritableFile(atPath: path) else { throw RuntimeOperationError("\(path) is not writable.") }
        var w: [String] = []
        let fs = MountStatus.filesystem(containing: path)
        if let fs, fs.typeName != "apfs" { w.append("\(path) is on a \(fs.typeName) filesystem; Xcode expects APFS/HFS+ semantics.") }
        let vol = volumes.first { $0.mountPoint == fs?.mountPoint }
        let external = (vol?.isExternal ?? false) || path.hasPrefix("/Volumes/")
        if external {
            let msg = "DerivedData on an external physical volume: `xcodebuild test` fails to load test bundles there on macOS 26 (E2, reproduced) — unit tests will break for projects built here. Disk images and internal volumes are unaffected."
            guard acknowledgeExternalTests else { throw RuntimeOperationError(msg + " Re-run with --i-understand-tests-may-fail to proceed anyway.") }
            w.append(msg)
        }
        if let vol, !vol.ownersEnabled { w.append("Ownership is ignored on \(vol.volumeName); enable it with `diskutil enableOwnership`.") }
        return w
    }

    /// Applies a change through `defaults` (which talks to cfprefsd correctly). Journaled.
    public static func apply(_ change: Change, runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal()) throws {
        let op = UUID().uuidString
        let previous = (try? runner.run(Tools.defaults, ["read", domain, change.key]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try journal.record(id: op, kind: .xcodeLocationChange, state: .started, summary: "\(change.key) → \(change.newValue ?? "<default>")",
                           detail: ["key": change.key, "previous": previous, "new": change.newValue ?? ""])
        let args = change.newValue.map { ["write", domain, change.key, "-string", $0] } ?? ["delete", domain, change.key]
        let r = try runner.run(Tools.defaults, args)
        try journal.record(id: op, kind: .xcodeLocationChange, state: r.succeeded ? .completed : .failed, summary: r.succeeded ? "applied" : r.stderr)
        guard r.succeeded else { throw CommandError(executable: Tools.defaults, arguments: args, result: r, underlying: nil) }
    }
}
