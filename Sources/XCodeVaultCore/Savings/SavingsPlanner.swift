import Foundation

/// One line of `xcodevaultctl plan`: a category, what it frees on the boot volume, and the command that does it.
public struct SavingsPlanRow: Sendable, Codable, Equatable {
    public let categoryID: String
    public let categoryName: String
    /// Boot-volume bytes counted for this category (0 for an option that only redirects new data).
    public let bytes: UInt64
    public let option: SavingsOption
    /// The command the user runs; `<angle brackets>` are values they supply. Never translated.
    public let command: String
}

public enum SavingsPlanner {
    /// One row per category offering `bucket`, largest first; categories whose option only redirects new data are
    /// listed with 0 bytes. Counts the same items as `SavingsCalculator` (exists, not a symlink, on the boot volume,
    /// not a breakdown). A category with nothing on this Mac is not listed, except for an option that only
    /// redirects new data, which does not need existing data.
    public static func rows(report: ScanReport, bucket: SavingsBucket) -> [SavingsPlanRow] {
        var bytesByCategory: [String: UInt64] = [:]
        for (item, c) in SavingsCalculator.countedItems(report.items, category: StorageCatalog.category) {
            bytesByCategory[c.id, default: 0] += item.allocatedBytes
        }
        var rows: [SavingsPlanRow] = []
        for c in StorageCatalog.all {
            guard let option = c.savingsOptionDetails.first(where: { $0.bucket == bucket }), let command = command(categoryID: c.id, bucket: bucket) else {
                continue
            }
            let counted = bytesByCategory[c.id]
            guard counted != nil || !option.appliesToExistingData else { continue }
            rows.append(
                SavingsPlanRow(
                    categoryID: c.id, categoryName: c.name, bytes: option.appliesToExistingData ? (counted ?? 0) : 0, option: option, command: command))
        }
        return rows.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.categoryName < $1.categoryName }
    }

    /// The command for a (category, bucket) pair; nil when the pair is not offered. Only the preview form of each
    /// command is ever listed (no `--apply`, `--yes` ...), so the command's own dry run or confirmation speaks at
    /// the moment of decision. Every spelling was checked against the command's declaration in `Sources/xcodevaultctl` by hand: no test can import that target.
    public static func command(categoryID: String, bucket: SavingsBucket) -> String? {
        guard let c = StorageCatalog.category(categoryID), c.savingsOptions.contains(bucket) else { return nil }
        switch (bucket, categoryID) {
        case (.deleteAndRegenerate, "simulatorRuntimeAssets"): return "xcodevaultctl runtime delete <identifier> --dry-run"
        case (.deleteAndRegenerate, "simulatorDevices"): return "xcrun simctl delete <udid>"
        case (.deleteAndRegenerate, _): return "xcodevaultctl clean --category \(categoryID)"
        case (.parkExternally, "archives"): return "xcodevaultctl externalize --category archives --vault <vault>"
        case (.parkExternally, "simulatorRuntimeAssets"): return "xcodevaultctl runtime offload <identifier> --library <dir>"
        case (.runFromExternal, "derivedData"): return "xcodevaultctl locations set-derived-data <dir>"
        case (.runFromExternal, "archives"): return "xcodevaultctl locations set-archives <dir>"
        case (.runFromExternal, "runtimeLibrary"): return "xcodevaultctl runtime export <platform> --to <dir>"
        default: return nil
        }
    }

    /// Commands with no preview of their own: they apply (or download) the moment they are run.
    static let actsImmediately: Set<String> = [
        "simulatorDevices/deleteAndRegenerate", "derivedData/runFromExternal", "archives/runFromExternal", "runtimeLibrary/runFromExternal",
    ]

    /// A one-line caveat the user needs before running the row's command. Text only, never in JSON.
    static func note(categoryID: String, bucket: SavingsBucket) -> String? {
        switch (bucket, categoryID) {
        case (.parkExternally, "archives"): return L10n.tr("cli.plan.note.archivesPark")
        case (.runFromExternal, "derivedData"): return L10n.tr("cli.plan.note.derivedDataExternal")
        case (.deleteAndRegenerate, "simulatorDevices"): return L10n.tr("cli.plan.note.simctlDelete")
        default: return nil
        }
    }

    /// The plan as text, in the chosen language: the bucket's title, promise and undo cost, then one entry per row.
    public static func render(rows: [SavingsPlanRow], bucket: SavingsBucket) -> String {
        var o = "\(bucket.localizedTitle)\n\(bucket.localizedPromise)\n\(bucket.localizedUndoCost)\n\n"
        guard !rows.isEmpty else { return o + L10n.tr("cli.plan.empty") + "\n" }
        for r in rows {
            var markers: [String] = []
            if r.option.isExperimental { markers.append(L10n.tr("cli.plan.marker.experimental")) }
            if r.option.losesUserData { markers.append(L10n.tr("cli.plan.marker.losesUserData")) }
            if actsImmediately.contains("\(r.categoryID)/\(bucket.rawValue)") { markers.append(L10n.tr("cli.plan.marker.actsImmediately")) }
            if !r.option.appliesToExistingData { markers.append(L10n.tr("cli.plan.marker.newDataOnly")) }
            let size = r.option.appliesToExistingData ? "  " + ByteCount.format(r.bytes) : ""
            o += "  \(r.categoryName)\(size)" + (markers.isEmpty ? "" : "  (" + markers.joined(separator: ", ") + ")") + "\n      \(r.command)\n"
            if let note = note(categoryID: r.categoryID, bucket: bucket) { o += "      \(note)\n" }
        }
        return o
    }
}
