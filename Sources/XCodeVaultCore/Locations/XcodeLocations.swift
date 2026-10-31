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
    /// RelativeToDerivedData | RelativeToWorkspace | Absolute. Nil is Xcode's own default for the style in use.
    public var buildLocationType: String?
    /// Absolute products directory when the split is in use. Nil means products stay inside DerivedData.
    public var buildProducts: String?
    /// Absolute intermediates directory when the split is in use. Nil means they follow the products path.
    public var buildIntermediates: String?
    public var archives: String?  // nil = default (~/Library/Developer/Xcode/Archives)
    public var compilationCache: String?  // nil = default (<DerivedData>/CompilationCache.noindex), Xcode 26+

    public static let domain = "com.apple.dt.Xcode"
    public static let derivedDataKey = "IDECustomDerivedDataLocation"  // reproduced E8b (probable)
    public static let buildLocationStyleKey = "IDEBuildLocationStyle"  // observed E8
    public static let buildLocationTypeKey = "IDECustomBuildLocationType"  // LOCATIONS-KEYS; the split writes Absolute
    public static let buildProductsKey = "IDECustomBuildProductsPath"  // LOCATIONS-KEYS; the SYMROOT equivalent
    public static let buildIntermediatesKey = "IDECustomBuildIntermediatesPath"  // LOCATIONS-KEYS
    public static let archivesKey = "IDECustomDistributionArchivesLocation"  // reproduced (LOCATIONS-KEYS report; probable)
    public static let compilationCacheKey = "IDECustomCompilationCacheLocation"  // reproduced (LOCATIONS-KEYS report); Xcode 26+, experimental
    /// What the split writes. Custom is the only style that lets products leave DerivedData (LOCATIONS-KEYS).
    public static let customBuildLocationStyle = "Custom"
    public static let absoluteBuildLocationType = "Absolute"
    /// Journal detail for a split, so a later split or a reset can put the build location style back.
    public static let splitLayout = "split"
    /// The CLI flag for the residual risk. Not the whole-folder tests flag: that risk is a different layout.
    public static let splitAcknowledgementFlag = "--i-understand-the-split-is-experimental"

    public static func read(runner: CommandRunning = ProcessCommandRunner()) -> XcodeLocations {
        func get(_ k: String) -> String? {
            guard let r = try? runner.run(Tools.defaults, ["read", domain, k]), r.succeeded else { return nil }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v
        }
        return XcodeLocations(
            derivedData: get(derivedDataKey), buildLocationStyle: get(buildLocationStyleKey), buildLocationType: get(buildLocationTypeKey),
            buildProducts: get(buildProductsKey), buildIntermediates: get(buildIntermediatesKey), archives: get(archivesKey),
            compilationCache: get(compilationCacheKey))
    }

    /// The `com.apple.dt.Xcode` keys this tool owns.
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
    /// time. Each case carries its own defaults key rather than the call sites naming
    /// `XcodeLocations.derivedDataKey` alongside a `Change`, which is how the two could disagree.
    /// The three build-location cases exist for the measured split (H19): products leave DerivedData,
    /// so the style has to be Custom and the type Absolute, and intermediates have to be named or
    /// they follow the products onto the internal disk. Whole-folder DerivedData relocation does not
    /// write them.
    public enum Key: String, Sendable, Equatable, CaseIterable, Codable {
        case derivedData
        case buildLocationStyle
        case buildLocationType
        case buildProducts
        case buildIntermediates
        case archives
        case compilationCache

        /// The literal written to `defaults`. Deliberately a switch and not a raw value: the raw
        /// values are the short names used in journal entries and CLI output, and tying the two
        /// together would make renaming one silently rewrite a real Xcode preference key.
        public var defaultsKey: String {
            switch self {
            case .derivedData: return XcodeLocations.derivedDataKey
            case .buildLocationStyle: return XcodeLocations.buildLocationStyleKey
            case .buildLocationType: return XcodeLocations.buildLocationTypeKey
            case .buildProducts: return XcodeLocations.buildProductsKey
            case .buildIntermediates: return XcodeLocations.buildIntermediatesKey
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
                "\(top) is a plain directory, not a mounted volume — pointing Xcode there would write shadow data to the internal disk. Connect the volume "
                    + "(and check `doctor`) first."
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
        // A volume that could not be placed is treated as external: the warnings below are the ones to see (#54 review).
        let where_ = placement(resolved: resolved, volumes: volumes)
        let external = where_ != .thisMac
        if where_ == .unknown {
            w.append("Could not tell whether \(path) is on this Mac or on an external volume (its volume is not listed and is not this Mac's), so it is treated as external.")
        }
        if external && warnsAboutTests {
            let msg =
                "DerivedData on an external physical volume: `xcodebuild test` fails to load test bundles there on macOS 26 (reproduced here) — unit tests "
                + "will break for projects built here. Disk images and internal volumes are unaffected."
            guard acknowledgeExternalTests else { throw RuntimeOperationError(msg + " Re-run with --i-understand-tests-may-fail to proceed anyway.") }
            w.append(msg)
        }
        if external {
            w.append(
                "If this volume is disconnected, Xcode's behaviour has not been tested yet: it may fail or recreate data locally. Run `xcodevaultctl doctor` "
                    + "after reconnecting to detect shadow data."
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
        // A read that could not run says nothing about the previous value, so no `previous` is recorded for it (R3
        // review): an empty one would read as "the default", which nothing established.
        let read = try? runner.run(Tools.defaults, ["read", domain, key])
        var detail = ["key": key, "new": change.newValue ?? ""]
        if let read { detail["previous"] = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        try journal.record(
            id: op, kind: .xcodeLocationChange, state: .started, summary: "\(key) → \(change.newValue ?? "<default>")",
            detail: detail)
        let args = change.newValue.map { ["write", domain, key, "-string", $0] } ?? ["delete", domain, key]
        let r: CommandResult
        do {
            r = try runner.run(Tools.defaults, args)
        } catch {
            // A write that could not start is a failure, not an operation left `started` (R3 review).
            try journal.record(id: op, kind: .xcodeLocationChange, state: .failed, summary: "\(error)")
            throw error
        }
        try journal.record(id: op, kind: .xcodeLocationChange, state: r.succeeded ? .completed : .failed, summary: r.succeeded ? "applied" : r.stderr)
        guard r.succeeded else { throw CommandError(executable: Tools.defaults, arguments: args, result: r, underlying: nil) }
    }

    /// The measured layout (H19, probable): bulky build data on the external folder, test products on this Mac.
    ///
    /// Index and module cache follow `IDECustomDerivedDataLocation`, so they are not separate keys. Intermediates
    /// are an absolute path under the external folder: with Custom + Absolute they would otherwise follow the
    /// products onto the internal disk. E19 measured the directories with `xcodebuild` overrides. These Locations
    /// keys are the same settings, and saving them was not part of that measurement.
    public struct DerivedDataSplit: Sendable, Equatable {
        public var bulk: String
        public var products: String
        public var intermediates: String

        public init(bulk: String, products: String) {
            self.bulk = bulk
            self.products = products
            self.intermediates = URL(fileURLWithPath: bulk, isDirectory: true).appendingPathComponent("Intermediates", isDirectory: true).path
        }

        /// The five keys the split writes. Whole-folder relocation writes only `.derivedData`.
        public var changes: [Change] {
            [
                Change(key: .derivedData, newValue: bulk),
                Change(key: .buildLocationStyle, newValue: XcodeLocations.customBuildLocationStyle),
                Change(key: .buildLocationType, newValue: XcodeLocations.absoluteBuildLocationType),
                Change(key: .buildProducts, newValue: products),
                Change(key: .buildIntermediates, newValue: intermediates),
            ]
        }
    }

    /// What a split changed, so Undo can put every key back. An empty `previous` entry is not used: a missing key
    /// is in `unset` and is deleted.
    public struct SplitRestore: Sendable, Equatable {
        public var previous: [String: String]
        public var unset: [String]

        public init(previous: [String: String], unset: [String]) {
            self.previous = previous
            self.unset = unset
        }

        public var changes: [Change] {
            var out: [Change] = []
            for key in Key.allCases {
                let name = key.defaultsKey
                if let value = previous[name] {
                    out.append(Change(key: key, newValue: value))
                } else if unset.contains(name) {
                    out.append(Change(key: key, newValue: nil))
                }
            }
            return out
        }
    }

    /// The usual products folder on this Mac: `~/Library/Developer/Xcode/Products`, expanded. The CLI and the Run
    /// sheet both offer this path. Nothing creates it except `productsDirectory(createIfMissing: true)`, and only
    /// when its parent already exists and is not on an external volume.
    public static func suggestedProductsDirectory(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        (home as NSString).appendingPathComponent("Library/Developer/Xcode/Products")
    }

    /// The products folder a split uses. `chosen` nil means `suggestedProductsDirectory`. That folder is created
    /// only when `createIfMissing` is true — the CLI command and the app's Run. The sheet reads
    /// `suggestedProductsDirectory` and passes false here, so opening it does not create the directory. A folder
    /// the user chose is never created. The usual folder is refused when its parent is on an external volume.
    public static func productsDirectory(
        chosen: String?, createIfMissing: Bool, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> String {
        let suggested = suggestedProductsDirectory(home: home)
        if let chosen, !sameDirectory(chosen, suggested) { return chosen }
        if createIfMissing { return try ensureProductsDirectory(home: home) }
        try validateSuggestedProductsParent(home: home)
        return suggested
    }

    /// Makes the usual products folder when the user did not pass one. Refuses to create it on an external volume
    /// or when `~/Library/Developer/Xcode` is missing: that parent is Xcode's, and this does not invent it.
    public static func ensureProductsDirectory(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        let products = suggestedProductsDirectory(home: home)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: products, isDirectory: &isDir) {
            guard isDir.boolValue else { throw RuntimeOperationError("\(products) exists and is not a folder.") }
            return products
        }
        try validateSuggestedProductsParent(home: home)
        try FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: false)
        return products
    }

    /// The usual products folder may be missing until Run. Its parent has to exist, be writable, and sit on this Mac.
    private static func validateSuggestedProductsParent(home: String) throws {
        let products = suggestedProductsDirectory(home: home)
        let parent = (products as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue, FileManager.default.isWritableFile(atPath: parent) else {
            throw RuntimeOperationError(
                "Choose a folder on this Mac with --products. \(products) is not there, and \(parent) is missing or not writable.")
        }
        let resolvedParent = resolve(parent)
        switch placement(resolved: resolvedParent, volumes: []) {
        case .thisMac: break
        case .external:
            throw RuntimeOperationError("\(products) would be on an external volume. Built test products have to stay on this Mac. Pass --products.")
        case .unknown:
            throw RuntimeOperationError(
                "Cannot tell whether \(products) would be on this Mac: its volume is not this Mac's and could not be read. Built test products have to stay on this Mac. Pass --products.")
        }
    }

    /// Preflight for the split. Returns the warnings the user has to see; throws on a blocker.
    ///
    /// `pathIsExternal` stands in for the real check (`placement(resolved:volumes:)`) when a test passes a literal.
    /// The placement rule itself is `splitPlacementProblem`, which does not touch the disk.
    public static func preflightDerivedDataSplit(
        bulk: String, products: String, volumes: [Volume], xcodeRunning: Bool, acknowledgeExperimental: Bool,
        pathIsExternal decide: ((String) -> Bool)? = nil, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> [String] {
        if xcodeRunning { throw RuntimeOperationError("Xcode.app is running; it caches Locations and may overwrite the change. Quit Xcode first.") }
        try requireDirectory(bulk)
        try acceptProductsDirectory(products, home: home)
        let bulkResolved = resolve(bulk)
        let productsResolved = resolveForPlacement(products)
        try shadowDataRefusal(resolved: bulkResolved)
        try shadowDataRefusal(resolved: productsResolved)
        let place: (String) -> Placement = decide.map { d in { d($0) ? .external : .thisMac } } ?? { placement(resolved: $0, volumes: volumes) }
        if let problem = splitPlacementProblem(
            bulk: place(bulkResolved), products: place(productsResolved),
            productsInsideBulk: productsSitInsideBulk(products: productsResolved, bulk: bulkResolved))
        {
            throw RuntimeOperationError(problem)
        }
        guard acknowledgeExperimental else { throw RuntimeOperationError(splitExperimentalRefusal) }
        var w: [String] = [
            "Built test products stay in \(products) on this Mac. DerivedData, intermediates, the index and the module cache go to \(bulk).",
            "My Mac framework tests were measured to pass only with this split. Pointing the whole DerivedData folder at the drive still breaks them.",
            "Experimental. Measured once with xcodebuild on one Intel Mac. Saving these Locations settings was not part of that measurement. "
                + "A project's own location settings can override this, and a disconnected drive has not been tested.",
        ]
        for path in [bulk, products] {
            if let fs = MountStatus.filesystem(containing: path), fs.typeName != "apfs" {
                w.append("\(path) is on a \(fs.typeName) filesystem; Xcode expects APFS/HFS+ semantics.")
            }
        }
        let fs = MountStatus.filesystem(containing: bulk)
        if let vol = volumes.first(where: { $0.mountPoint == fs?.mountPoint }) {
            if !vol.ownersEnabled { w.append("Ownership is ignored on \(vol.volumeName); enable it with `diskutil enableOwnership`.") }
            w.append(
                "If this volume is disconnected, Xcode's behaviour has not been tested yet: it may fail or recreate data locally. Run `xcodevaultctl doctor` "
                    + "after reconnecting to detect shadow data.")
        }
        return w
    }

    /// Where the two folders have to sit, when either could not be placed: neither side is guessed (#54 review).
    static func splitPlacementProblem(bulk: Placement, products: Placement, productsInsideBulk: Bool) -> String? {
        if bulk == .unknown {
            return "Cannot tell whether the bulky build data folder is on the external drive: its volume is not this Mac's and could not be read."
        }
        if products == .unknown {
            return "Cannot tell whether the built test products folder is on this Mac: its volume is not this Mac's and could not be read. "
                + "Built test products have to stay on this Mac."
        }
        return splitPlacementProblem(bulkExternal: bulk == .external, productsExternal: products == .external, productsInsideBulk: productsInsideBulk)
    }

    /// Where the two folders have to sit. Nil when the layout is the one that was measured.
    static func splitPlacementProblem(bulkExternal: Bool, productsExternal: Bool, productsInsideBulk: Bool) -> String? {
        if !bulkExternal { return "The bulky build data has to be a folder on the external drive. This folder is on this Mac." }
        if productsExternal {
            return
                "Built test products have to stay on this Mac. That folder is on an external volume, and My Mac framework tests fail to load a test bundle from there."
        }
        if productsInsideBulk {
            return "Built test products cannot sit inside the external DerivedData folder, or the test bundle ends up on the drive."
        }
        return nil
    }

    static func productsSitInsideBulk(products: String, bulk: String) -> Bool {
        let p = URL(fileURLWithPath: products).standardizedFileURL.path
        let b = URL(fileURLWithPath: bulk).standardizedFileURL.path
        return p == b || p.hasPrefix(b + "/")
    }

    /// Where a path lives: on this Mac, on an external volume, or unknown.
    enum Placement: Equatable { case thisMac, external, unknown }

    /// A `/Volumes/` path is external even when the volume list has not caught up. Anything else is placed by the
    /// filesystem that serves it: the listed volume says which, and an unlisted one is this Mac's only when it is the
    /// boot volume (`/`, or its data volume at `/System/Volumes/Data`). Any other unlisted mount — a volume `diskutil`
    /// could not read, mounted outside `/Volumes` — is `.unknown`, never this Mac's (review of #54). A path that does not
    /// exist yet is placed by its nearest existing parent; one that cannot be looked at (not `ENOENT`) is `.unknown`.
    static func placement(
        resolved: String, volumes: [Volume], filesystemAt: (String) -> MountStatus.FilesystemInfo? = MountStatus.filesystem(containing:)
    ) -> Placement {
        if resolved.hasPrefix("/Volumes/") { return .external }
        var path = resolved
        var st = stat()
        while lstat(path, &st) != 0 {
            guard errno == ENOENT, path != "/" else { return .unknown }
            path = (path as NSString).deletingLastPathComponent
            if path.isEmpty { return .unknown }
        }
        guard let fs = filesystemAt(path) else { return .unknown }
        if let listed = volumes.first(where: { $0.mountPoint == fs.mountPoint }) { return listed.isExternal ? .external : .thisMac }
        return fs.mountPoint == "/" || fs.mountPoint == "/System/Volumes/Data" ? .thisMac : .unknown
    }

    static let splitExperimentalRefusal =
        "This split is experimental. My Mac framework tests were measured to pass only with built test products on the internal disk and DerivedData, "
        + "intermediates, the index and the module cache on the external drive, using xcodebuild. Saving that layout in Xcode's Locations settings was not "
        + "part of the measurement. A project's own location settings can override it, and a disconnected drive has not been tested. Re-run with "
        + splitAcknowledgementFlag + "."

    /// Writes the split. Creates `Intermediates` under the external folder before any defaults write, and journals
    /// the previous value of every key so a second split still restores the style from before the first one.
    @discardableResult
    public static func apply(_ split: DerivedDataSplit, runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal()) throws -> SplitRestore {
        try ensureIntermediates(split)
        return try apply(split.changes, layout: splitLayout, runner: runner, journal: journal, tolerateMissingDelete: false)
    }

    /// Clears the DerivedData location and the split's build-location keys. The build location style goes back to
    /// the value recorded before the split, when there is one. Without that record the style is left alone: deleting
    /// it would mean Unique, which is not what a Mac already set to Shared had.
    @discardableResult
    public static func resetDerivedData(runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal()) throws -> SplitRestore {
        var changes = [
            Change(key: Key.derivedData, newValue: nil), Change(key: Key.buildLocationType, newValue: nil), Change(key: Key.buildProducts, newValue: nil),
            Change(key: Key.buildIntermediates, newValue: nil),
        ]
        if let recorded = try recordedStyleBeforeSplit(journal: journal) {
            switch recorded {
            case .unset: changes.append(Change(key: .buildLocationStyle, newValue: nil))
            case .value(let style): changes.append(Change(key: .buildLocationStyle, newValue: style))
            }
        }
        return try apply(changes, layout: "reset", runner: runner, journal: journal, tolerateMissingDelete: true)
    }

    /// Puts a split's keys back. `tolerateMissingDelete` because a key Undo deletes may already be gone.
    @discardableResult
    public static func restore(_ restore: SplitRestore, runner: CommandRunning = ProcessCommandRunner(), journal: Journal = Journal()) throws -> SplitRestore {
        try apply(restore.changes, layout: "undo", runner: runner, journal: journal, tolerateMissingDelete: true)
    }

    @discardableResult
    static func apply(
        _ changes: [Change], layout: String, runner: CommandRunning, journal: Journal, tolerateMissingDelete: Bool
    ) throws -> SplitRestore {
        var previous: [String: String] = [:]
        var unset: [String] = []
        for change in changes {
            let name = change.key.defaultsKey
            if let value = readDefault(name, runner: runner) {
                previous[name] = value
            } else {
                unset.append(name)
            }
        }
        if layout == splitLayout, previous[buildLocationStyleKey] == customBuildLocationStyle, previous[buildProductsKey] != nil,
            let recorded = try recordedStyleBeforeSplit(journal: journal)
        {
            switch recorded {
            case .unset:
                previous.removeValue(forKey: buildLocationStyleKey)
                if !unset.contains(buildLocationStyleKey) { unset.append(buildLocationStyleKey) }
            case .value(let style):
                previous[buildLocationStyleKey] = style
                unset.removeAll { $0 == buildLocationStyleKey }
            }
        }
        let restore = SplitRestore(previous: previous, unset: unset)
        let op = UUID().uuidString
        var detail = ["layout": layout]
        for change in changes { detail["new." + change.key.defaultsKey] = change.newValue ?? "" }
        for (name, value) in previous { detail["previous." + name] = value }
        for name in unset { detail["unset." + name] = "1" }
        let summary = layout == splitLayout ? "derived data split" : layout
        try journal.record(id: op, kind: .xcodeLocationChange, state: .started, summary: summary, detail: detail)
        var written: [Change] = []
        do {
            for change in changes {
                try write(change, runner: runner, tolerateMissingDelete: tolerateMissingDelete)
                written.append(change)
            }
        } catch {
            let note = rollBack(written, previous: previous, runner: runner)
            try journal.record(id: op, kind: .xcodeLocationChange, state: .failed, summary: "\(error)\(note)")
            throw error
        }
        try journal.record(id: op, kind: .xcodeLocationChange, state: .completed, summary: "applied", detail: detail)
        return restore
    }

    private enum RecordedStyle { case unset, value(String) }

    private static func recordedStyleBeforeSplit(journal: Journal) throws -> RecordedStyle? {
        let done = try journal.entries().filter { $0.kind == .xcodeLocationChange && $0.state == .completed && $0.detail["layout"] == splitLayout }
        guard let last = done.last else { return nil }
        if last.detail["unset." + buildLocationStyleKey] == "1" { return .unset }
        if let value = last.detail["previous." + buildLocationStyleKey], !value.isEmpty { return .value(value) }
        return nil
    }

    private static func ensureIntermediates(_ split: DerivedDataSplit) throws {
        let intermediates = URL(fileURLWithPath: split.intermediates).standardizedFileURL.path
        let bulk = URL(fileURLWithPath: split.bulk).standardizedFileURL.path
        guard (intermediates as NSString).lastPathComponent == "Intermediates", (intermediates as NSString).deletingLastPathComponent == bulk else {
            throw RuntimeOperationError("Intermediates must be a folder named Intermediates inside the external DerivedData folder.")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: intermediates, isDirectory: &isDir) {
            guard isDir.boolValue else { throw RuntimeOperationError("\(intermediates) exists and is not a folder.") }
            return
        }
        try FileManager.default.createDirectory(atPath: intermediates, withIntermediateDirectories: false)
    }

    private static func requireDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        guard path.hasPrefix("/") else { throw RuntimeOperationError("Use an absolute path.") }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeOperationError("\(path) is not an existing directory.")
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw RuntimeOperationError("\(path) is not writable.") }
    }

    /// An existing products folder has to be a writable directory. The usual folder may still be missing: Run creates
    /// it, and only on the internal volume. Any other missing folder is refused.
    private static func acceptProductsDirectory(_ products: String, home: String) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: products, isDirectory: &isDir) {
            try requireDirectory(products)
            return
        }
        guard sameDirectory(products, suggestedProductsDirectory(home: home)) else {
            throw RuntimeOperationError("\(products) is not an existing directory.")
        }
        try validateSuggestedProductsParent(home: home)
    }

    /// A products folder that does not exist yet is placed by its parent, so an external parent is still refused.
    private static func resolveForPlacement(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return resolve(path) }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, FileManager.default.fileExists(atPath: parent) else { return path }
        return (resolve(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    private static func sameDirectory(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a, isDirectory: true).standardizedFileURL.path == URL(fileURLWithPath: b, isDirectory: true).standardizedFileURL.path
    }

    private static func resolve(_ path: String) -> String {
        (try? PathSafety.canonicalize(path)).flatMap { canonical in
            realpath(canonical, nil).map { r in
                defer { free(r) }
                return String(cString: r)
            }
        } ?? path
    }

    private static func readDefault(_ key: String, runner: CommandRunning) -> String? {
        guard let read = try? runner.run(Tools.defaults, ["read", domain, key]), read.succeeded else { return nil }
        let value = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func write(_ change: Change, runner: CommandRunning, tolerateMissingDelete: Bool) throws {
        let key = change.key.defaultsKey
        let args = change.newValue.map { ["write", domain, key, "-string", $0] } ?? ["delete", domain, key]
        let result: CommandResult
        do { result = try runner.run(Tools.defaults, args) } catch {
            throw error
        }
        if result.succeeded { return }
        if change.newValue == nil, tolerateMissingDelete, missingDefaultsKey(result) { return }
        throw CommandError(executable: Tools.defaults, arguments: args, result: result, underlying: nil)
    }

    private static func missingDefaultsKey(_ result: CommandResult) -> Bool {
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("does not exist") || text.contains("not found")
    }

    /// Puts back the keys already written. Returns a note when a put-back itself fails; the original error still throws.
    private static func rollBack(_ written: [Change], previous: [String: String], runner: CommandRunning) -> String {
        var note = ""
        for change in written.reversed() {
            let back = Change(key: change.key, newValue: previous[change.key.defaultsKey])
            do { try write(back, runner: runner, tolerateMissingDelete: true) } catch { note += " Rollback of \(change.key.defaultsKey) failed: \(error)." }
        }
        return note
    }
}
