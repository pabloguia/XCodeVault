import Foundation

/// The CoreSimulator rule family: the simulator runtime registry, the stranded runtime Inbox,
/// orphaned dyld caches, orphaned MobileAssets, and unavailable devices.
///
/// Split out of `Doctor.swift` under issue #11, and the reason is a two-reasons-to-change boundary
/// rather than a size complaint. **These rules are versioned by Apple's release schedule**; every
/// other rule in `Doctor.swift` is versioned by this project's. When CoreSimulator changes its
/// on-disk layout — as it has for the dyld cache path, the Inbox reaping behaviour and the runtime
/// registry — the edit lands here and nowhere else.
///
/// `Doctor+Vault.swift` already established the extension-in-its-own-file shape; this follows it.
///
/// **Where the boundary was drawn, and the judgement in it.** The issue named lines 471-941, which
/// is exactly these five rules. `checkPerDeviceRegenerables` is arguably also CoreSimulator-versioned
/// — it reads per-device subpaths and cites F22 — and it was deliberately left in `Doctor.swift`,
/// because moving it would have made the split something other than what the issue described, and a
/// structural move is only verifiable against a boundary somebody stated in advance. If it belongs
/// here, that is a second, separately reviewable move.
///
/// **How this was proved to preserve behaviour**, which is the method S2 of the review prescribes
/// and the reason the split waited: the test-name list was captured before and after and diffed to
/// empty, and the suite re-run. Nothing here is a rewrite — the functions are byte-identical to
/// their previous text.
extension Doctor {
    func checkRuntimeRegistry(runtimes: [SimulatorRuntime]) -> [Finding] {
        var out: [Finding] = []
        for r in runtimes {
            let name = r.runtimeIdentifier ?? r.identifier
            // Collapse direction (issue #25): `.undetermined` raises the finding. A runtime that
            // claims Ready at a path whose mount state cannot be read is worth saying out loud.
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
                        detail:
                            "Files left in the Inbox after a runtime download/install are not reclaimed by Xcode — observed even after a successful `-downloadPlatform -exportPath` followed by `simctl runtime delete`.",
                        path: p,
                        remediation:
                            "Restart the Mac: simdiskimaged reaps the Inbox at startup (verified 2026-09-07, 5 GB reclaimed). Deleting by hand does not work — even `sudo rm` is refused (Operation not permitted) on macOS 26.5. If it survives a reboot, report to Apple.",
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
                        title:
                            "Dyld caches for macOS \(buildDir), which this machine no longer runs (\(usage.map { ByteCount.format($0.allocatedBytes) } ?? "size unknown"))",
                        detail:
                            "This machine runs \(hostBuild). Caches under another build are not read by anything — but XCodeVault has never observed a stale "
                            + "build directory in the field, so this is reported for inspection only and carries no command.",
                        path: buildPath,
                        remediation:
                            "Inspect it. If it is genuinely a leftover from a macOS update, report what you find so this can be turned into a real rule.",
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
        //
        // Matched by installer **path**, and a reviewer noted this is a fourth route to the branch
        // that says nothing was offloaded: if the only offload entry has a completed import against
        // the same path, `offloads` comes out empty and that sentence is produced with a perfectly
        // good installer sitting on disk. Left as is deliberately — a completed import means the
        // runtime was already restored once, so re-importing it again is not the advice these
        // devices need, and the sentence is then true of the *outstanding* offloads, which is what
        // it is about. Written down because it is not obvious, and the next reader should not have
        // to re-derive it.
        let reimported = Set(entries.filter { $0.kind == .runtimeImport && $0.state == .completed }.flatMap(\.paths))
        /// An offload that wrote `.started` and never wrote a terminal line.
        ///
        /// **A reviewer found this reading the journal end to end (issue #26, B1).** `offload`
        /// journals `.started`, runs `simctl runtime delete`, then journals `.completed`. Lose power,
        /// or ^C a hung `simctl`, in between and the runtime is gone, the devices are unavailable,
        /// the installer is on the vault — and the journal holds only `.started`. This rule used to
        /// read `.completed` and nothing else, so that entry vanished, every category came out empty,
        /// and control reached the final branch: "the journal records no offloaded runtime that could
        /// bring these back", which green-lights a permanent delete. Exactly the F2 falsehood, by the
        /// crash route instead of the foreign-drive route.
        ///
        /// `.failed` is deliberately not here: it means the delete did not happen.
        let terminal = Set(entries.filter { $0.kind == .runtimeOffload && ($0.state == .completed || $0.state == .failed) }.map(\.id))

        struct Offload {
            let installer: String
            let rid: String?
            let volumeUUID: String?
            /// False when the journal never recorded how this offload ended.
            let finished: Bool
        }
        var seen = Set<String>()
        let offloads =
            entries
            .filter { $0.kind == .runtimeOffload && ($0.state == .completed || ($0.state == .started && !terminal.contains($0.id))) }
            .compactMap { e -> Offload? in
                guard let path = e.detail["installer"] ?? e.paths.first, !reimported.contains(path), seen.insert(path).inserted else { return nil }
                // Empty means the entry predates the field (#26) or the filesystem reported no
                // UUID — either way it is "no identity recorded", which is not the same as a
                // recorded identity that fails to match.
                let uuid = e.detail["installerVolumeUUID"].flatMap { $0.isEmpty ? nil : $0 }
                return Offload(installer: path, rid: e.detail["runtimeIdentifier"], volumeUUID: uuid, finished: e.state == .completed)
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
        /// Whether the file now at that path is on the volume this offload verified (#26).
        ///
        /// The whole safety argument for `runtime offload` is "delete the installed runtime only
        /// because an installer exists to restore it from", and this rule re-states that argument
        /// to the user. It used to re-state it from a **path**. On a machine with two external
        /// drives — or one that comes back as `/Volumes/VAULT 1` after an unclean eject, leaving
        /// the original mount-point directory behind — a file of the right size at the right path
        /// can belong to somebody else entirely, and the user would be told their devices are
        /// recoverable from an image nothing checked.
        ///
        /// `notRecorded` means the journal has no identity to check: entries written before the
        /// field existed, and filesystems that report no UUID. Those stay in `reachable` rather
        /// than being demoted — demoting them would tell a user with a perfectly good installer
        /// that their devices are unrecoverable, which is the more dangerous error of the two —
        /// and `unverifiable` below carries them through to the wording, so nothing promises more
        /// than was actually checked.
        ///
        /// An earlier version of this comment claimed that separation while the code did not make
        /// it: a `nil`-identity entry whose runtime id matched went into `matched` and collected the
        /// full "Re-import instead" promise with no qualifier at all. A reviewer caught the comment
        /// asserting a property its own code lacked, which is worse than the gap — the next reader
        /// trusts it.
        ///
        /// The comparison itself lives in `MountStatus` so this and `RuntimeOperations.offload`
        /// cannot drift: one warns about a deletion the other performs.
        /// What one offload entry is, decided **once**.
        ///
        /// **Why a stored value and not six `filter`s (issue #26, B2).** The predicates are syscalls:
        /// `isUsableImage` does an `lstat`, `identity` reads a volume UUID. The previous version
        /// evaluated them two and three times per entry across separate passes, and the claim that
        /// the six lists partitioned the entries held only if the filesystem answered identically
        /// every time. It does not have to: eject the drive mid-`diagnose` and one entry is `usable`
        /// in the first pass and not in the third, which lands it in two categories — or, with the
        /// opposite flip, in none, and a single such entry sends the whole finding to the branch that
        /// says nothing was offloaded. That is the same TOCTOU class this issue's other fix closed in
        /// `offload()`, one file over.
        ///
        /// One `map`, one answer per entry, and the partition becomes a property of the code instead
        /// of a property of the disk holding still.
        enum Disposition {
            /// A usable image, on the volume this offload verified.
            case verified
            /// A usable image, and nothing was recorded to check it against.
            case unverifiable
            /// A usable image on a **different** volume than the one verified — the case the path
            /// alone cannot see, and the one issue #26 exists for.
            case foreignVolume
            /// No usable image, and the path is on a `/Volumes` location with nothing mounted: the
            /// vault is unplugged, not gone.
            case disconnected
            /// No usable image, and that volume **is** mounted (finding F2).
            case missingOnMountedVolume
            /// The journal never recorded how this offload ended (finding B1).
            case interrupted
        }
        let classified: [(offload: Offload, disposition: Disposition)] = offloads.map { o in
            guard o.finished else { return (o, .interrupted) }
            if isUsableImage(o.installer) {
                switch MountStatus.compareVolumeIdentity(recorded: o.volumeUUID, found: volumeUUIDAt(o.installer)) {
                case .matches: return (o, .verified)
                case .notRecorded: return (o, .unverifiable)
                case .differs, .unreadable: return (o, .foreignVolume)
                }
            }
            return (o, RuntimeOperations.isNotOnAMountedVolume(destination: o.installer) ? .disconnected : .missingOnMountedVolume)
        }
        func inState(_ states: Disposition...) -> [Offload] {
            classified.filter { states.contains($0.disposition) }.map(\.offload)
        }

        let reachable = inState(.verified, .unverifiable)
        /// Reachable, and nothing was recorded to check it against. Kept usable — demoting it would
        /// tell a user with a perfectly good installer that their devices are unrecoverable — but
        /// named, because the sentence a user reads must not say the drive was confirmed.
        let unverifiable = inState(.unverifiable)
        let foreignVolume = inState(.foreignVolume)
        let disconnected = inState(.disconnected)
        let missingOnMountedVolume = inState(.missingOnMountedVolume)
        let interrupted = inState(.interrupted)

        // Identity matching where the journal carries it. Entries written before `detail` gained the
        // runtime identity have `rid == nil` and cannot be matched — those degrade to neutral wording
        // rather than an affirmative promise about devices they may have nothing to do with.
        let matched = reachable.filter { $0.rid.map(deviceRuntimes.contains) ?? false }
        let unidentified = reachable.filter { $0.rid == nil }
        /// Reachable, identified, and belonging to some *other* set of devices than these.
        ///
        /// `matched` and `unidentified` do not cover `reachable`, and the remainder used to fall to
        /// the final branch. That sentence is true there only if the `runtimeIdentifier` recorded
        /// from `simctl runtime list` is byte-identical to the key `simctl list devices` reports —
        /// an unverified string-equality assumption between two subcommands, carrying a
        /// delete-green-light. A neutral branch costs three lines and removes the assumption.
        let unmatched = reachable.filter { o in o.rid.map { !deviceRuntimes.contains($0) } ?? false }

        func importList(_ items: [Offload]) -> String {
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
            // Named rather than assumed: if any of these had no recorded volume identity, the
            // promise is still the right one — an installer is there and its runtime id matches —
            // but it rests on a path, and the user is told so in the same breath.
            let unchecked = matched.filter { m in unverifiable.contains { $0.installer == m.installer } }
            let identityCaveat =
                unchecked.isEmpty
                ? ""
                : " Note: \(unchecked.count == 1 ? "one of these entries predates" : "\(unchecked.count) of these entries predate") "
                    + "recording which drive the installer was on (or the drive reports no identity), so this matched the file by path and "
                    + "size, not by volume — confirm it is the drive you expect before relying on it."
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` — it is permanent. Re-import instead: \(importList(matched)). "
                + "The devices should return to Shutdown with their data.\(identityCaveat) \(caveat) "
                + "Delete them only if you have decided you no longer want these devices at all."
            evidence = "docs/architecture/HYPOTHESES.md H4 (E8 import round trip)"
        } else if !unidentified.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` yet — it is permanent. XCodeVault offloaded "
                + "\(unidentified.count == 1 ? "a runtime" : "\(unidentified.count) runtimes") and the installer is still on the vault, but the journal entry "
                + "predates recording which runtime it was, so this cannot confirm it matches these devices. "
                + "Check `xcodevaultctl runtime library --dir <your library>` before deleting anything."
            evidence = "docs/architecture/HYPOTHESES.md H4 (E8 import round trip)"
        } else if !foreignVolume.isEmpty {
            // Ordered before `disconnected` deliberately: a file *is* present at the path, so the
            // disconnected branch's sentence ("on a volume that is not mounted") would be false.
            // This is the case issue #26 exists for, and it has to read as a warning about
            // identity, not as a missing file.
            remediation =
                "Do NOT run `xcrun simctl delete unavailable`, and do NOT assume the image at that path will restore these devices. XCodeVault "
                + "offloaded \(foreignVolume.count == 1 ? "a runtime" : "\(foreignVolume.count) runtimes") and recorded which drive the installer "
                + "was on. There IS a file at \(foreignVolume.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", ")), "
                + "but it is on a different volume than the one that was verified — most likely another drive mounted at the same path, or the vault "
                + "returned as `\u{27}<name> 1\u{27}` after an unclean eject and left its old mount-point directory behind. Reconnect the original "
                + "drive and re-run `xcodevaultctl doctor`; check `xcodevaultctl volumes` to see which is which."
            evidence = "CLAUDE.md rule 6 (a mount point is not an identity)"
        } else if !interrupted.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` — it is permanent. XCodeVault began "
                + "\(interrupted.count == 1 ? "an offload" : "\(interrupted.count) offloads") and never recorded how it ended, most likely a "
                + "crash or a power loss between deleting the runtime and writing the result. The runtime may already be gone while the installer "
                + "at \(interrupted.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", ")) is perfectly good. "
                + "Check `xcodevaultctl journal` and `xcodevaultctl runtime library --dir <your library>`, then re-import before deleting anything."
            evidence = "CLAUDE.md rule 5 (an offload is recorded; its outcome is not)"
        } else if !disconnected.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` — it is permanent, and these devices may be recoverable. XCodeVault offloaded "
                + "\(disconnected.count == 1 ? "a runtime whose installer is" : "\(disconnected.count) runtimes whose installers are") recorded at "
                + "\(disconnected.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", ")), on a volume that is not mounted. "
                + "Reconnect it and re-run `xcodevaultctl doctor`."
            evidence = "CLAUDE.md rule 6 (a disconnected volume is a first-class failure mode)"
        } else if !missingOnMountedVolume.isEmpty {
            remediation =
                "Do NOT run `xcrun simctl delete unavailable` yet — it is permanent. XCodeVault offloaded "
                + "\(missingOnMountedVolume.count == 1 ? "a runtime" : "\(missingOnMountedVolume.count) runtimes") and recorded the installer at "
                + "\(missingOnMountedVolume.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", ")). "
                + "That volume IS mounted and the installer is not there, or is too small to be one — it may have been moved or deleted, or "
                + "another drive may be mounted at that path. Check `xcodevaultctl runtime library --dir <your library>` and "
                + "`xcodevaultctl volumes` before deleting anything."
            evidence = "CLAUDE.md rule 5 (the journal records an offload; the installer is not where it was)"
        } else if !unmatched.isEmpty {
            remediation =
                "Not advising deletion. XCodeVault offloaded "
                + "\(unmatched.count == 1 ? "a runtime" : "\(unmatched.count) runtimes") and the installer is on the vault, but the recorded "
                + "runtime identity does not match any of these unavailable devices — so these devices are probably not the ones that offload "
                + "was about. `xcrun simctl delete unavailable` is permanent; check `xcodevaultctl journal` and "
                + "`xcodevaultctl runtime library --dir <your library>` first."
            evidence = "CLAUDE.md rule 5"
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
        // **Appended, not exclusive (review finding N3).** The chain above picks one sentence, and a
        // category that loses the race used to go unmentioned: two offload entries, one reachable and
        // matching, one sitting on a foreign drive at the vault's old mount point, and the user was
        // told "Re-import instead" with no word about the second. The chosen sentence was the safe
        // one, so this was never a deletion path — but `MIGRATION_ENGINE.md` requires shadow data to
        // be *surfaced*, and #26 exists precisely to surface that entry.
        var warnings: [String] = []
        if !foreignVolume.isEmpty, !remediation.contains("different volume") {
            warnings.append(
                "Separately: \(foreignVolume.count == 1 ? "an installer" : "\(foreignVolume.count) installers") recorded by an earlier offload "
                    + "\(foreignVolume.count == 1 ? "is" : "are") on a different volume than the one that was verified "
                    + "(\(foreignVolume.prefix(3).map { OwnershipAdvice.shellQuoted($0.installer) }.joined(separator: ", "))). Do not rely on "
                    + "\(foreignVolume.count == 1 ? "it" : "them") to restore anything until you have checked `xcodevaultctl volumes`.")
        }
        if !interrupted.isEmpty, !remediation.contains("never recorded how it ended") {
            warnings.append(
                "Separately: the journal shows \(interrupted.count == 1 ? "an offload that began" : "\(interrupted.count) offloads that began") "
                    + "and never recorded how it ended — most likely a crash or a power loss mid-operation. The runtime may already be gone while "
                    + "the installer is fine. Check `xcodevaultctl journal` before deleting anything.")
        }
        let fullRemediation = ([remediation] + warnings).joined(separator: " ")

        return [
            Finding(
                id: "unavailable-devices", severity: .warning, title: "\(bad.count) simulator device(s) unavailable (\(ByteCount.format(bytes)))",
                detail: bad.prefix(5).map { "\($0.name): \($0.availabilityError ?? "runtime missing")" }.joined(separator: "; "),
                path: home + "/Library/Developer/CoreSimulator/Devices", remediation: fullRemediation, evidence: evidence)
        ]
    }
}
