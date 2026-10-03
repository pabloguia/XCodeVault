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
            if !x.capabilitiesProbed { flags.append("capabilities not probed") }
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

    /// The status, then the savings; the per-item table only with `details`. Warnings are safety information
    /// and are always printed.
    public static func scan(_ r: ScanReport, details: Bool = false, colors: Bool = false) -> String {
        var o = status(r)
        // Without sizes every amount would be zero, which reads as "nothing to reclaim" rather than "not measured".
        let measured = r.sizesMeasured
        o +=
            "\n"
            + (measured
                ? savings(r.savings, runtimeImageBytes: r.summary.runtimeImageBytes, colors: colors) : L10n.tr("cli.savings.notMeasured", "xcodevaultctl scan"))
        if details {
            o += "\nStorage categories (sizes are on-disk, not crossing mounts):\n"
            o += "  \(pad("SIZE", 10)) \(pad("CATEGORY", 34)) \(pad("OUTCOME", 15)) \(pad("STRATEGY", 21)) PATH\n"
            let items = r.items.filter { $0.exists }.sorted { $0.allocatedBytes > $1.allocatedBytes }
            for it in items {
                guard let c = r.category(for: it) else { continue }
                let label = c.isExperimental ? c.recommendedStrategy.rawValue + " (exp.)" : c.recommendedStrategy.rawValue
                let extra =
                    it.isSymlink
                    ? "  → SYMLINK to \(it.symlinkTarget ?? "?")"
                    : (it.isMountPoint ? "  [mount point]" : "") + (it.mountStateUndetermined ? "  [mount state unreadable]" : "")
                        + (it.onBootVolume ? "" : "  [not on boot volume]")
                        + ((it.usage?.isLowerBound ?? false) ? "  [partial: unreadable entries]" : "")
                        // Without this the rows stop adding up to the savings block and nothing says why: a
                        // breakdown row's bytes are already inside its parent's row, and are counted
                        // once, there. Naming the parent is what keeps the reader from adding them.
                        + (it.breakdownParentName(in: r).map { "  [inside \($0)]" } ?? "")
                o += "  \(pad(ByteCount.format(it.allocatedBytes), 10)) \(pad(c.name, 34)) \(pad(c.outcomeLabel, 15)) \(pad(label, 21)) \(it.path)\(extra)\n"
            }
        }
        if !r.warnings.isEmpty {
            if !o.hasSuffix("\n") { o += "\n" }
            o += "\nWarnings:\n"; for w in r.warnings { o += "  ! \(w)\n" }
        }
        return o
    }

    /// What `status` ends with: the next step, and why a measurement may be incomplete.
    public static func statusFooter(fullDiskAccess: FullDiskAccessState) -> String {
        var o = "\n" + L10n.tr("cli.status.measureHint", "xcodevaultctl scan") + "\n"
        if fullDiskAccess == .notGranted { o += L10n.tr("cli.status.fdaHint", "xcodevaultctl permissions") + "\n" }
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
            if let a = f.action { o += "  privileged action: \(a.title) — needs the privileged helper; see `xcodevaultctl permissions`\n" }
            if let e = f.evidence { o += "  evidence: \(e)\n" }
        }
        return o
    }

    public static func permissions(_ r: PermissionsReport) -> String {
        var o = "Full Disk Access: \(r.fullDiskAccess.state.displayName)\n"
        o += "  why:  \(r.fullDiskAccess.why)\n"
        o += "  next: \(r.fullDiskAccess.nextStep)\n"
        o += "Privileged helper: \(r.helper.state.displayName)\n"
        o += "  why:  \(r.helper.why)\n"
        o += "  next: \(r.helper.nextStep)\n"
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

    /// The savings block (spec 2026-10-03 §5): both headlines, each option with its undo cost, the stay-local
    /// remainder and the next command. Every column is padded by display width, so wide scripts stay aligned.
    /// Under the delete row, the part that does not come back (simulator devices); after the stay-local row, the
    /// runtime images simctl measured (`runtimeImageBytes`, from `ScanSummary`), which no catalog category counts yet.
    /// With `colors`, each bucket title is wrapped in its 24-bit color after the row is padded, so the codes never
    /// count toward width. For a terminal only: records (`report`, `--json`) and pipes never pass it.
    public static func savings(_ s: SavingsSummary, runtimeImageBytes: UInt64, colors: Bool = false) -> String {
        func headline(_ bytes: UInt64) -> String {
            let amount = ByteCount.format(bytes)
            return s.isLowerBound ? L10n.tr("savings.atLeast", amount) : L10n.tr("savings.upTo", amount)
        }
        func option(_ bytes: UInt64) -> String { s.isLowerBound ? headline(bytes) : ByteCount.format(bytes) }

        struct Row {
            var label: String
            var amount: String
            var note: String = ""
            /// An indented line printed right under this row, outside the aligned columns.
            var detail: String?
            /// The bucket whose title this row's label ends with, when it is one that gets a color.
            var bucket: SavingsBucket?
        }
        func bucketRow(_ b: SavingsBucket) -> Row {
            Row(label: "    " + b.localizedTitle, amount: option(s[b].optionBytes), note: b.localizedUndoCost, bucket: b)
        }
        func verified(_ bytes: UInt64) -> String { "(" + L10n.tr("savings.verifiedShare", ByteCount.format(bytes)) + ")" }

        var delete = bucketRow(.deleteAndRegenerate)
        if s.deleteLosesUserDataBytes > 0 { delete.detail = "      " + L10n.tr("cli.savings.losesUserData", option(s.deleteLosesUserDataBytes)) }
        let rows: [Row] = [
            Row(label: "  " + L10n.tr("savings.temporary.title"), amount: headline(s.temporaryBytes), note: verified(s.verifiedTemporaryBytes)),
            delete,
            bucketRow(.parkExternally),
            Row(label: "  " + L10n.tr("savings.permanent.title"), amount: headline(s.permanentBytes), note: verified(s.verifiedPermanentBytes)),
            bucketRow(.runFromExternal),
            Row(label: "  " + L10n.tr("savings.total.title"), amount: headline(s.reclaimableBytes)),
        ]
        let keep = Row(label: "  " + SavingsBucket.keepLocal.localizedTitle, amount: option(s.keepLocal.primaryBytes), bucket: .keepLocal)
        let all = rows + [keep]
        let labelWidth = all.map { displayWidth($0.label) }.max() ?? 0
        let amountWidth = all.map { displayWidth($0.amount) }.max() ?? 0
        func render(_ r: Row) -> String {
            let amount = String(repeating: " ", count: amountWidth - displayWidth(r.amount)) + r.amount
            var label = padDisplay(r.label, labelWidth)
            if colors, let b = r.bucket, let range = label.range(of: b.localizedTitle) {
                label.replaceSubrange(range, with: ansi(b.colorHex) + b.localizedTitle + "\u{1B}[0m")
            }
            let line = label + "  " + amount
            return r.note.isEmpty ? line : line + "   " + r.note
        }
        var out = [L10n.tr("cli.savings.heading")]
        for row in rows {
            out.append(render(row))
            if let detail = row.detail { out.append(detail) }
        }
        out.append("  " + L10n.tr("savings.alternativesNote"))
        out.append(render(keep))
        if runtimeImageBytes > 0 {
            out.append("  " + L10n.tr("cli.savings.runtimesNote", ByteCount.format(runtimeImageBytes), "xcodevaultctl runtime list"))
        }
        out.append(L10n.tr("cli.savings.next", "xcodevaultctl plan delete | park | external"))
        return out.joined(separator: "\n")
    }

    /// 24-bit foreground escape for `#RRGGBB`; empty for anything else, so a bad hex costs the color and nothing more.
    static func ansi(_ hex: String) -> String {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return "" }
        return "\u{1B}[38;2;\((v >> 16) & 0xFF);\((v >> 8) & 0xFF);\(v & 0xFF)m"
    }

    /// Terminal columns a string occupies: East Asian wide and fullwidth scalars take two, combining marks none.
    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { sum, u in
            switch u.value {
            case 0x0300...0x036F: sum
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
                sum + 2
            default: sum + 1
            }
        }
    }

    static func padDisplay(_ s: String, _ n: Int) -> String {
        let w = displayWidth(s)
        return w >= n ? s : s + String(repeating: " ", count: n - w)
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
