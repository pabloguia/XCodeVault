import Foundation

/// Xcode ▸ Settings ▸ Locations as user defaults. Mechanism reproduced on Xcode 26.5 — status
/// per COMPATIBILITY_MATRIX.md: DerivedData and Archives *probable*, compilation cache
/// *experimental*; none has met the Definition of Done yet
/// (docs/research/evidence/e8b-*.txt and docs/research/LOCATIONS-KEYS-2026-09-06.md):
/// - `IDECustomDerivedDataLocation`: honoured by xcodebuild; absolute = "Custom", a relative
///   value silently means "Relative to project", so we only ever write absolute paths.
/// - `IDECustomDistributionArchivesLocation`: honoured by `xcodebuild archive` (adds
///   `YYYY-MM-DD/<Scheme> <date>.xcarchive` under it).
/// - `IDECustomCompilationCacheLocation` (Xcode ≥ 26): honoured (`-cas-path <dir>/builtin`).
/// `IDEDerivedDataPathOverride` / `IDEArchivePathOverride` are per-invocation overrides and are
/// never persisted.
public struct XcodeLocations: Sendable, Codable, Equatable {
    public var derivedData: String?  // nil = default (~/Library/Developer/Xcode/DerivedData)
    public var buildLocationStyle: String?  // Unique (default) | Shared | Custom | DeterminedByTargets
    public var archives: String?  // nil = default (~/Library/Developer/Xcode/Archives)
    public var compilationCache: String?  // nil = default (<DerivedData>/CompilationCache.noindex), Xcode 26+

    public static let domain = "com.apple.dt.Xcode"
    public static let derivedDataKey = "IDECustomDerivedDataLocation"  // reproduced E8b (probable)
    public static let buildLocationStyleKey = "IDEBuildLocationStyle"  // observed E8
    public static let archivesKey = "IDECustomDistributionArchivesLocation"  // reproduced (LOCATIONS-KEYS report; probable)
    public static let compilationCacheKey = "IDECustomCompilationCacheLocation"  // reproduced (LOCATIONS-KEYS report); Xcode 26+, experimental

    public static func read(runner: CommandRunning = ProcessCommandRunner()) -> XcodeLocations {
        func get(_ k: String) -> String? {
            guard let r = try? runner.run(Tools.defaults, ["read", domain, k]), r.succeeded else { return nil }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v
        }
        return XcodeLocations(
            derivedData: get(derivedDataKey), buildLocationStyle: get(buildLocationStyleKey), archives: get(archivesKey),
            compilationCache: get(compilationCacheKey))
    }

    /// The four `com.apple.dt.Xcode` keys this tool owns.
    ///
    /// A closed enumeration rather than a `String` (issue #16). `Change.key` used to be a
    /// `public var String` written straight into `defaults write com.apple.dt.Xcode`, with nothing
    /// in the type saying which keys this tool may write. The rule was held by discipline at six
    /// call sites — and it had held; no caller ever passed an unowned key. But the value being
    /// free-form is what makes "hold it at six sites" the mechanism, and the domain being written
    /// is Xcode's entire preferences domain, where an unowned key is a setting of the user's that
    /// this tool has no business touching.
    ///
    /// With this, an unowned key cannot be *constructed*, so there is nothing to reject at write
    /// time. The four cases carry their own defaults key rather than the call sites naming
    /// `XcodeLocations.derivedDataKey` alongside a `Change`, which is how the two could disagree.
    public enum Key: String, Sendable, Equatable, CaseIterable, Codable {
        case derivedData
        case buildLocationStyle
        case archives
        case compilationCache

        /// The literal written to `defaults`. Deliberately a switch and not a raw value: the raw
        /// values are the short names used in journal entries and CLI output, and tying the two
        /// together would make renaming one silently rewrite a real Xcode preference key.
        public var defaultsKey: String {
            switch self {
            case .derivedData: return XcodeLocations.derivedDataKey
            case .buildLocationStyle: return XcodeLocations.buildLocationStyleKey
            case .archives: return XcodeLocations.archivesKey
            case .compilationCache: return XcodeLocations.compilationCacheKey
            }
        }
    }

    public struct Change: Sendable, Equatable {
        public var key: Key
        public var newValue: String?  // nil = delete (reset to default)
        public init(key: Key, newValue: String?) { self.key = key; self.newValue = newValue }
    }

    /// Preflight for pointing DerivedData at `path`. Returns warnings; throws on blockers.
    public static func preflightDerivedData(path: String?, volumes: [Volume], xcodeRunning: Bool, acknowledgeExternalTests: Bool) throws -> [String] {
        try preflightLocation(
            path: path, volumes: volumes, xcodeRunning: xcodeRunning, acknowledgeExternalTests: acknowledgeExternalTests, warnsAboutTests: true)
    }

    /// Preflight for the Archives root. The E2 test restriction does not apply to archiving. What
    /// Xcode does when the volume is absent at archive time is unverified (E6 pending).
    public static func preflightArchives(path: String?, volumes: [Volume], xcodeRunning: Bool) throws -> [String] {
        try preflightLocation(path: path, volumes: volumes, xcodeRunning: xcodeRunning, acknowledgeExternalTests: true, warnsAboutTests: false)
    }

    /// Refuses a resolved path that sits under a `/Volumes/<name>` which is not a mount point.
    ///
    /// Extracted so the rule can be tested on a literal. The alternative — injecting what a path
    /// "resolves to" — was tried and was a hole rather than a seam: it is not a relocation of the
    /// mount question but an off switch, because a resolver that never returns a `/Volumes/`
    /// prefix makes this branch not run at all. It also sat on the *public* archives entry point,
    /// the non-regenerable category, while `preflightDerivedData` did not carry it. A reviewer
    /// pointed out that this is backwards, and that the real resolution — `canonicalize` then
    /// `realpath`, which is what stops a symlink into `/Volumes` bypassing the check — was then
    /// itself unpinned, because every test passed a resolver instead of exercising it.
    ///
    /// `isMountPoint` stays injectable: staging a plain directory under `/Volumes` needs root,
    /// which this project refuses to take.
    static func shadowDataRefusal(resolved: String, isMountPoint: (String) -> Bool = MountStatus.isMountPoint) throws {
        guard resolved.hasPrefix("/Volumes/"),
            let name = resolved.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first
        else { return }
        let top = "/Volumes/" + name
        guard isMountPoint(top) else {
            throw RuntimeOperationError(
                "\(top) is a plain directory, not a mounted volume — pointing Xcode there would write shadow data to the internal disk. Connect the volume (and check `doctor`) first."
            )
        }
    }

    static func preflightLocation(path: String?, volumes: [Volume], xcodeRunning: Bool, acknowledgeExternalTests: Bool, warnsAboutTests: Bool) throws
        -> [String]
    {
        if xcodeRunning { throw RuntimeOperationError("Xcode.app is running; it caches Locations and may overwrite the change. Quit Xcode first.") }
        guard let path else { return [] }
        var isDir: ObjCBool = false
        guard path.hasPrefix("/") else { throw RuntimeOperationError("Use an absolute path.") }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeOperationError("\(path) is not an existing directory.")
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw RuntimeOperationError("\(path) is not writable.") }
        var w: [String] = []
        // Resolve symlinks before deciding where the path really lives (a symlink into /Volumes must not bypass the check).
        let resolved =
            (try? PathSafety.canonicalize(path)).flatMap {
                realpath($0, nil).map { r in
                    defer { free(r) }; return String(cString: r)
                }
            } ?? path
        // UNPINNED, knowingly — the call, not the rule.
        //
        // `shadowDataRefusal` itself is covered (both directions). Deleting THIS LINE fails no
        // test, because reaching the refusal through here needs a path that really resolves
        // under a `/Volumes/<name>` which is not a mount point, and staging one needs root.
        // That is the same constraint that left this guard with a skipping test in the first
        // place; extracting the rule moved the untestable part from the whole guard down to one
        // line, which is progress, not a fix. Said out loud rather than left for the next
        // mutation run.
        try shadowDataRefusal(resolved: resolved)
        let fs = MountStatus.filesystem(containing: path)
        if let fs, fs.typeName != "apfs" { w.append("\(path) is on a \(fs.typeName) filesystem; Xcode expects APFS/HFS+ semantics.") }
        let vol = volumes.first { $0.mountPoint == fs?.mountPoint }
        let external = (vol?.isExternal ?? false) || resolved.hasPrefix("/Volumes/")
        if external && warnsAboutTests {
            let msg =
                "DerivedData on an external physical volume: `xcodebuild test` fails to load test bundles there on macOS 26 (E2, reproduced) — unit tests will break for projects built here. Disk images and internal volumes are unaffected."
            guard acknowledgeExternalTests else { throw RuntimeOperationError(msg + " Re-run with --i-understand-tests-may-fail to proceed anyway.") }
            w.append(msg)
        }
        if external {
            w.append(
                "If this volume is disconnected, Xcode's behaviour is not yet verified (E6 pending): it may fail or recreate data locally. Run `xcodevaultctl doctor` after reconnecting to detect shadow data."
            )
        }
        if let vol, !vol.ownersEnabled { w.append("Ownership is ignored on \(vol.volumeName); enable it with `diskutil enableOwnership`.") }
        return w
    }

    /// Applies a change through `defaults` (which talks to cfprefsd correctly). Journaled.
    public static func apply(_ change: Change, runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal()) throws {
        let op = UUID().uuidString
        // One resolution of the key, used for the read, the journal and the write. Three separate
        // `change.key` reads would be three chances for them to name different keys.
        let key = change.key.defaultsKey
        let previous = (try? runner.run(Tools.defaults, ["read", domain, key]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try journal.record(
            id: op, kind: .xcodeLocationChange, state: .started, summary: "\(key) → \(change.newValue ?? "<default>")",
            detail: ["key": key, "previous": previous, "new": change.newValue ?? ""])
        let args = change.newValue.map { ["write", domain, key, "-string", $0] } ?? ["delete", domain, key]
        let r = try runner.run(Tools.defaults, args)
        try journal.record(id: op, kind: .xcodeLocationChange, state: r.succeeded ? .completed : .failed, summary: r.succeeded ? "applied" : r.stderr)
        guard r.succeeded else { throw CommandError(executable: Tools.defaults, arguments: args, result: r, underlying: nil) }
    }
}
