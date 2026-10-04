import Foundation

// What the Details screens' charts show, how their tables sort and filter, and what a click on a bar selects (R2),
// decided here so the views only draw it. Nothing here is text: the app renders the labels.

// MARK: - Storage

extension StorageRow {
    /// The bucket column's order: `SavingsBucket`'s, most durable saving first; a row with no bucket last.
    public var bucketSortKey: Int { bucket.flatMap { SavingsBucket.allCases.firstIndex(of: $0) } ?? SavingsBucket.allCases.count }
    /// The strategy column's order: by the strategy's identifier, a fixed order whatever the language (the cell shows the
    /// strategy's name in words since R5); the experimental one of two equal identifiers sorts after the plain one, as its
    /// badge follows its name. A row with no strategy first.
    public var strategySortKey: String { (strategy?.rawValue ?? "") + (isExperimental ? " ~" : "") }
}

extension StorageTable {
    /// One bar of the Storage chart: a bucket and the bytes of its rows that `countsInBucketTotal`.
    public struct BucketBar: Sendable, Equatable, Identifiable {
        public let bucket: SavingsBucket
        public let bytes: UInt64
        /// Every row of the bucket, those that count once and those that do not: what the table shows when it is filtered.
        public let rowCount: Int
        /// The bar's value on the chart's category axis; `bucket(forBarID:)` maps it back.
        public var id: String { bucket.rawValue }
    }

    /// One bar per bucket that has rows, in `DiskBar.bucketOrder`. A row with no bucket has no bar.
    public static func bucketBars(rows: [StorageRow]) -> [BucketBar] {
        DiskBar.bucketOrder.compactMap { bucket in
            let inBucket = rows.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { return nil }
            let bytes = inBucket.filter { $0.countedBucket == bucket }.reduce(UInt64(0)) { sum, row in
                let (value, overflow) = sum.addingReportingOverflow(row.item.allocatedBytes)
                return overflow ? .max : value
            }
            return BucketBar(bucket: bucket, bytes: bytes, rowCount: inBucket.count)
        }
    }

    /// The rows the table shows (R5): those in any of `buckets` — every row when the set is empty — whose name or path
    /// contains `query` (`matches`). In `rows(report:)`'s order.
    public static func rows(report: ScanReport, buckets: Set<SavingsBucket>, query: String = "") -> [StorageRow] {
        rows(report: report).filter { row in
            (buckets.isEmpty || row.bucket.map(buckets.contains) == true) && matches(row, query: query)
        }
    }

    /// The search (R5, the user's feedback of 2026-10-04): the category's name or the item's path contains the text,
    /// ignoring case and diacritics, after trimming. An empty search matches every row.
    public static func matches(_ row: StorageRow, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return row.categoryName.localizedStandardContains(text) || row.item.path.localizedStandardContains(text)
    }

    /// Whether anything narrows the table: a bucket chosen or a search typed. The view shows **Show All** and the filter's
    /// summary exactly then.
    public static func isFiltered(buckets: Set<SavingsBucket>, query: String) -> Bool {
        !buckets.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The bucket a chart value names; nil for anything else.
    public static func bucket(forBarID id: String?) -> SavingsBucket? { id.flatMap(SavingsBucket.init(rawValue:)) }

    /// The buckets after a click on the chart (R5): a plain click shows only the clicked bucket, or every bucket when it
    /// was the only one shown; ⌘-click (`extending`) adds the bucket or takes it away, as a legend chip does; a click
    /// outside every bar (nil) changes nothing.
    public static func filter(after current: Set<SavingsBucket>, clicked: SavingsBucket?, extending: Bool) -> Set<SavingsBucket> {
        guard let clicked else { return current }
        if extending { return toggled(current, clicked) }
        return current == [clicked] ? [] : [clicked]
    }

    /// A legend chip's toggle: the bucket added to the filter, or taken out of it.
    public static func toggled(_ current: Set<SavingsBucket>, _ bucket: SavingsBucket) -> Set<SavingsBucket> {
        current.contains(bucket) ? current.subtracting([bucket]) : current.union([bucket])
    }

    /// The filter after a new scan: only the buckets that still have a bar, so the summary never names a bucket no bar or
    /// chip can toggle.
    public static func filter(_ current: Set<SavingsBucket>, validIn bars: [BucketBar]) -> Set<SavingsBucket> {
        current.intersection(bars.map(\.bucket))
    }

    /// The table's sortable columns, and the comparator each one sorts by.
    public enum Column: CaseIterable, Sendable {
        case size, bucket, category, outcome, strategy, path

        public func comparator(_ order: SortOrder = .forward) -> KeyPathComparator<StorageRow> {
            switch self {
            case .size: KeyPathComparator(\StorageRow.item.allocatedBytes, order: order)
            case .bucket: KeyPathComparator(\StorageRow.bucketSortKey, order: order)
            case .category: KeyPathComparator(\StorageRow.categoryName, order: order)
            case .outcome: KeyPathComparator(\StorageRow.outcome, order: order)
            case .strategy: KeyPathComparator(\StorageRow.strategySortKey, order: order)
            case .path: KeyPathComparator(\StorageRow.item.path, order: order)
            }
        }
    }

    /// Largest first, as `rows(report:)` orders them.
    public static var defaultSortOrder: [KeyPathComparator<StorageRow>] { [Column.size.comparator(.reverse)] }

    /// `rows` sorted by the table's sort order; equal rows by path then id, so the order does not change between redraws.
    public static func sorted(_ rows: [StorageRow], using order: [KeyPathComparator<StorageRow>]) -> [StorageRow] {
        rows.sorted(using: order + [KeyPathComparator(\StorageRow.item.path), KeyPathComparator(\StorageRow.id)])
    }
}

// MARK: - Chart clicks

/// Where a click lands on a chart (R2 review M1), decided here so the view only reads the chart's value at it.
public enum ChartHit {
    /// The click's y inside the plot, measured from the plot's top — what `ChartProxy.value(atY:)` takes — or nil when
    /// the click is above or below the plot. Its edges count as inside.
    public static func plotY(clickY: Double, plotMinY: Double, plotMaxY: Double) -> Double? {
        guard plotMinY <= plotMaxY, clickY >= plotMinY, clickY <= plotMaxY else { return nil }
        return clickY - plotMinY
    }
}

// MARK: - Simulators

/// One bar of the Simulators chart: a device's data or a runtime's image, measured.
public struct SimulatorBar: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case runtime, device
    }

    public let kind: Kind
    /// The row the bar stands for: `SimulatorRuntime.id` or `SimulatorDeviceRow.id`.
    public let rowID: String
    /// The runtime's platform and version ("iOS 26.0") or the device's name: simctl's records, never translated.
    public let name: String
    public let bytes: UInt64

    /// The bar's value on the chart's category axis: unique even when two devices share a name.
    public var id: String { kind.rawValue + ":" + rowID }

    /// The SF Symbol shown with the bar's name, so the kind is never told by color alone.
    public var symbolName: String { kind.symbolName }
}

extension SimulatorBar.Kind {
    public var symbolName: String {
        switch self {
        case .runtime: "shippingbox"
        case .device: "iphone"
        }
    }
}

public enum SimulatorsChart {
    /// The measured runtimes and devices, largest first; equal sizes runtimes first, then by name and id. An unmeasured
    /// one has no bar (`unmeasuredCount`), never a zero bar.
    public static func bars(report: ScanReport) -> [SimulatorBar] {
        let runtimes = report.runtimes.compactMap { r in
            r.sizeBytes.map { SimulatorBar(kind: .runtime, rowID: r.id, name: r.chartName, bytes: $0) }
        }
        let devices = SimulatorsTable.devices(report: report).compactMap { d in
            d.bytes.map { SimulatorBar(kind: .device, rowID: d.id, name: d.device.name, bytes: $0) }
        }
        let kinds = SimulatorBar.Kind.allCases
        return (runtimes + devices).sorted { a, b in
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            let (ka, kb) = (kinds.firstIndex(of: a.kind) ?? 0, kinds.firstIndex(of: b.kind) ?? 0)
            if ka != kb { return ka < kb }
            return (a.name, a.rowID) < (b.name, b.rowID)
        }
    }

    /// The runtimes and devices with no size: listed in the tables as "not measured", left out of the chart.
    public static func unmeasuredCount(report: ScanReport) -> Int {
        report.runtimes.filter { $0.sizeBytes == nil }.count + report.devices.filter { $0.dataPathSize == nil }.count
    }

    /// The chart's height in points: one bar's band per bar plus the axis, at least `minimum`. The screen scrolls as a
    /// whole, so a long chart lengthens the page and never asks the window for more height.
    public static func height(barCount: Int, band: Double = 34, axis: Double = 34, minimum: Double = 120) -> Double {
        max(minimum, Double(barCount) * band + axis)
    }

    /// The selection after a click on the chart (R5): the clicked bar's row — a bar's id is its row's id in the one table
    /// (`SimulatorListRow.id`) — and nothing else; a click outside every bar (nil) changes nothing.
    public static func selection(after current: Set<String>, clicked barID: String?) -> Set<String> {
        guard let barID else { return current }
        return [barID]
    }
}

/// One row of the Simulators screen's one table (R5, HIG review SI1): a runtime or a device, under shared columns.
public struct SimulatorListRow: Sendable, Equatable, Identifiable {
    public let kind: SimulatorBar.Kind
    /// `SimulatorRuntime.id` or `SimulatorDeviceRow.id`.
    public let rowID: String
    /// The runtime's platform and version ("iOS 26.0") or the device's name: simctl's records, never translated.
    public let name: String
    /// The runtime's version and build ("26.0 (23A343)"), or the runtime a device runs ("iOS 26.0").
    public let detail: String
    /// simctl's state, nil when it gave none.
    public let state: String?
    /// Whether a runtime's image is mounted; nil for a device, which has none.
    public let isMounted: Bool?
    /// The runtime's image or the device's data folder; nil when simctl gave none.
    public let path: String?
    /// Nil when the scan did not measure it.
    public let bytes: UInt64?

    /// The same id as the row's chart bar (`SimulatorBar.id`), so a click on a bar selects this row.
    public var id: String { kind.rawValue + ":" + rowID }
    public var sizeSortKey: UInt64 { bytes ?? 0 }
    public var stateSortKey: String { state ?? "" }
    public var pathSortKey: String { path ?? "" }
}

extension SimulatorRuntime {
    /// The chart's name for a runtime: its platform and version ("iOS 26.0"), as the devices table names it.
    public var chartName: String { [platformDisplayName, version].compactMap { $0 }.joined(separator: " ") }
    /// The size column's order: unmeasured as 0, so it sorts with the smallest.
    public var sizeSortKey: UInt64 { sizeBytes ?? 0 }
    public var versionSortKey: String { (version ?? "") + " " + (build ?? "") }
    public var stateSortKey: String { state ?? "" }
    public var mountedSortKey: Int { isMounted ? 1 : 0 }
    public var pathSortKey: String { path ?? "" }
}

extension SimulatorDeviceRow {
    /// The size column's order: unmeasured as 0, so it sorts with the smallest.
    public var sizeSortKey: UInt64 { bytes ?? 0 }
    public var pathSortKey: String { device.dataPath ?? "" }
}

extension SimulatorsTable {
    public enum RuntimeColumn: CaseIterable, Sendable {
        case size, platform, version, state, mounted, image

        public func comparator(_ order: SortOrder = .forward) -> KeyPathComparator<SimulatorRuntime> {
            switch self {
            case .size: KeyPathComparator(\SimulatorRuntime.sizeSortKey, order: order)
            case .platform: KeyPathComparator(\SimulatorRuntime.platformDisplayName, order: order)
            case .version: KeyPathComparator(\SimulatorRuntime.versionSortKey, order: order)
            case .state: KeyPathComparator(\SimulatorRuntime.stateSortKey, order: order)
            case .mounted: KeyPathComparator(\SimulatorRuntime.mountedSortKey, order: order)
            case .image: KeyPathComparator(\SimulatorRuntime.pathSortKey, order: order)
            }
        }
    }

    public enum DeviceColumn: CaseIterable, Sendable {
        case size, name, runtime, state, path

        public func comparator(_ order: SortOrder = .forward) -> KeyPathComparator<SimulatorDeviceRow> {
            switch self {
            case .size: KeyPathComparator(\SimulatorDeviceRow.sizeSortKey, order: order)
            case .name: KeyPathComparator(\SimulatorDeviceRow.device.name, order: order)
            case .runtime: KeyPathComparator(\SimulatorDeviceRow.runtime, order: order)
            case .state: KeyPathComparator(\SimulatorDeviceRow.device.state, order: order)
            case .path: KeyPathComparator(\SimulatorDeviceRow.pathSortKey, order: order)
            }
        }
    }

    /// The one table's columns (R5).
    public enum ListColumn: CaseIterable, Sendable {
        case size, name, detail, state, path

        public func comparator(_ order: SortOrder = .forward) -> KeyPathComparator<SimulatorListRow> {
            switch self {
            case .size: KeyPathComparator(\SimulatorListRow.sizeSortKey, order: order)
            case .name: KeyPathComparator(\SimulatorListRow.name, order: order)
            case .detail: KeyPathComparator(\SimulatorListRow.detail, order: order)
            case .state: KeyPathComparator(\SimulatorListRow.stateSortKey, order: order)
            case .path: KeyPathComparator(\SimulatorListRow.pathSortKey, order: order)
            }
        }
    }

    public static var defaultListSortOrder: [KeyPathComparator<SimulatorListRow>] { [ListColumn.size.comparator(.reverse)] }

    /// The rows of one section of the table — the installed runtimes or the devices — whose name, detail or path contains
    /// `query` (ignoring case and diacritics; empty matches all), sorted by `order`, ties by name then id.
    public static func listRows(
        report: ScanReport, kind: SimulatorBar.Kind, query: String = "", using order: [KeyPathComparator<SimulatorListRow>] = defaultListSortOrder
    ) -> [SimulatorListRow] {
        let rows: [SimulatorListRow] =
            switch kind {
            case .runtime:
                runtimes(report: report).map { r in
                    SimulatorListRow(
                        kind: .runtime, rowID: r.id, name: r.chartName,
                        detail: [r.version, r.build.map { "(" + $0 + ")" }].compactMap { $0 }.joined(separator: " "),
                        state: r.state, isMounted: r.isMounted, path: r.path, bytes: r.sizeBytes)
                }
            case .device:
                devices(report: report).map { d in
                    SimulatorListRow(
                        kind: .device, rowID: d.id, name: d.device.name, detail: d.runtime, state: d.device.state, isMounted: nil, path: d.device.dataPath,
                        bytes: d.bytes)
                }
            }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching =
            text.isEmpty
            ? rows
            : rows.filter { row in
                row.name.localizedStandardContains(text) || row.detail.localizedStandardContains(text) || (row.path?.localizedStandardContains(text) ?? false)
            }
        return matching.sorted(using: order + [KeyPathComparator(\SimulatorListRow.name), KeyPathComparator(\SimulatorListRow.id)])
    }

    public static var defaultRuntimeSortOrder: [KeyPathComparator<SimulatorRuntime>] { [RuntimeColumn.size.comparator(.reverse)] }
    public static var defaultDeviceSortOrder: [KeyPathComparator<SimulatorDeviceRow>] { [DeviceColumn.size.comparator(.reverse)] }

    /// The runtimes by the table's sort order; equal ones by platform, version and identifier.
    public static func sorted(_ runtimes: [SimulatorRuntime], using order: [KeyPathComparator<SimulatorRuntime>]) -> [SimulatorRuntime] {
        runtimes.sorted(
            using: order + [
                KeyPathComparator(\SimulatorRuntime.platformName), KeyPathComparator(\SimulatorRuntime.versionSortKey),
                KeyPathComparator(\SimulatorRuntime.identifier),
            ])
    }

    /// The devices by the table's sort order; equal ones by name and UDID.
    public static func sorted(_ devices: [SimulatorDeviceRow], using order: [KeyPathComparator<SimulatorDeviceRow>]) -> [SimulatorDeviceRow] {
        devices.sorted(using: order + [KeyPathComparator(\SimulatorDeviceRow.device.name), KeyPathComparator(\SimulatorDeviceRow.device.udid)])
    }
}

// MARK: - Drives

extension DiskBar {
    /// A drive's bar (R2): other data, the developer data the scan found on it by primary bucket, then free space, out of
    /// the volume's size. Nil when the volume's size was not measured: no bar is drawn rather than a made-up one.
    public static func drive(_ row: DriveRow, report: ScanReport) -> DiskBar? {
        guard row.volume.totalBytes > 0 else { return nil }
        return DiskBar(totalBytes: row.volume.totalBytes, freeBytes: row.volume.freeBytes, bucketBytes: developerBytes(on: row, report: report))
    }

    /// The bytes on the drive by the bucket they count once in (`SavingsCalculator.countedOnceBucket`, the rule the
    /// Storage chart uses). The boot group's row adds the savings model's own filter, `SavingsCalculator.isInternalSaving`,
    /// so its bar matches the Overview's; any other row takes the items whose volume is mounted where the row's is.
    public static func developerBytes(on row: DriveRow, report: ScanReport) -> [SavingsBucket: UInt64] {
        let mountPoints = Set(row.members.compactMap(\.mountPoint))
        var bytes: [SavingsBucket: UInt64] = [:]
        for item in report.items {
            let onDrive =
                row.isBootGroup
                ? SavingsCalculator.isInternalSaving(item)
                : !SavingsCalculator.isInternalSaving(item) && (item.volumeMountPoint.map(mountPoints.contains) ?? false)
            guard onDrive, let bucket = SavingsCalculator.countedOnceBucket(item, category: report.category(for: item)) else { continue }
            let (value, overflow) = bytes[bucket, default: 0].addingReportingOverflow(item.allocatedBytes)
            bytes[bucket] = overflow ? .max : value
        }
        return bytes
    }
}
