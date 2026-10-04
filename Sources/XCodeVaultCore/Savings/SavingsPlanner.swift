import Foundation

/// One line of `xcodevaultctl plan`: a category, what it frees on the boot volume, and the command that does it. Every
/// fact the text shows is here too, so `plan --json` carries it; the ids in `noteIDs` are English and never translated.
public struct SavingsPlanRow: Sendable, Codable, Equatable {
    public let categoryID: String
    public let categoryName: String
    /// Boot-volume bytes counted for this category (0 for an option that only redirects new data).
    public let bytes: UInt64
    public let option: SavingsOption
    /// The command the user runs; `<angle brackets>` are values they supply. Never translated.
    public let command: String
    /// What the row's command is run over: for a command taking one `<udid>` or `<identifier>`, the devices or runtimes
    /// simctl lists (the catalog counts the whole device set as one path); otherwise the counted catalog items.
    public let itemCount: Int
    /// The command has no preview of its own: it applies (or downloads) the moment it is run.
    public let actsImmediately: Bool
    /// The caveats the user needs before running the command, in the order to read them (spec §5: the order to run
    /// them in). Stable English ids: `archivesPark`, `derivedDataExternal`, `simctlDelete`, `exportFirst`, `runtimeSizes`, `rootOnly`.
    public let noteIDs: [String]

    /// The command names a single item, so a row of several items is several commands.
    public var isPerItem: Bool { command.contains("<udid>") || command.contains("<identifier>") }
}

public enum SavingsPlanner {
    /// One row per category offering `bucket`. Counts the same items as `SavingsCalculator` (exists, not a symlink, on
    /// the boot volume, not a breakdown). A row with nothing to reclaim is not listed, except for an option that only
    /// redirects new data, which does not need existing data (listed with 0 bytes).
    ///
    /// Ordered safest first (final S3 review): verified previews, then experimental previews, then rows that act
    /// immediately or lose the user's data; largest first within a group, ties by name.
    public static func rows(report: ScanReport, bucket: SavingsBucket) -> [SavingsPlanRow] {
        var bytesByCategory: [String: UInt64] = [:]
        var itemsByCategory: [String: Int] = [:]
        var lowerBound: Set<String> = []
        for (item, c) in SavingsCalculator.countedItems(report.items, category: StorageCatalog.category) {
            bytesByCategory[c.id, default: 0] += item.allocatedBytes
            itemsByCategory[c.id, default: 0] += 1
            if item.usage?.isLowerBound == true { lowerBound.insert(c.id) }
        }
        var rows: [SavingsPlanRow] = []
        for c in StorageCatalog.all {
            guard let option = c.savingsOptionDetails.first(where: { $0.bucket == bucket }), let command = command(categoryID: c.id, bucket: bucket) else {
                continue
            }
            let bytes = option.appliesToExistingData ? (bytesByCategory[c.id] ?? 0) : 0
            // An unreadable item measures 0 because nothing could be read: unknown, not empty, so its row stays.
            guard bytes > 0 || !option.appliesToExistingData || lowerBound.contains(c.id) else { continue }
            rows.append(
                SavingsPlanRow(
                    categoryID: c.id, categoryName: c.name, bytes: bytes, option: option, command: command,
                    itemCount: itemCount(categoryID: c.id, report: report, counted: itemsByCategory[c.id] ?? 0),
                    actsImmediately: actsImmediately(categoryID: c.id, bucket: bucket), noteIDs: noteIDs(category: c, bucket: bucket)))
        }
        func group(_ r: SavingsPlanRow) -> Int {
            if r.actsImmediately || r.option.losesUserData || r.noteIDs.contains("rootOnly") { return 2 }
            return r.option.isExperimental ? 1 : 0
        }
        return rows.sorted { a, b in
            if group(a) != group(b) { return group(a) < group(b) }
            return a.bytes != b.bytes ? a.bytes > b.bytes : a.categoryName < b.categoryName
        }
    }

    /// The command for a (category, bucket) pair; nil when the pair is not offered. Only the preview form of each
    /// command is ever listed (no `--apply`, `--yes` ...), so the command's own dry run or confirmation speaks at
    /// the moment of decision. Every `xcodevaultctl` spelling is parsed by the CLI itself in `PlanCommandParseTests`.
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
        case (.runFromExternal, "runtimeLibrary"): return "xcodevaultctl runtime export <platform> --to <dir> --preflight"
        default: return nil
        }
    }

    /// Devices for the `simctl delete <udid>` row, runtimes for the two `<identifier>` rows (controller ruling, S3 review).
    static func itemCount(categoryID: String, report: ScanReport, counted: Int) -> Int {
        switch categoryID {
        case "simulatorDevices": report.devices.count
        case "simulatorRuntimeAssets": report.runtimes.count
        default: counted
        }
    }

    /// Commands with no preview of their own: they apply the moment they are run.
    static func actsImmediately(categoryID: String, bucket: SavingsBucket) -> Bool {
        switch (bucket, categoryID) {
        case (.deleteAndRegenerate, "simulatorDevices"), (.runFromExternal, "derivedData"), (.runFromExternal, "archives"): true
        default: false
        }
    }

    /// The caveats for a row, as ids, in reading order. `rootOnly`: `clean` lists a root-only category for accounting and
    /// never deletes it (CleanPlanner), so the row says what would (migration-safety review F1). Only for the `clean`
    /// rows: the runtime row is root-owned too, but `runtime delete` goes through simctl, which does delete it.
    static func noteIDs(category c: StorageCategory, bucket: SavingsBucket) -> [String] {
        if bucket == .deleteAndRegenerate && c.privilege == .root && command(categoryID: c.id, bucket: bucket)?.hasPrefix("xcodevaultctl clean ") == true {
            return ["rootOnly"]
        }
        return switch (bucket, c.id) {
        case (.parkExternally, "archives"): ["archivesPark"]
        case (.runFromExternal, "derivedData"): ["derivedDataExternal"]
        case (.deleteAndRegenerate, "simulatorDevices"): ["simctlDelete"]
        case (.parkExternally, "simulatorRuntimeAssets"): ["exportFirst", "runtimeSizes"]
        case (.deleteAndRegenerate, "simulatorRuntimeAssets"): ["runtimeSizes"]
        default: []
        }
    }

    /// A note's text in the chosen language; nil for an id this build does not know.
    static func noteText(_ id: String) -> String? {
        switch id {
        case "archivesPark": L10n.tr("cli.plan.note.archivesPark")
        case "derivedDataExternal": L10n.tr("cli.plan.note.derivedDataExternal")
        case "simctlDelete": L10n.tr("cli.plan.note.simctlDelete")
        case "exportFirst": L10n.tr("cli.plan.note.exportFirst")
        case "runtimeSizes": L10n.tr("cli.plan.note.runtimeSizes")
        case "rootOnly": L10n.tr("cli.plan.note.rootOnly")
        default: nil
        }
    }

    /// The plan as text, in the chosen language: the bucket's title, promise and undo cost, then one entry per row.
    public static func render(rows: [SavingsPlanRow], bucket: SavingsBucket) -> String {
        var o = "\(bucket.localizedTitle)\n\(bucket.localizedPromise)\n\(bucket.localizedUndoCost)\n\n"
        guard !rows.isEmpty else { return o + L10n.tr("cli.plan.empty") + "\n" }
        for r in rows {
            // The same markers and notes the app shows (`SavingsMarker.markers(for:)`, `localizedNotes`).
            let markers = SavingsMarker.markers(for: r).map(\.localizedText)
            let size = r.option.appliesToExistingData ? "  " + ByteCount.format(r.bytes) : ""
            o += "  \(r.categoryName)\(size)" + (markers.isEmpty ? "" : "  (" + markers.joined(separator: ", ") + ")") + "\n      \(r.command)\n"
            for note in r.localizedNotes { o += "      \(note)\n" }
        }
        return o
    }
}
