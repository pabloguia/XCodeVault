import Foundation

/// Plain-text rendering shared by the CLI (and reusable by the GUI's "copy report").
public enum TextRenderer {
    public static func status(_ r: ScanReport) -> String {
        var o = ""
        o += "XCodeVault \(r.toolVersion) · catalog \(r.catalogVersion) · \(iso(r.generatedAt))\n"
        o +=
            "macOS \(r.host.macOSVersion) (\(r.host.macOSBuild)) · \(r.host.architecture) · internal free \(ByteCount.format(r.host.dataVolumeFreeBytes)) of \(ByteCount.format(r.host.dataVolumeTotalBytes))\n"
        o += "\nXcode installations:\n"
        if r.xcodes.isEmpty { o += "  (none found)\n" }
        for x in r.xcodes {
            let caps = x.capabilities
            var flags: [String] = []
            if caps.supportsRuntimeLibrary { flags.append("runtime-library") }
            if caps.architectureVariant { flags.append("arch-variant") }
            if caps.downloadComponent { flags.append("components") }
            if caps.prepareDeviceSupport { flags.append("prepare-device-support") }
            o += "  \(x.isSelected ? "*" : " ") \(x.version) (\(x.build))  \(x.path)  [\(flags.joined(separator: ", "))]\n"
        }
        o += "\nSimulator runtimes (\(r.runtimes.count), \(ByteCount.format(r.summary.runtimeImageBytes))):\n"
        for rt in r.runtimes {
            o +=
                "  \(pad(rt.platformName, 9)) \(pad(rt.version ?? "?", 7)) \(pad(rt.build ?? "?", 8)) \(pad(rt.state ?? "?", 8)) \(pad(ByteCount.format(rt.sizeBytes ?? 0), 9)) \(rt.isMounted ? "mounted" : "NOT mounted")  \(rt.isMobileAssetBacked ? "MobileAsset store" : rt.path ?? "")\n"
        }
        o +=
            "\nSimulator devices: \(r.devices.count) (\(r.devices.filter { !$0.isAvailable }.count) unavailable), \(ByteCount.format(r.devices.reduce(0) { $0 + ($1.dataPathSize ?? 0) }))\n"
        o += "\nVolumes:\n"
        for v in r.volumes {
            let q = VolumeQualification.evaluate(v)
            o +=
                "  \(pad(v.volumeName, 18)) \(pad(v.filesystemPersonality, 20)) \(pad(v.busProtocol, 12)) \(v.isInternal ? "internal" : "external") free \(pad(ByteCount.format(v.freeBytes), 10)) \(v.isBootVolume ? "boot" : q.verdict.rawValue)\n"
        }
        return o
    }

    public static func scan(_ r: ScanReport) -> String {
        var o = status(r)
        o += "\nStorage categories (sizes are on-disk, not crossing mounts):\n"
        o += "  \(pad("SIZE", 10)) \(pad("CATEGORY", 34)) \(pad("OUTCOME", 15)) \(pad("STRATEGY", 21)) PATH\n"
        let items = r.items.filter { $0.exists }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        for it in items {
            guard let c = r.category(for: it) else { continue }
            let label = c.isExperimental ? c.recommendedStrategy.rawValue + " (exp.)" : c.recommendedStrategy.rawValue
            let extra =
                it.isSymlink
                ? "  → SYMLINK to \(it.symlinkTarget ?? "?")"
                : (it.isMountPoint ? "  [mount point]" : "") + (it.onBootVolume ? "" : "  [not on boot volume]")
                    + ((it.usage?.isLowerBound ?? false) ? "  [partial: unreadable entries]" : "")
                    // Without this the rows stop adding up to the Summary and nothing says why: a
                    // breakdown row's bytes are already inside its parent's row, and are counted
                    // once, there. Naming the parent is what keeps the reader from adding them.
                    + (it.breakdownParentName(in: r).map { "  [inside \($0)]" } ?? "")
            o += "  \(pad(ByteCount.format(it.allocatedBytes), 10)) \(pad(c.name, 34)) \(pad(c.outcomeLabel, 15)) \(pad(label, 21)) \(it.path)\(extra)\n"
        }
        let s = r.summary
        o += "\nSummary:\n"
        o += "  Internal developer storage found:   \(ByteCount.format(s.internalDeveloperBytes))\(s.lowerBound ? " (lower bound)" : "")\n"
        o +=
            "    of which simulator runtime images: \(ByteCount.format(s.runtimeImageBytes))  (delete with `simctl runtime delete`, keep installers externally)\n"
        o += "  Safely cleanable:                   \(ByteCount.format(s.cleanableBytes))\n"
        o += "  Relocatable (supported mechanisms): \(ByteCount.format(s.relocatableBytes))\n"
        o += "  Cold-storage eligible:              \(ByteCount.format(s.coldStorageEligibleBytes))\n"
        o += "  Apple-managed (info only):          \(ByteCount.format(s.appleManagedBytes))\n"
        o += "  Must remain local:                  \(ByteCount.format(s.mustRemainLocalBytes))\n"
        o += "  Reclaimable from the boot volume:   \(ByteCount.format(s.estimatedInternalSavingsBytes))  via recommended cleanup/relocation\n"
        o += "    with verified strategies only:    \(ByteCount.format(s.verifiedSavingsBytes))  (the rest is labeled experimental — see `compatibility`)\n"
        if !r.warnings.isEmpty {
            o += "\nWarnings:\n"; for w in r.warnings { o += "  ! \(w)\n" }
        }
        return o
    }

    public static func findings(_ findings: [Finding]) -> String {
        if findings.isEmpty { return "doctor: no findings.\n" }
        var o = "doctor: \(findings.count) finding(s)\n"
        for f in findings {
            o += "\n[\(f.severity.rawValue.uppercased())] \(f.title)\n"
            o += "  \(f.detail)\n"
            if let p = f.path { o += "  path: \(p)\n" }
            if let r = f.remediation { o += "  → \(r)\n" }
            if let e = f.evidence { o += "  evidence: \(e)\n" }
        }
        return o
    }

    public static func compatibility(_ catalog: [StorageCategory]) -> String {
        var o = "\(pad("CATEGORY", 34)) \(pad("STRATEGY", 21)) \(pad("STATUS", 13)) \(pad("PRIV", 5)) EVIDENCE\n"
        for c in catalog {
            o +=
                "\(pad(c.name, 34)) \(pad(c.recommendedStrategy.rawValue, 21)) \(pad(c.isExperimental ? "experimental" : c.evidenceStatus.rawValue, 13)) \(pad(c.privilege.rawValue, 5)) \(c.evidence ?? "(none — unverified)")\n"
        }
        return o
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}

public enum JSONOutput {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return String(decoding: try e.encode(value), as: UTF8.self)
    }
}
