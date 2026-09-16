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
    public init(
        home: String = NSHomeDirectory(), runner: CommandRunning = ProcessCommandRunner(),
        dyldCacheRoot: String = "/Library/Developer/CoreSimulator/Caches/dyld", journal: Journal? = nil
    ) {
        self.home = home
        self.runner = runner
        self.dyldCacheRoot = dyldCacheRoot
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
                        remediation: "Re-run `xcodevaultctl doctor` with the volume mounted and readable. If it stays unreadable, inspect it manually before assuming no shadow data is there.",
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
                                remediation: "Inspect it as a user who can read it before assuming no shadow data is there, then re-run `xcodevaultctl doctor`.",
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
                        + (udids.isEmpty ? "a device_set.plist and no device directories" : "\(udids.count) device director\(udids.count == 1 ? "y" : "ies")\(hasDeviceSet ? " and a device_set.plist" : "")")
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
                    remediation = stillTargeted
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

    func checkRuntimeRegistry(runtimes: [SimulatorRuntime]) -> [Finding] {
        var out: [Finding] = []
        for r in runtimes {
            let name = r.runtimeIdentifier ?? r.identifier
            if let mp = r.mountPath, r.state == "Ready", !MountStatus.isMountPoint(mp) {
                out.append(
                    Finding(
                        id: "runtime-not-mounted:\(r.identifier)", severity: .error, title: "Runtime \(name) is Ready but not mounted",
                        detail: "Registry says Ready; nothing is mounted at \(mp). Xcode will not see this runtime.",
                        path: mp,
                        remediation:
                            "`xcrun simctl runtime verify \(r.identifier)` then restart CoreSimulator (`launchctl kickstart -k`) or reboot. Never remount with Disk Utility (Apple DTS).",
                        evidence: "docs/research/FINDINGS-2026-09-05.md §F1"))
            }
            if let sig = r.signatureState, sig != "Verified" {
                out.append(
                    Finding(
                        id: "runtime-signature:\(r.identifier)", severity: .error, title: "Runtime \(name) signature state: \(sig)",
                        detail: "Sealed runtime images must verify; state '\(sig)' means the image is unusable.",
                        path: r.path, remediation: "`xcrun simctl runtime delete \(r.identifier)` and re-download.",
                        evidence: "docs/research/FINDINGS-2026-09-05.md §F1"))
            }
            if let p = r.path, !FileManager.default.fileExists(atPath: p) {
                out.append(
                    Finding(
                        id: "runtime-image-missing:\(r.identifier)", severity: .error, title: "Runtime \(name) image file missing",
                        detail: "Registry references \(p) which does not exist (zombie registry entry).", path: p,
                        remediation: "`xcrun simctl runtime delete \(r.identifier)`.", evidence: "F1/F6"))
            }
        }
        return out
    }

    func checkStrandedInbox() -> [Finding] {
        var out: [Finding] = []
        for dir in ["/Library/Developer/CoreSimulator/Cryptex/Images/Inbox", "/Library/Developer/CoreSimulator/Images/Inbox"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where !n.hasPrefix(".") {
                let p = dir + "/" + n
                let size = DiskUsage.measure(p)?.allocatedBytes ?? 0
                out.append(
                    Finding(
                        id: "stranded-inbox:\(n)", severity: .warning, title: "Stranded runtime download: \(n) (\(ByteCount.format(size)))",
                        detail: "Files left in the Inbox after a runtime download/install are not reclaimed by Xcode — observed even after a successful `-downloadPlatform -exportPath` followed by `simctl runtime delete`.",
                        path: p, remediation: "Restart the Mac: simdiskimaged reaps the Inbox at startup (verified 2026-09-07, 5 GB reclaimed). Deleting by hand does not work — even `sudo rm` is refused (Operation not permitted) on macOS 26.5. If it survives a reboot, report to Apple.",
                        evidence: "docs/research/FINDINGS-2026-09-05.md §F1 + 2026-09-06 root-EPERM note"))
            }
        }
        return out
    }

    /// Dyld shared caches whose owner no longer exists.
    ///
    /// Layout observed on macOS 26.6.2 / 25G83 / Xcode 26.5 / Intel (2026-09-08):
    ///
    ///     /Library/Developer/CoreSimulator/Caches/dyld/<hostBuild>/<runtimeIdentifier>.<build>/
    ///     /Library/Developer/CoreSimulator/Caches/dyld/<hostBuild>/inc/<runtimeIdentifier>.<build>/
    ///
    /// The distinction this rule exists to draw: "rebuilt on next boot" is true of a cache whose
    /// runtime is installed — deleting it buys a slow first boot, not free space — and false of a
    /// cache whose runtime is gone. Only the latter is a durable win, and the category cannot say so.
    ///
    /// **The remediation used to be "restart first", and that ordering was deliberate — then the
    /// restart was measured and it does nothing here. See E13 below.** The one time this
    /// repo reasoned "no BSD file flags + absent from `rootless.conf` ⇒ root can delete it", it was
    /// wrong: the stranded runtime Inbox `.dmg` had *both* of those properties and root still got
    /// `Operation not permitted` three times — and what actually reclaimed it was a reboot, because
    /// the reaper is a startup GC (F1 2026-09-06, which ends with "doctor must not promise a
    /// root-only fix").
    ///
    /// **That probe has since run, and the restart did not reclaim it (E13, 2026-09-16.)** Captured
    /// before a reboot and again 5h46m after one, the whole cache tree came back byte-identical: same
    /// sizes, same mtimes, same birth times, and the same newest write anywhere inside the orphan. So
    /// the startup GC that collects the Inbox is **path-specific, not a general mechanism**, and the
    /// remediation below no longer tells anyone to restart — it was measured to do nothing here.
    ///
    /// What that does *not* license is the opposite inference. Root deletion remains untested (E13b),
    /// and the Inbox is the standing reason to expect it may be refused, so the command below is
    /// offered as a probe whose result is worth reporting, not as a fix that is known to work.
    ///
    /// Every guard below is a fail-closed one, and each exists because removing it produced a
    /// destructive suggestion against live data in review.
    func checkOrphanedDyldCaches(
        runtimes: [SimulatorRuntime], host: HostEnvironment, devices: [SimulatorDevice] = [], warnings: [String] = [], now: Date = Date(),
        root: String? = nil
    ) -> [Finding] {
        let root = root ?? dyldCacheRoot
        // The probe either failed outright — `Scanner` records that in `report.warnings` — or
        // returned runtimes whose identifiers did not decode. Both look like "nothing is installed",
        // and acting on that reports every live cache on the machine as garbage.
        guard !warnings.contains(where: { $0.hasPrefix("simctl runtime list failed") }) else { return [] }
        guard !runtimes.isEmpty else { return [] }
        // `runtimeIdentifier` is optional and `parseRuntimes` enforces no required keys, so a key
        // rename upstream yields a non-empty array of runtimes that claim nothing at all.
        var installed = runtimes.compactMap { r -> (rid: String, build: String?)? in
            guard let rid = r.runtimeIdentifier else { return nil }
            return (rid, r.build)
        }
        guard !installed.isEmpty else { return [] }
        // `simctl runtime list` enumerates disk-image runtimes only. A runtime bundled inside an
        // older Xcode does not appear there, so "absent from that list" is not "absent from the
        // machine" — and on such a machine the rule would offer `sudo rm` for a live cache. An
        // available device is a second, independent witness that its runtime exists; devices whose
        // runtime is gone report `isAvailable == false`, so this only ever adds claims.
        // Not verifiable here: this machine has no bundled runtime, so the case is reasoned, not
        // measured. That is also why the direction chosen is the one that can only under-report.
        // …but only for identifiers `simctl` does not report at all. A device knows its runtime
        // exists; it does not know which *build*, so a device entry can only prefix-match. Adding one
        // for a runtime `simctl` already described precisely would replace a build-accurate claim
        // with a vague one — and since every real machine has available devices for its installed
        // runtimes, that silently disabled superseded-build detection entirely, which is the one
        // orphan class the exact-matching machinery exists to find.
        let reportedRids = Set(installed.map(\.rid))
        installed += devices.filter { $0.isAvailable && !reportedRids.contains($0.runtimeIdentifier) }
            .map { (rid: $0.runtimeIdentifier, build: nil) }
        // `HostEnvironment.discover` substitutes "unknown" when `sw_vers` fails; comparing against it
        // marks every build directory stale.
        let hostBuild = host.macOSBuild
        guard hostBuild != "unknown", !hostBuild.isEmpty else { return [] }
        guard let buildDirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        // Two name sets, not one: `<hostBuild>/` and `<hostBuild>/inc/` are separate naming
        // conventions, and confirming a scheme in one says nothing about the other.
        let finishedNames = Set((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + hostBuild)) ?? [])
        let incNames = Set((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + hostBuild + "/inc")) ?? [])

        /// Exact `<rid>.<build>` matching is what makes a *superseded build's* cache visible — the
        /// most likely orphan on a machine that has taken a runtime update. But it rests on a naming
        /// scheme observed on one machine, and where the scheme does not hold, exact matching orphans
        /// every live cache for that platform.
        ///
        /// So the tree confirms the scheme before it is relied on — **per runtime and per level**, not
        /// once for the whole tree. A single global flag was worse than no flag: on a mixed tree, iOS
        /// naming its directory `<rid>.<build>` licensed exact matching for a visionOS runtime named
        /// some other way, and reported that live cache for deletion. Confirming one platform says
        /// nothing about another, and confirming `<hostBuild>/` says nothing about `<hostBuild>/inc/`.
        func confirmedRids(in names: Set<String>) -> Set<String> {
            Set(
                installed.compactMap { entry in
                    guard let b = entry.build, names.contains(entry.rid + "." + b) else { return nil }
                    return entry.rid
                })
        }
        let confirmedFinished = confirmedRids(in: finishedNames)
        let confirmedInc = confirmedRids(in: incNames)
        /// `dirName` belongs to an installed runtime. The bare `<rid>` form is claimed too: this
        /// rule's own notes and `EXPERIMENTS.md` describe CoreSimulator writing `inc/<rid>` with no
        /// build suffix during an install, and without the equality test that live in-progress build
        /// was reported as "a runtime simctl no longer reports" while the runtime was installed.
        /// The trailing dot in the prefix form keeps `…iOS-26-5` from claiming `…iOS-26-50`'s cache.
        func isInstalled(_ dirName: String, confirmed: Set<String>) -> Bool {
            installed.contains { entry in
                if dirName == entry.rid { return true }
                if confirmed.contains(entry.rid), let b = entry.build { return dirName == entry.rid + "." + b }
                return dirName.hasPrefix(entry.rid + ".")
            }
        }
        /// A cache directory always names a runtime. Anything else under these directories is not a
        /// cache and nothing here can say what it is — so it must not be described as one, and must
        /// certainly not carry a deletion command. Level 1 got this check as `looksLikeBuild`; levels
        /// 2 and 3 had only a type check, so a directory called `tmp` was reported as "a finished
        /// cache for a runtime simctl no longer reports" with `sudo rm` attached.
        func namesARuntime(_ dirName: String) -> Bool { dirName.contains(".SimRuntime.") }
        /// The newest mtime in `path` and its **direct children only**. Every cache directory observed
        /// is flat, so one level is enough today — but that is an unverified layout assumption of the
        /// same kind that produced the mixed-tree and bare-`inc/<rid>` bugs, so it is stated rather
        /// than left implicit: a write two levels down would be invisible here, because a directory's
        /// mtime does not change when a file inside a *child* is appended. A cache build writes multi-hundred-MB
        /// files for many minutes while the *directory's* own mtime stays frozen at the moment its
        /// entries were created — measured here: the iOS rebuild spanned 06:47→07:06, and the tvOS
        /// orphan's directory mtime froze 17 minutes after its birth. Judging liveness by the
        /// directory alone therefore reports a genuinely in-flight build as garbage.
        func newestWrite(in path: String) -> Date? {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: path), let dirTime = attrs[.modificationDate] as? Date else { return nil }
            guard let children = try? fm.contentsOfDirectory(atPath: path) else { return nil }
            return children.reduce(dirTime) { newest, child in
                guard let a = try? fm.attributesOfItem(atPath: path + "/" + child), let t = a[.modificationDate] as? Date else { return newest }
                return t > newest ? t : newest
            }
        }
        func isDirectory(_ path: String) -> Bool {
            var st = stat()
            // `lstat`, so a symlink is never mistaken for the directory it points at and then
            // suggested for deletion.
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }

        var out: [Finding] = []
        func report(_ path: String, _ dirName: String, reason: String, id: String) {
            let usage = DiskUsage.measure(path)
            // "0 bytes" next to a deletion command is a confident lie about a tree we could not read.
            let size: String
            switch usage {
            case .none: size = "size unknown"
            // "at least 0 bytes" is still a confident-looking number for a tree we could not read.
            case .some(let u) where u.isLowerBound && u.allocatedBytes == 0: size = "size unknown"
            case .some(let u) where u.isLowerBound: size = "at least \(ByteCount.format(u.allocatedBytes))"
            case .some(let u): size = ByteCount.format(u.allocatedBytes)
            }
            // `newestWrite`, not the directory's own mtime — the same frozen value the age guard was
            // fixed to stop trusting. Printing it next to a deletion command would tell the user a
            // tree written minutes ago was last touched a year back. No date at all beats a wrong one.
            let age = newestWrite(in: path).map { " Last written \(Doctor.dayStamp.string(from: $0))." } ?? ""
            let q = OwnershipAdvice.shellQuoted(path)
            out.append(
                Finding(
                    id: id, severity: .warning, title: "Orphaned dyld cache: \(dirName) (\(size))",
                    detail:
                        "\(reason)\(age) Nothing will rebuild it, because the runtime it belongs to is gone — unlike the rest of this tree, "
                        + "where deleting a cache only costs the next boot the time to rebuild it.",
                    path: path,
                    remediation:
                        "Do not start with a restart: where this was measured (macOS 26.6.2 / 25G83, 2026-09-16) the tree came back byte-identical across "
                        + "a reboot, so the startup reaper that does collect the stranded runtime Inbox does not cover this path (E13). "
                        + "What DOES clear it is a macOS update: these caches are keyed by host build, so updating 26.6.2 (25G83) to 26.7 (25G229) "
                        + "removed the whole previous build's tree (2026-09-16, one observation). Only the orphan's share of that is durable free space "
                        + "— within the hour the installed runtimes had rebuilt their caches to the same sizes on the new build, and only the orphan "
                        + "stayed gone, because nothing rebuilds a cache for an absent runtime. "
                        + "First confirm the runtime is really gone: `simctl runtime list` cannot see a runtime bundled inside an older Xcode, so if any "
                        + "Xcode on this Mac ships \(dirName), this cache is live and deleting it costs you a rebuild for nothing. "
                        + "Then, if you want to run the probe that is still open — root deletion is UNVERIFIED, and was refused on that Inbox file despite "
                        + "the same absence of SIP markers — inspect first: `P=\(q); sudo ls -la \"$P\"`. Delete as a separate command: "
                        + "`sudo rm -f \"$P\"/dyld_sim_shared_cache_* \"$P\"/update_dyld_sim_shared_cache-std*.txt && sudo rmdir \"$P\"`. "
                        + "`rmdir` refuses if anything unexpected is inside. Copy `update_dyld_sim_shared_cache-stderr.txt` out first — that glob deletes it, "
                        + "and it is the diagnostic worth keeping. If the delete is refused with Operation not permitted, that is the more interesting "
                        + "outcome, not a failure: it would make this a second path where root is blocked with no BSD flag and no rootless.conf entry.",
                    evidence: "docs/research/FINDINGS-2026-09-05.md §F10"))
        }

        // A build directory is only judged stale when its name is build-version shaped AND some
        // sibling equals this machine's build. The second half is the load-bearing one: it is proof
        // the layout is the one we understand. Without it any unrecognised sibling — a `tmp`, a
        // stray file, a future Apple directory — was reported as "built for macOS tmp" with a
        // deletion command attached. This branch has never been observed to fire on real data: no
        // machine here has had a second host-build directory, so it stays informational.
        let looksLikeBuild = { (n: String) in n.range(of: #"^\d{2}[A-Z]\d+[a-z]?$"#, options: .regularExpression) != nil }
        let layoutUnderstood = buildDirs.contains(hostBuild)

        for buildDir in buildDirs where !buildDir.hasPrefix(".") {
            let buildPath = root + "/" + buildDir
            guard isDirectory(buildPath) else { continue }
            if buildDir != hostBuild {
                guard layoutUnderstood, looksLikeBuild(buildDir) else { continue }
                let usage = DiskUsage.measure(buildPath)
                out.append(
                    Finding(
                        id: "orphan-dyld-host:\(buildDir)", severity: .info,
                        title: "Dyld caches for macOS \(buildDir), which this machine no longer runs (\(usage.map { ByteCount.format($0.allocatedBytes) } ?? "size unknown"))",
                        detail:
                            "This machine runs \(hostBuild). Caches under another build are not read by anything — but XCodeVault has never observed a stale "
                            + "build directory in the field, so this is reported for inspection only and carries no command.",
                        path: buildPath,
                        remediation: "Inspect it. If it is genuinely a leftover from a macOS update, report what you find so this can be turned into a real rule.",
                        evidence: "docs/research/FINDINGS-2026-09-05.md §F10 (layout), branch unverified"))
                continue
            }
            // `inc` is a staging directory, not a runtime identifier — descend rather than judge it.
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: buildPath) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let entryPath = buildPath + "/" + entry
                // Levels 2 and 3 need the same type check as level 1: this tree really does contain
                // plain files (`update_dyld_sim_shared_cache-stderr.txt`), and reporting one with a
                // deletion command is both wrong and, for a symlink, dangerous.
                guard isDirectory(entryPath) else { continue }
                if entry == "inc" {
                    guard let pendings = try? FileManager.default.contentsOfDirectory(atPath: entryPath) else { continue }
                    for pending in pendings where !pending.hasPrefix(".") {
                        let pendingPath = entryPath + "/" + pending
                        guard isDirectory(pendingPath) else { continue }
                        // Two independent guards, because "not installed" alone does not mean "not in
                        // flight": CoreSimulator writes `inc/<rid>` during an install before `simctl`
                        // reports the runtime, and deleting a runtime mid-build lands here too. An
                        // entry younger than an hour is assumed to be live work.
                        guard namesARuntime(pending) else { continue }
                        guard !isInstalled(pending, confirmed: confirmedInc) else { continue }
                        // Fail-closed on an unreadable mtime: "we cannot tell how old it is" must not
                        // mean "old enough to delete".
                        guard let lastWrite = newestWrite(in: pendingPath) else { continue }
                        guard now.timeIntervalSince(lastWrite) >= 3600 else { continue }
                        report(
                            pendingPath, pending,
                            reason: "An interrupted cache build for a runtime `simctl runtime list` no longer reports.",
                            id: "orphan-dyld-inc:\(pending)")
                    }
                    continue
                }
                guard namesARuntime(entry), !isInstalled(entry, confirmed: confirmedFinished) else { continue }
                // The same two guards as the `inc/` branch. Nothing establishes that a rebuild is
                // staged through `inc/` rather than written straight into its final directory, so a
                // cache being written *right now* — for a runtime `simctl` has not reported yet — was
                // reported here with a deletion command while the identical case was guarded one
                // level down. An unreadable mtime is "unknown", never "old enough".
                guard let lastWrite = newestWrite(in: entryPath), now.timeIntervalSince(lastWrite) >= 3600 else { continue }
                report(entryPath, entry, reason: "A finished cache for a runtime `simctl runtime list` no longer reports.", id: "orphan-dyld:\(entry)")
            }
        }
        return out
    }

    /// Day resolution on purpose: a doctor finding is not a forensic timestamp, and the exact second
    /// a root-owned cache was written is noise next to "is this from today or from last month?".
    static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func checkOrphanedAssets(runtimes: [SimulatorRuntime]) -> [Finding] {
        var out: [Finding] = []
        let referenced = Set(
            runtimes.compactMap { $0.path }.compactMap { p -> String? in
                // …/com_apple_MobileAsset_iOSSimulatorRuntime/<sha1>.asset/AssetData/Restore/x.dmg → <dir>/<sha1>.asset
                guard let r = p.range(of: ".asset/") else { return nil }
                return String(p[..<r.lowerBound]) + ".asset"
            })
        let base = "/System/Library/AssetsV2"
        guard let stores = try? FileManager.default.contentsOfDirectory(atPath: base) else { return out }
        for store in stores where store.hasPrefix("com_apple_MobileAsset_") && store.hasSuffix("SimulatorRuntime") {
            let dir = base + "/" + store
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".asset") {
                let p = dir + "/" + e
                if !referenced.contains(p) {
                    let size = DiskUsage.measure(p)?.allocatedBytes ?? 0
                    out.append(
                        Finding(
                            id: "orphan-asset:\(e)", severity: .warning, title: "Runtime asset not referenced by any runtime (\(ByteCount.format(size)))",
                            detail:
                                "\(p) exists in the MobileAsset store but `simctl runtime list` references no runtime backed by it. Likely a NeverCollected orphan (F1).",
                            path: p,
                            remediation:
                                "Do not delete by hand (under /System). Try `xcrun simctl runtime delete all --dry-run` to see whether simctl knows it; otherwise it is an Apple bug to report.",
                            evidence: "docs/research/FINDINGS-2026-09-05.md §F1 (forum thread 812992)"))
                }
            }
        }
        return out
    }

    /// Unavailable devices are not automatically garbage. A device goes unavailable the moment its
    /// runtime leaves the machine — including when **XCodeVault itself** offloads that runtime, which
    /// is reversible and whose whole promise is that the devices come back untouched on re-import.
    ///
    /// `xcrun simctl delete unavailable` is therefore right in one case and permanent data loss in
    /// another, and the two are indistinguishable from `simctl list devices` alone. Recommending it
    /// unconditionally meant the tool offloaded a runtime and then, in the same breath, told the user
    /// to destroy the devices it had just promised to preserve.
    ///
    /// **The destructive suggestion is emitted from exactly one state: the journal was read in full
    /// and records no offload at all.** Every other state — an installer we can see, an installer on
    /// a volume that is not mounted right now, a journal we could not read — withholds it. The
    /// second of those is the one that bites: unplug the vault, run `doctor`, and an earlier version
    /// of this rule would tell you to delete devices whose installers are in your pocket. Absence of
    /// a *reachable* installer is not absence of an installer, and silence from a journal that could
    /// not be read is not a fact about the world.
    func checkUnavailableDevices(devices: [SimulatorDevice]) -> [Finding] {
        let bad = devices.filter { !$0.isAvailable }
        guard !bad.isEmpty else { return [] }
        let bytes = bad.reduce(0) { $0 + ($1.dataPathSize ?? 0) }
        let deviceRuntimes = Set(bad.map(\.runtimeIdentifier))

        let read = try? journal.read()
        let entries = read?.entries ?? []
        // An installer that was offloaded and later re-imported is no longer standing in for a
        // missing runtime; the stale offload entry must not keep claiming recoverability.
        let reimported = Set(entries.filter { $0.kind == .runtimeImport && $0.state == .completed }.flatMap(\.paths))
        var seen = Set<String>()
        let offloads =
            entries
            .filter { $0.kind == .runtimeOffload && $0.state == .completed }
            .compactMap { e -> (installer: String, rid: String?)? in
                guard let path = e.detail["installer"] ?? e.paths.first, !reimported.contains(path), seen.insert(path).inserted else { return nil }
                return (path, e.detail["runtimeIdentifier"])
            }

        /// A recorded path is only evidence of a recoverable runtime when it is a real image we can
        /// see. `fileExists` alone says true for a directory and for a 16-byte stub — the floor is the
        /// one `installer(for:in:)` already applies, so a truncated copy cannot pose as a runtime.
        /// Integrity beyond that is left to `runtime import`: the cost of a corrupt-but-large image is
        /// a failed import, while the cost of calling a real installer missing is a deleted device.
        func isUsableImage(_ path: String) -> Bool {
            var st = stat()
            // The S_IFREG test is redundant *today* and mutation testing says so: under `lstat` a
            // directory and a symlink both report a small `st_size`, so the floor already rejects
            // them. It stays because it states the intent the floor only implies — if the floor is
            // ever lowered or made configurable, this becomes the only thing standing between a
            // `.exportedBundle` directory and a promise that it can restore a runtime.
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
            return st.st_size >= 500_000_000
        }
        let reachable = offloads.filter { isUsableImage($0.installer) }
        // Not reachable, but on a /Volumes path with nothing mounted: the vault is unplugged, not
        // gone. Distinguished with the same mount primitive `runtime export`/`offload` use.
        let disconnected = offloads.filter { !isUsableImage($0.installer) && RuntimeOperations.isNotOnAMountedVolume(destination: $0.installer) }

        // Identity matching where the journal carries it. Entries written before `detail` gained the
        // runtime identity have `rid == nil` and cannot be matched — those degrade to neutral wording
        // rather than an affirmative promise about devices they may have nothing to do with.
        let matched = reachable.filter { rid in rid.rid.map(deviceRuntimes.contains) ?? false }
        let unidentified = reachable.filter { $0.rid == nil }

        func importList(_ items: [(installer: String, rid: String?)]) -> String {
            let shown = items.prefix(5).map { "`xcodevaultctl runtime import \(OwnershipAdvice.shellQuoted($0.installer))`" }
            let more = items.count > 5 ? " (+\(items.count - 5) more — see `xcodevaultctl runtime library`)" : ""
            return shown.joined(separator: ", then ") + more
        }
        // Replicated, but on one configuration: macOS 26.6.2 / Xcode 26.5 / x86_64, iOS 26.5,
        // re-imported at the SAME version (E8/H4, then F13 end-to-end through these verbs). Two runs
        // of one setup is not a law, and the same-version precondition is load-bearing — a
        // cross-version import has never been tried, so the user has to see the qualifier. E11 is the
        // staging-space experiment; the device-return finding belongs to the import round trip.
        let caveat =
            "Observed twice on one configuration (macOS 26.6.2 / Xcode 26.5 / Intel, iOS 26.5, re-imported at the same version — E8/H4, F13); "
            + "a cross-version import has not been tried. Re-import first and confirm the devices come back before deleting anything."

        let remediation: String
        let evidence: String
        if !matched.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` — it is permanent. Re-import instead: \(importList(matched)). "
                + "The devices should return to Shutdown with their data. \(caveat) "
                + "Delete them only if you have decided you no longer want these devices at all."
            evidence = "docs/architecture/HYPOTHESES.md H4 (E8 import round trip)"
        } else if !unidentified.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` yet — it is permanent. XCodeVault offloaded "
                + "\(unidentified.count == 1 ? "a runtime" : "\(unidentified.count) runtimes") and the installer is still on the vault, but the journal entry "
                + "predates recording which runtime it was, so this cannot confirm it matches these devices. "
                + "Check `xcodevaultctl runtime library --dir <your library>` before deleting anything."
            evidence = "docs/architecture/HYPOTHESES.md H4 (E8 import round trip)"
        } else if !disconnected.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` — it is permanent, and these devices may be recoverable. XCodeVault offloaded "
                + "\(disconnected.count == 1 ? "a runtime whose installer is" : "\(disconnected.count) runtimes whose installers are") recorded at "
                + "\(disconnected.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", ")), on a volume that is not mounted. "
                + "Reconnect it and re-run `xcodevaultctl doctor`."
            evidence = "CLAUDE.md rule 6 (a disconnected volume is a first-class failure mode)"
        } else if read == nil || read?.isComplete == false {
            remediation =
                "Not advising deletion: XCodeVault could not read its journal in full, so it cannot tell whether these devices' runtime was offloaded "
                + "and is recoverable. `xcrun simctl delete unavailable` is permanent — check `xcodevaultctl journal` first."
            evidence = "CLAUDE.md rule 5"
        } else {
            remediation =
                "`xcrun simctl delete unavailable` removes devices whose runtime is gone. This is permanent — the device data goes with them — and the "
                + "journal records no offloaded runtime that could bring these back."
            evidence = "simctl help"
        }
        return [
            Finding(
                id: "unavailable-devices", severity: .warning, title: "\(bad.count) simulator device(s) unavailable (\(ByteCount.format(bytes)))",
                detail: bad.prefix(5).map { "\($0.name): \($0.availabilityError ?? "runtime missing")" }.joined(separator: "; "),
                path: home + "/Library/Developer/CoreSimulator/Devices", remediation: remediation, evidence: evidence)
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
