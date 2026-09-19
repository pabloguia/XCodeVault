import Foundation

public struct Finding: Sendable, Codable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Codable, Comparable {
        case info, warning, error, critical
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int {
            switch self {
            case .info: 0;
            case .warning: 1;
            case .error: 2;
            case .critical: 3
            }
        }
    }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var path: String?
    /// What the user (or a future `doctor --fix`) would do. Doctor never executes it.
    public var remediation: String?
    public var evidence: String?
}

/// Read-only diagnostics per docs/product/UX_AND_CLI.md §Doctor. Proposes; never executes.
public struct Doctor: Sendable {
    public var home: String
    public var runner: CommandRunning
    /// Injectable like `home`, and for the same reason: without it the rule that reads this tree can
    /// only ever be exercised against whatever the machine happens to hold, and its wiring into
    /// `diagnose` cannot be tested at all.
    public var dyldCacheRoot: String
    /// Read-only here. `checkUnavailableDevices` needs it to tell "this runtime is gone for good"
    /// apart from "XCodeVault offloaded this runtime and the installer is still on the vault", which
    /// is the difference between advice that frees space and advice that destroys the user's devices.
    public var journal: Journal
    /// The volume identity of the filesystem holding a path.
    ///
    /// Injected for the reason `MigrationEngine.volumeUUIDAt` is, and the same spelling is used on
    /// purpose: the question "is the file now at this path on the volume that was verified?" (#26)
    /// cannot be staged from a unit test without two real drives and root. A test's two volumes are
    /// the same `/tmp`, and the real lookup correctly says so.
    ///
    /// **The residual, stated rather than discovered later:** flipping the *production default*
    /// below to something that always matches would disable the identity check with the whole suite
    /// green, because the tests supply their own. That is the failure mode issue #13 documented for
    /// the mount-point seams, and the answer there — use a real primitive instead — is not available
    /// here. This one is held by review.
    /// `let`, not `var`: a mutable seam on a shipped type is a second way to disable the check —
    /// any caller could assign `{ _ in nil }` (refuse everything) or a matching stub (disable the
    /// identity comparison) with the whole suite green. Set once, through `init`.
    ///
    /// The argument indicted its own sibling, which is why this comment used to name
    /// `MigrationEngine.volumeUUIDAt` as still being a `public var`. It was converted under issue
    /// #27, with the migration-safety review that change needed. The rest of that struct's seams
    /// are still mutable and are tracked as issue #31 — `verifier` in particular is a larger lever
    /// than either of these two.
    public let volumeUUIDAt: @Sendable (String) -> String?
    public init(
        home: String = NSHomeDirectory(), runner: CommandRunning = ProcessCommandRunner(),
        dyldCacheRoot: String = "/Library/Developer/CoreSimulator/Caches/dyld", journal: Journal? = nil,
        volumeUUIDAt: @escaping @Sendable (String) -> String? = { MountStatus.volumeUUID(at: $0) }
    ) {
        self.home = home
        self.runner = runner
        self.dyldCacheRoot = dyldCacheRoot
        self.volumeUUIDAt = volumeUUIDAt
        // Derived from `home`, not from `Journal.defaultURL`. The default reads `NSHomeDirectory()`
        // directly, so a test that injected `home` still got this machine's real journal — the
        // injection looked complete and was not, which is how a test can pass against production data.
        self.journal = journal ?? Journal(url: URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/XCodeVault/journal.jsonl"))
    }

    public func diagnose(report: ScanReport) -> [Finding] {
        var f: [Finding] = []
        // Computed once and shared: the shadow-root rule escalates when a live redirect is also
        // present, because that is the case where two device sets can take writes at the same time.
        let forbidden = checkForbiddenSymlinks()
        f += forbidden
        f += checkBrokenSymlinks()
        f += checkShadowCoreSimulatorRoots(volumes: report.volumes, forbiddenSymlinks: forbidden)
        f += checkPriorToolLeftovers(volumes: report.volumes)
        f += checkFreeSpace(host: report.host)
        f += checkRuntimeRegistry(runtimes: report.runtimes)
        f += checkStrandedInbox()
        f += checkOrphanedAssets(runtimes: report.runtimes)
        f += checkOrphanedDyldCaches(runtimes: report.runtimes, host: report.host, devices: report.devices, warnings: report.warnings)
        f += checkUnavailableDevices(devices: report.devices)
        f += checkPerDeviceRegenerables(items: report.items)
        f += checkDerivedDataLocation(volumes: report.volumes)
        f += checkXcodeSelect(xcodes: report.xcodes)
        f += checkOS(host: report.host)
        return f.sorted { ($0.severity > $1.severity) || ($0.severity == $1.severity && $0.id < $1.id) }
    }

    // MARK: rules

    func checkForbiddenSymlinks() -> [Finding] {
        var out: [Finding] = []
        for t in CatalogRules.neverSymlink {
            let p = t.expandingTilde(home: home)
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { continue }
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) ?? "?"
            let why: String
            switch t {
            case "~/Library/Developer": why = "Breaks Xcode 15+ physical-device DDI discovery (FB12363725)."
            case "~/Library/Developer/CoreSimulator":
                // Wording corrected after E9 (2026-09-08): we could NOT reproduce the Files-app
                // breakage on macOS 26.6.2 / Xcode 26.5, so stating it as fact would be wrong.
                // The path stays forbidden — the reason is "unverified and known to leave shadow
                // data", not "proven to break".
                why =
                    "Unsupported redirect (this is what mac-ssd-rescue creates). CoreSimulator caches the resolved target, so this layout leaves shadow device sets behind (E9). An Aug 2025 report also describes the Simulator's Files app losing share/save/create-folder on this configuration; we could not reproduce that on macOS 26.6.2 / Xcode 26.5, so treat it as unverified rather than safe (H5)."
            case "~/Library/Developer/DeveloperDiskImages": why = "Must be a real directory for device support to work (FB12363725)."
            default: why = "This path must never be redirected wholesale."
            }
            out.append(
                Finding(
                    id: "forbidden-symlink:\(t)", severity: .critical, title: "\(t) is a symlink → \(target)",
                    detail: why + " This configuration was not created by XCodeVault (it is exactly what mac-ssd-rescue creates).",
                    path: p,
                    remediation:
                        "Move the data back to \(p) as a real directory (copy with `ditto`, verify, then replace the symlink). XCodeVault will offer a verified restore in a later milestone.",
                    evidence: "docs/research/FINDINGS-2026-09-05.md §F3"))
        }
        return out
    }

    func checkBrokenSymlinks() -> [Finding] {
        var out: [Finding] = []
        let root = home + "/Library/Developer"
        guard let e = FileManager.default.enumerator(atPath: root) else { return out }
        var depth = 0
        while let rel = e.nextObject() as? String {
            depth = rel.split(separator: "/").count
            if depth > 3 { e.skipDescendants(); continue }
            let p = root + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { continue }
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) ?? "?"
            let resolved = target.hasPrefix("/") ? target : (p as NSString).deletingLastPathComponent + "/" + target
            if !FileManager.default.fileExists(atPath: resolved) {
                out.append(
                    Finding(
                        id: "broken-symlink:\(rel)", severity: .error, title: "Broken symlink under ~/Library/Developer",
                        detail: "\(p) → \(target) (target missing). Typical of a relocation tool whose destination volume is not mounted.",
                        path: p,
                        remediation:
                            "Reconnect the destination volume, or restore the directory. Do not let Xcode recreate it as a local directory first — that creates shadow data.",
                        evidence: "docs/process/PRIOR_ART.md"))
            } else if target.hasPrefix("/Volumes/") {
                out.append(
                    Finding(
                        id: "external-symlink:\(rel)", severity: .warning, title: "Symlink into /Volumes under ~/Library/Developer",
                        detail:
                            "\(p) → \(target). Absolute symlinks into /Volumes break when the volume mounts under a different name (e.g. 'Name 1') or is absent.",
                        path: p, remediation: "Prefer XCodeVault's UUID-identified strategies; keep the volume connected until migrated.",
                        evidence: "docs/architecture/MIGRATION_ENGINE.md"))
            }
        }
        return out
    }

    /// A CoreSimulator device-set root sitting outside `~/Library/Developer/CoreSimulator`.
    ///
    /// This is the rule-6 shadow/duplicate failure mode, and it does not need an external volume
    /// to happen: E9 (2026-09-08) produced one on the internal disk alone. CoreSimulator caches
    /// the *resolved* target path while a symlink is in place — `simctl get_app_container`
    /// returns the resolved path, not the symlinked one — so after the symlink is removed, a
    /// restarted `CoreSimulatorService` can recreate the device-set skeleton at the old target
    /// and keep writing there.
    ///
    /// Scope is deliberately bounded and differs per root: the home directory is scanned one
    /// level deep (going deeper would walk every project directory on every `doctor` run), while
    /// external volumes and disk images are scanned two levels deep, because the layout that
    /// actually occurs in the wild puts the device set one level down —
    /// `/Volumes/<disk>/mac-ssd-rescue/CoreSimulator`. Matching is by name, so an arbitrarily
    /// named shadow root buried elsewhere is still missed; catching those would need a full
    /// filesystem walk, which `doctor` must stay cheap enough to avoid.
    ///
    /// Known false negatives, deliberately accepted:
    /// - A **symlink** whose target is a shadow set (e.g. `~/CoreSimulator-backup` → a real set)
    ///   is skipped here, and is *not* picked up elsewhere either: `checkForbiddenSymlinks` only
    ///   walks `CatalogRules.neverSymlink` and `checkBrokenSymlinks` only walks
    ///   `~/Library/Developer`. This is a genuine gap, not a delegation.
    /// - `/Volumes` is not itself a scanned root, so a set on a volume that `diskutil` does not
    ///   enumerate — network mounts, or any volume whose `mountPoint` is nil — is invisible.
    /// - The rule cannot tell a live set from a stale duplicate or a deliberate cold backup.
    ///   That is why severity stops at `.error` unless a live redirect is also present.
    /// - An *unreadable* hidden directory on a volume is passed over without a finding, so a set
    ///   underneath one is missed. Readable hidden directories are still scanned.
    /// - The depth cap of 2 means a set in the volume's Trash —
    ///   `/Volumes/X/.Trashes/<uid>/CoreSimulator`, at depth 3 — is invisible. This one is not a
    ///   deliberate stash: it is where a set lands when a user follows this rule's own
    ///   `.holdsDevices` advice and removes the duplicate through Finder. The bytes are still on
    ///   the disk and `doctor` will report clean. Worth fixing when the depth cap is revisited.
    /// - The home scan is depth 1, so the same prior-tool layout pointed at an internal path
    ///   (`~/mac-ssd-rescue/CoreSimulator`) is missed while the identical layout on a volume is
    ///   caught. Deliberate asymmetry: descending the home directory would walk every project.
    func checkShadowCoreSimulatorRoots(volumes: [Volume], forbiddenSymlinks: [Finding] = []) -> [Finding] {
        let fm = FileManager.default
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let resolvedCanonical = resolved(home + "/Library/Developer/CoreSimulator")
        var roots: [(path: String, scope: String, display: String, depth: Int)] = [(home, "home", "your home directory", 1)]
        for v in volumes where v.isExternal || v.isDiskImage {
            guard let mp = v.mountPoint else { continue }
            roots.append((mp, v.id, v.volumeName, 2))
        }

        // A live redirect means the canonical path and the shadow set can both be taking writes
        // right now, which is worse than any single stale copy. Computed once for all roots.
        //
        // Note for anyone tempted to "fix" the resolved-path guard below so this fires for
        // mac-ssd-rescue: it deliberately does not. When `~/Library/Developer` is symlinked onto
        // an external volume, the redirect *target* resolves to the canonical path and is
        // excluded here on purpose — that layout is already reported by `checkForbiddenSymlinks`
        // (`.critical`) and `checkPriorToolLeftovers`. Escalating it here too would double-report
        // the same configuration.
        let liveRedirect = forbiddenSymlinks.contains {
            $0.id == "forbidden-symlink:~/Library/Developer/CoreSimulator" || $0.id == "forbidden-symlink:~/Library/Developer"
        }

        var out: [Finding] = []
        for root in roots {
            // Relative paths of everything to consider, at the depth this root allows.
            // A root we cannot enumerate is reported rather than skipped: silence is precisely
            // the failure mode this rule exists to prevent, and a volume that vanished between
            // the scan and now is a disconnect event, not a clean bill of health.
            guard let topLevel = try? fm.contentsOfDirectory(atPath: root.path) else {
                out.append(
                    Finding(
                        id: "shadow-coresimulator-unscannable:\(root.scope)", severity: .warning,
                        title: "Could not scan \(root.display) for stray CoreSimulator device sets",
                        detail:
                            "\(root.path) could not be enumerated (permissions). This rule reports nothing about that location — treat it as unknown, not as clean. Note it does NOT catch a volume that merely went away: an unmounted mount point that is still a readable empty directory enumerates fine and produces no finding at all.",
                        path: root.path,
                        remediation:
                            "Re-run `xcodevaultctl doctor` with the volume mounted and readable. If it stays unreadable, inspect it manually before assuming no shadow data is there.",
                        evidence: "docs/architecture/COMPATIBILITY_MATRIX.md (E9, 2026-09-08); NON_GOALS_AND_SAFETY.md rule 6"))
                continue
            }
            var relatives = topLevel.sorted()
            if root.depth >= 2 {
                // Hidden directories ARE descended into. The noise problem they caused is about
                // *reporting*, not scanning: every external volume carries root-owned macOS
                // metadata stores (`.Spotlight-V100`, `.DocumentRevisions-V100`, `.TemporaryItems`,
                // `.Trashes`, `.fseventsd`, …) that this process cannot read, and announcing each
                // as "could not scan" every run is unactionable noise. Suppressing the finding
                // rather than the readdir costs one extra listing per hidden top-level directory
                // and keeps coverage of the readable ones — a set at `/Volumes/X/.stash/…` is
                // still found. A deny-list of known stores was rejected: that set is not closed,
                // so every macOS release would be a latent noise regression discovered on a
                // user's machine.
                for parent in relatives {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: root.path + "/" + parent, isDirectory: &isDir), isDir.boolValue else { continue }
                    // Same principle as the root guard above: an unreadable intermediate directory
                    // would otherwise swallow a whole device set one level below it and report
                    // nothing at all, which is the silence this rule exists to prevent.
                    guard let children = try? fm.contentsOfDirectory(atPath: root.path + "/" + parent) else {
                        // An unreadable *hidden* directory is almost certainly a macOS metadata
                        // store this process was never meant to read. Reporting it teaches the
                        // user to ignore this rule's findings, which is worse than the coverage
                        // it buys.
                        if parent.hasPrefix(".") { continue }
                        out.append(
                            Finding(
                                id: "shadow-coresimulator-unscannable:\(root.scope):\(parent)", severity: .warning,
                                title: "Could not scan \(parent) on \(root.display) for stray CoreSimulator device sets",
                                detail:
                                    "\(root.path)/\(parent) could not be enumerated (permissions). Anything below it — including a whole CoreSimulator device set — is invisible to this check. Treat it as unknown, not as clean.",
                                path: root.path + "/" + parent,
                                remediation:
                                    "Inspect it as a user who can read it before assuming no shadow data is there, then re-run `xcodevaultctl doctor`.",
                                evidence: "docs/architecture/COMPATIBILITY_MATRIX.md (E9, 2026-09-08); NON_GOALS_AND_SAFETY.md rule 6"))
                        continue
                    }
                    relatives.append(contentsOf: children.sorted().map { parent + "/" + $0 })
                }
            }
            for name in relatives where (name as NSString).lastPathComponent.lowercased().contains("coresimulator") {
                let candidate = root.path + "/" + name
                // Compare *resolved* paths, not strings: a volume or an aliased parent in the
                // chain (e.g. a root containing `dev -> ~/Library/Developer`) otherwise makes the
                // real device set report itself as its own shadow, which would tell the user
                // their live data is a duplicate.
                guard resolved(candidate) != resolvedCanonical else { continue }
                // Only real directories. A symlink at this name is a different problem and is
                // already covered by checkForbiddenSymlinks / checkBrokenSymlinks.
                var st = stat()
                guard lstat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                // The `Devices` subdirectory is what makes this CoreSimulator-shaped rather than
                // an unrelated folder that happens to be named after it. `lstat`, not
                // `fileExists`: the latter follows symlinks, and a symlinked `Devices` pointing at
                // an empty directory would otherwise be classified as removable residue — while
                // the `rmdir` that advice names returns ENOTDIR on a symlink.
                var dst = stat()
                guard lstat(candidate + "/Devices", &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR else { continue }

                // A failed listing must NEVER be read as "empty". `try?` here would turn an
                // EPERM/EACCES on a root-owned set (external volume with owners enabled, or a
                // TCC-protected path) into an empty array, i.e. report real shadow data as
                // harmless residue and offer to delete it. Keep the distinction.
                let deviceEntries = try? fm.contentsOfDirectory(atPath: candidate + "/Devices")
                let rootEntries = try? fm.contentsOfDirectory(atPath: candidate)
                // Device directories are UUID-named (36 chars, hyphenated). Dotfiles are skipped
                // so a stray .DS_Store never reads as "this holds devices".
                let udids = (deviceEntries ?? []).filter { $0.count == 36 && $0.contains("-") && !$0.hasPrefix(".") }
                let hasDeviceSet = (deviceEntries ?? []).contains("device_set.plist")
                // Residue is only residue when the whole root is nothing but a genuinely empty
                // `Devices`. Two separate traps here:
                //  - a root whose `Devices` is empty but which still holds `Caches` (the dyld
                //    cache alone is multi-GB), `Temp`, `Runtimes`… is not removable;
                //  - `Devices` itself may hold entries that are not UUID-shaped — a restored
                //    device under a hand-given name, or just a `.DS_Store` from a Finder visit,
                //    which is the likely state of any set on a drive somebody has browsed.
                // Both are checked on the *unfiltered* listings, because `rmdir` refuses over a
                // `.DS_Store` too: the advice must not promise what the tool cannot deliver.
                // Dot entries are NOT filtered out here. `rootIsOnlyDevices` below counts them and
                // `rmdir` refuses over them, so a message that drops them would say "not empty
                // either — ." and name nothing. That is not hypothetical: a real CoreSimulator
                // root carries `.metadata_never_index`, so the recreated skeleton this rule exists
                // to catch lands in exactly that state. Naming nothing sends the user to Finder,
                // which hides dotfiles, to conclude the tool is wrong and reach for `rm -rf`.
                let siblings = (rootEntries ?? []).filter { $0 != "Devices" }
                let rootIsOnlyDevices = (rootEntries ?? []).allSatisfy { $0 == "Devices" }
                let devicesIsTrulyEmpty = (deviceEntries ?? []).isEmpty

                enum Shape { case unreadable, holdsDevices, otherContent, pureResidue }
                let shape: Shape =
                    deviceEntries == nil || rootEntries == nil
                    ? .unreadable
                    : (!udids.isEmpty || hasDeviceSet)
                        ? .holdsDevices
                        : (rootIsOnlyDevices && devicesIsTrulyEmpty) ? .pureResidue : .otherContent

                let severity: Finding.Severity
                let detail: String
                let remediation: String
                switch shape {
                case .unreadable:
                    // The case we know least about, so it escalates on the same signal as a
                    // populated set: an unreadable shadow root next to a live redirect could be
                    // anything, including a second set actively taking writes.
                    severity = liveRedirect ? .critical : .error
                    detail =
                        "\(candidate) looks like a CoreSimulator device set, but its contents could not be read (permissions). It cannot be classified as empty residue or as live data, so it is reported at the higher severity on purpose."
                        + (liveRedirect ? " A forbidden symlink under ~/Library/Developer is present at the same time." : "")
                    // No shell command here either: the path would need escaping for volume names
                    // containing spaces or quotes, which is the same trap the residue branch avoids.
                    remediation =
                        "Inspect the directory yourself before doing anything — list the contents of its `Devices` subdirectory as a user who can read it. Do not delete it: an unreadable directory is not an empty one."
                case .holdsDevices:
                    // Two device sets that can both take writes right now — the shadow set plus a
                    // live redirect pointing simulator traffic away from the canonical path — is
                    // materially worse than a stale duplicate sitting on a shelf.
                    severity = liveRedirect ? .critical : .error
                    detail =
                        "\(candidate)/Devices holds "
                        + (udids.isEmpty
                            ? "a device_set.plist and no device directories"
                            : "\(udids.count) device director\(udids.count == 1 ? "y" : "ies")\(hasDeviceSet ? " and a device_set.plist" : "")")
                        + ". Either this is a live device set reached through a redirect — an unsupported configuration — or it is a stale duplicate left behind by one, or a deliberate cold backup. All three mean simulator state exists in two places, which is the shadow-data failure mode; this rule cannot tell them apart."
                        + (liveRedirect
                            ? " A forbidden symlink under ~/Library/Developer is present at the same time, so both sets can be taking writes right now — resolve that redirect first."
                            : "")
                    remediation =
                        "Do not delete it yet. Compare it against ~/Library/Developer/CoreSimulator/Devices first — check which set `xcrun simctl list devices` actually reports, and confirm no path still points here. XCodeVault `verify` will diff the two in a later milestone."
                case .otherContent:
                    severity = .warning
                    // Name what is actually there, on both levels. Saying only "not empty" invites
                    // the user to go looking with `rm -rf`; saying exactly what is left does not.
                    var leftovers: [String] = []
                    if !siblings.isEmpty { leftovers.append("alongside `Devices`: " + siblings.sorted().joined(separator: ", ")) }
                    let insideDevices = (deviceEntries ?? []).sorted()
                    if !insideDevices.isEmpty { leftovers.append("inside `Devices`: " + insideDevices.joined(separator: ", ")) }
                    detail =
                        "\(candidate) holds no UUID-named devices and no device_set.plist, but it is not empty either — \(leftovers.joined(separator: "; ")). Not removable residue: CoreSimulator keeps multi-gigabyte caches next to the device set, a device may have been restored under a non-UUID name, and even a stray `.DS_Store` is enough for `rmdir` to refuse."
                    remediation =
                        "Inspect what remains before removing anything — `Caches` in particular can be several GB, and a non-UUID entry under `Devices` may still be a real device directory. Confirm what each item is rather than assuming it is junk."
                case .pureResidue:
                    severity = .warning
                    detail =
                        "\(candidate) contains nothing but an empty `Devices` directory. This is residue: CoreSimulator caches the resolved target path while a redirect is in place and can recreate the skeleton there after the redirect is gone (observed in E9)."
                    // No copy-pasteable command on purpose. The path would need shell-escaping for
                    // volume names containing quotes, and `report` redacts $HOME to a literal `~`,
                    // which does not expand inside quotes — so an emitted command is the one thing
                    // a user is most likely to copy and the most likely to be subtly wrong.
                    remediation =
                        "Empty as of this scan. Remove it with `rmdir` — never `rm -rf` — taking `Devices` first and then the directory itself; `rmdir` refuses a non-empty directory, so it cannot take data with it. If `rmdir` refuses, the directory is no longer empty: stop, and re-run `xcodevaultctl doctor` to see what appeared."
                }

                out.append(
                    Finding(
                        id: "shadow-coresimulator:\(root.scope):\(name)", severity: severity,
                        title: "CoreSimulator device set outside ~/Library/Developer: \(name) in \(root.display)",
                        detail: detail, path: candidate, remediation: remediation,
                        evidence: "docs/architecture/COMPATIBILITY_MATRIX.md (E9, 2026-09-08); NON_GOALS_AND_SAFETY.md rule 6"))
            }
        }
        return out
    }

    func checkPriorToolLeftovers(volumes: [Volume]) -> [Finding] {
        var out: [Finding] = []
        for v in volumes where v.isExternal || v.isDiskImage {
            guard let mp = v.mountPoint else { continue }
            let candidate = mp + "/mac-ssd-rescue"
            // `lstat`, not `fileExists`: the latter follows symlinks, so a symlinked
            // `mac-ssd-rescue` would report some *other* tree's contents under this path, and the
            // empty branch would offer `sudo rmdir` on a symlink (ENOTDIR).
            var cst = stat()
            if lstat(candidate, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFLNK {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)) ?? "?"
                out.append(
                    Finding(
                        id: "prior-tool:mac-ssd-rescue:\(v.id)", severity: .warning,
                        title: "mac-ssd-rescue on \(v.volumeName) is a symlink",
                        detail:
                            "\(candidate) is a symlink to \(target), not a directory. Whatever it reports would be that other tree's contents, so this rule does not follow it.",
                        path: candidate,
                        remediation: "Inspect the link and its target yourself. Removing the link does not remove the data it points at.",
                        evidence: "docs/process/PRIOR_ART.md"))
            } else if lstat(candidate, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFDIR {
                // `try?` collapsed into `[]` used to render "contains: ." for an emptied directory
                // and still told the user to compare before deleting — advice about nothing. Found
                // in real use, after the tool's data had been removed but the directory could not
                // be (the volume root is root-owned, so unlinking an entry from it needs sudo).
                // Same defect class as the shadow-root rule's: keep unreadable and empty distinct.
                let listing = try? FileManager.default.contentsOfDirectory(atPath: candidate)
                // Emptiness is decided on the RAW listing. Filtering dotfiles first is the same
                // mistake this rewrite was meant to fix, one line lower: `rm -rf dir/*` in a shell
                // without `dotglob` — exactly how this directory got emptied in practice — leaves
                // `.DS_Store` behind, `rmdir` then refuses, and calling it "empty" would be a false
                // all-clear from a rule whose whole job is deciding whether data is at risk.
                let isEmpty = (listing ?? []).isEmpty
                let visible = (listing ?? []).filter { !$0.hasPrefix(".") }.sorted()
                let hiddenCount = (listing ?? []).count - visible.count
                let hiddenNote = hiddenCount > 0 ? " plus \(hiddenCount) hidden entr\(hiddenCount == 1 ? "y" : "ies")" : ""
                // "Nothing at risk" is only true if nothing still points here. The populated branch
                // already reasons about that; the empty branch must not skip it — an empty directory
                // that is still a live redirect target is a live redirect to an empty tree.
                // `PathSafety.symlinkRedirectsBetween` owns the resolution: relative destinations,
                // chained symlinks, doubled slashes, case, and containment in both directions. The
                // link set is `CatalogRules.neverSymlink` rather than literals, so it stays in step
                // with the shadow-root rule.
                let stillTargeted = CatalogRules.neverSymlink.contains {
                    PathSafety.symlinkRedirectsBetween($0.expandingTilde(home: home), candidate)
                }
                let detail: String
                let remediation: String
                if listing == nil {
                    detail = "\(candidate) exists but could not be read (permissions), so its contents are unknown — treat it as unknown, not as empty."
                    remediation = "Inspect it as a user who can read it before deciding anything."
                } else if isEmpty {
                    detail =
                        "\(candidate) is empty — the prior tool's data is gone and only the directory itself remains."
                        + (stillTargeted
                            ? " But something under ~/Library/Developer still redirects here, so this is a live redirect pointing at an empty tree — resolve that first."
                            : " Nothing to compare and nothing at risk.")
                    remediation =
                        stillTargeted
                        ? "Do not remove it yet: fix the redirect under ~/Library/Developer first, then this directory is safe to delete."
                        : "Remove the empty directory. The volume root is root-owned, so this one needs sudo:\n  sudo rmdir \(OwnershipAdvice.shellQuoted(candidate))\nUse `rmdir`, not `rm -rf` — it refuses if anything reappeared inside."
                } else {
                    detail =
                        "\(candidate) contains: \(visible.isEmpty ? "(only hidden entries)" : visible.joined(separator: ", "))\(hiddenNote). If ~/Library/Developer no longer links here, these are stale duplicates; if it does, they are live data in an unsupported configuration (H5 — the Aug 2025 Files-app breakage did not reproduce on macOS 26.6.2 / Xcode 26.5, but the layout still leaves shadow device sets behind, see E9)."
                    remediation = "Compare with the local copies before deleting anything. XCodeVault `verify` will diff them in a later milestone."
                }
                out.append(
                    Finding(
                        id: "prior-tool:mac-ssd-rescue:\(v.id)", severity: .warning,
                        title: isEmpty && listing != nil
                            ? "Empty mac-ssd-rescue directory left on \(v.volumeName)" : "mac-ssd-rescue data found on \(v.volumeName)",
                        detail: detail, path: candidate, remediation: remediation,
                        evidence: "docs/process/PRIOR_ART.md"))
            }
        }
        return out
    }

    func checkFreeSpace(host: HostEnvironment) -> [Finding] {
        let free = host.dataVolumeFreeBytes
        guard free < 40 * 1_000_000_000 else { return [] }
        let sev: Finding.Severity = free < 10 * 1_000_000_000 ? .critical : .warning
        return [
            Finding(
                id: "low-free-space", severity: sev, title: "Low free space on the internal volume: \(ByteCount.format(free))",
                detail:
                    "Simulator runtime installs stage on the internal volume and reportedly need ~40 GB free even when the installer is elsewhere; Xcode itself needs headroom for indexes and builds.",
                path: host.homeDirectory,
                remediation:
                    "Run `xcodevaultctl scan` and clean regenerable categories first (DerivedData, old Device Support, unused runtimes via `simctl runtime delete`).",
                evidence: "docs/research/FINDINGS-2026-09-05.md §F9 (E11)")
        ]
    }

    /// Reports the regenerable data sitting *inside* the simulator devices (F22): the largest
    /// user-owned, root-free total on a typical developer's machine.
    ///
    /// Reporting is the whole of it. `clean` offers none of these, so this finding is the only place
    /// the user learns the number — which makes it the one place the reason has to be stated rather
    /// than implied. Each category supplies its own `remediationHint`, and nil is a real answer: it
    /// renders as no remediation at all, which is the honest shape of "nothing we can stand behind",
    /// and it is never replaced by a plausible-sounding command we have not run. Only
    /// `simulatorDeadContainers` has one today, and it is not a deletion — a booted device reaps
    /// that directory itself (F22, measured against a shutdown control), so the advice is to boot.
    ///
    /// Nothing here may hand the user a destructive command. `checkUnavailableDevices` above is the
    /// rule that is allowed to, and only from one journal-verified state; this rule has no such
    /// gate and must therefore never acquire such a hint. The catalog test pins that.
    func checkPerDeviceRegenerables(items: [StorageItem]) -> [Finding] {
        let perDevice = StorageCatalog.all.filter { !$0.perDeviceSubpaths.isEmpty }
        return perDevice.compactMap { category -> Finding? in
            let mine = items.filter { $0.categoryID == category.id && $0.exists && !$0.isSymlink }
            // `doctor` scans with `measureSizes: false`, so these items usually arrive with zero
            // bytes and the rule would report nothing at all — which is how it shipped broken the
            // first time, with a test that injected a measuring scanner and therefore agreed. The
            // sizes are measured here, for these paths only, so the rule does not depend on a
            // caller's choice it cannot see: `doctor` stays cheap everywhere else, and a report that
            // did measure is reused rather than walked twice.
            let sized: [(udid: String, bytes: UInt64)] = mine.map { item in
                let bytes = item.allocatedBytes > 0 ? item.allocatedBytes : (DiskUsage.measure(item.path)?.allocatedBytes ?? 0)
                return (Doctor.deviceUDID(fromItemPath: item.path) ?? item.path, bytes)
            }
            // One line per device, not per subpath: a category that occupies two directories inside
            // the same device (the log store) is still one idea and one number to the reader.
            let perDeviceTotals = Dictionary(sized.map { ($0.udid, $0.bytes) }, uniquingKeysWith: +)
            let total = perDeviceTotals.values.reduce(0, +)
            guard total > 0 else { return nil }
            // Largest first: which device holds the bytes is the actionable part, since a device the
            // user no longer wants can be deleted outright with the official command.
            let breakdown =
                perDeviceTotals
                .filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
                .map { "  \($0.key): \(ByteCount.format($0.value))" }
                .joined(separator: "\n")
            return Finding(
                id: "perDeviceRegenerable.\(category.id)",
                severity: .info,
                title: "\(ByteCount.format(total)) in \(category.name.lowercased()) across \(perDeviceTotals.filter { $0.value > 0 }.count) device(s)",
                detail: category.description + "\n" + breakdown
                    + "\n\nNot offered by `clean`: " + (category.notes.first ?? "reported for accounting only."),
                path: nil,
                remediation: category.remediationHint,
                evidence: category.evidence)
        }
    }

    /// The device UDID out of a per-device item path, for display. Returns nil rather than guessing
    /// when the path is not shaped like one, so a surprise never renders as a confident label.
    static func deviceUDID(fromItemPath path: String) -> String? {
        path.split(separator: "/").map(String.init).last { SimulatorNaming.isDeviceUDID($0) }
    }

    func checkDerivedDataLocation(volumes: [Volume]) -> [Finding] {
        guard let r = try? runner.run(Tools.defaults, ["read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"]), r.succeeded else { return [] }
        let loc = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loc.isEmpty else { return [] }
        let fs = MountStatus.filesystem(containing: loc.expandingTilde(home: home))
        let vol = volumes.first { $0.mountPoint == fs?.mountPoint }
        if let vol, vol.isExternal || vol.isDiskImage || loc.hasPrefix("/Volumes/") {
            return [
                Finding(
                    id: "deriveddata-external", severity: .info, title: "DerivedData is on an external volume (\(loc))",
                    detail:
                        "Apple's supported relocation, but framework unit tests are reported to fail loading test bundles from external volumes (F4). E2 on this machine: see COMPATIBILITY_MATRIX.md.",
                    path: loc, remediation: "If `xcodebuild test` fails with a bundle-load error, point DerivedData back to the internal disk.",
                    evidence: "docs/research/FINDINGS-2026-09-05.md §F4; H6")
            ]
        }
        return []
    }

    func checkXcodeSelect(xcodes: [XcodeInstallation]) -> [Finding] {
        guard !xcodes.isEmpty, !xcodes.contains(where: \.isSelected) else { return [] }
        return [
            Finding(
                id: "xcode-select", severity: .warning, title: "xcode-select does not point at any installed Xcode",
                detail: "Command-line tools (xcodebuild, simctl) may be using the Command Line Tools package instead of Xcode.",
                path: nil, remediation: "`sudo xcode-select -s /Applications/Xcode.app`", evidence: nil)
        ]
    }

    func checkOS(host: HostEnvironment) -> [Finding] {
        guard !host.meetsMinimumOS else { return [] }
        return [
            Finding(
                id: "unsupported-macos", severity: .error, title: "macOS \(host.macOSVersion) is below the supported minimum (14.0)",
                detail: "XCodeVault runs in read-only diagnostic mode here; no relocation is offered (ADR-0001).",
                path: nil, remediation: nil, evidence: "docs/adr/0001-minimum-macos-target.md")
        ]
    }
}
