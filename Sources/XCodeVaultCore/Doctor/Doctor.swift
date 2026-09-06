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
    public init(home: String = NSHomeDirectory(), runner: CommandRunning = ProcessCommandRunner()) {
        self.home = home; self.runner = runner
    }

    public func diagnose(report: ScanReport) -> [Finding] {
        var f: [Finding] = []
        f += checkForbiddenSymlinks()
        f += checkBrokenSymlinks()
        f += checkPriorToolLeftovers(volumes: report.volumes)
        f += checkFreeSpace(host: report.host)
        f += checkRuntimeRegistry(runtimes: report.runtimes)
        f += checkStrandedInbox()
        f += checkOrphanedAssets(runtimes: report.runtimes)
        f += checkUnavailableDevices(devices: report.devices)
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
                why = "Breaks the Simulator's Files app (share/save/create folder) even when the target is on the same disk (H5, Aug 2025 report)."
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

    func checkPriorToolLeftovers(volumes: [Volume]) -> [Finding] {
        var out: [Finding] = []
        for v in volumes where v.isExternal || v.isDiskImage {
            guard let mp = v.mountPoint else { continue }
            let candidate = mp + "/mac-ssd-rescue"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: candidate)) ?? []
                out.append(
                    Finding(
                        id: "prior-tool:mac-ssd-rescue:\(v.id)", severity: .warning,
                        title: "mac-ssd-rescue data found on \(v.volumeName)",
                        detail:
                            "\(candidate) contains: \(contents.sorted().joined(separator: ", ")). If ~/Library/Developer no longer links here, these are stale duplicates; if it does, they are live data with a documented-broken configuration (H5).",
                        path: candidate,
                        remediation: "Compare with the local copies before deleting anything. XCodeVault `verify` will diff them in a later milestone.",
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
                        detail: "Files left in the Inbox after a failed or interrupted runtime install are never reclaimed by Xcode.",
                        path: p, remediation: "Remove after confirming no install is in progress (root required; XCodeVault helper verb in M3).",
                        evidence: "docs/research/FINDINGS-2026-09-05.md §F1"))
            }
        }
        return out
    }

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

    func checkUnavailableDevices(devices: [SimulatorDevice]) -> [Finding] {
        let bad = devices.filter { !$0.isAvailable }
        guard !bad.isEmpty else { return [] }
        let bytes = bad.reduce(0) { $0 + ($1.dataPathSize ?? 0) }
        return [
            Finding(
                id: "unavailable-devices", severity: .warning, title: "\(bad.count) simulator device(s) unavailable (\(ByteCount.format(bytes)))",
                detail: bad.prefix(5).map { "\($0.name): \($0.availabilityError ?? "runtime missing")" }.joined(separator: "; "),
                path: home + "/Library/Developer/CoreSimulator/Devices",
                remediation: "`xcrun simctl delete unavailable` removes devices whose runtime is gone.", evidence: "simctl help")
        ]
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
