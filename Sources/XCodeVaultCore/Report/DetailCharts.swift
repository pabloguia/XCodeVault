import Foundation

// What the Details screens' charts show, how their tables sort and filter, and what a click on a bar selects (R2),
// decided here so the views only draw it. Nothing here is text: the app renders the labels.

// MARK: - Storage

extension StorageRow {
    /// The bucket column's order: `SavingsBucket`'s, most durable saving first; a row with no bucket last.
    public var bucketSortKey: Int { bucket.flatMap { SavingsBucket.allCases.firstIndex(of: $0) } ?? SavingsBucket.allCases.count }
    /// The strategy column's order: the strategy's identifier; a row with none first.
    public var strategySortKey: String { strategy?.rawValue ?? "" }
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
            let bytes = inBucket.filter(\.countsInBucketTotal).reduce(UInt64(0)) { sum, row in
                let (value, overflow) = sum.addingReportingOverflow(row.item.allocatedBytes)
                return overflow ? .max : value
            }
            return BucketBar(bucket: bucket, bytes: bytes, rowCount: inBucket.count)
        }
    }

    /// The rows the table shows: all of them, or only `bucket`'s when the chart filters it. In `rows(report:)`'s order.
    public static func rows(report: ScanReport, bucket: SavingsBucket?) -> [StorageRow] {
        let all = rows(report: report)
        guard let bucket else { return all }
        return all.filter { $0.bucket == bucket }
    }

    /// The bucket a chart value names; nil for anything else.
    public static func bucket(forBarID id: String?) -> SavingsBucket? { id.flatMap(SavingsBucket.init(rawValue:)) }

    /// The filter after a click: the clicked bucket; no filter when the click is on the bar already selected; unchanged
    /// when the click is outside every bar (nil).
    public static func filter(after current: SavingsBucket?, clicked: SavingsBucket?) -> SavingsBucket? {
        guard let clicked else { return current }
        return clicked == current ? nil : clicked
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

/// What the Simulators screen's tables have selected: at most one row, in one of the two tables.
public struct SimulatorSelection: Sendable, Equatable {
    public var runtimeID: String?
    public var deviceID: String?

    public init(runtimeID: String? = nil, deviceID: String? = nil) {
        self.runtimeID = runtimeID
        self.deviceID = deviceID
    }

    /// The selection a click on the bar `barID` makes: that bar's row, in its table, and nothing in the other. A value
    /// that names no bar (a click outside the bars) keeps the selection as it was.
    public func selecting(barID: String?) -> SimulatorSelection {
        guard let barID, let colon = barID.firstIndex(of: ":"), let kind = SimulatorBar.Kind(rawValue: String(barID[..<colon])) else { return self }
        let rowID = String(barID[barID.index(after: colon)...])
        guard !rowID.isEmpty else { return self }
        return kind == .runtime ? SimulatorSelection(runtimeID: rowID) : SimulatorSelection(deviceID: rowID)
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

    /// Where a table's row sits inside the table, as a fraction of its height, for scrolling the page to it: the row's
    /// middle under `SimulatorsTable.fittedTableHeight`'s header. Nil when the row is not in the table.
    public static func rowAnchor(index: Int?, rowCount: Int, rowHeight: Double = 24, headerHeight: Double = 28) -> Double? {
        guard let index, index >= 0, index < rowCount else { return nil }
        let height = SimulatorsTable.fittedTableHeight(rowCount: rowCount, rowHeight: rowHeight, headerHeight: headerHeight)
        return min(1, (headerHeight + (Double(index) + 0.5) * rowHeight) / height)
    }
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

    public static var defaultRuntimeSortOrder: [KeyPathComparator<SimulatorRuntime>] { [RuntimeColumn.size.comparator(.reverse)] }
    public static var defaultDeviceSortOrder: [KeyPathComparator<SimulatorDeviceRow>] { [DeviceColumn.size.comparator(.reverse)] }

    /// The runtimes by the table's sort order; equal ones by identifier.
    public static func sorted(_ runtimes: [SimulatorRuntime], using order: [KeyPathComparator<SimulatorRuntime>]) -> [SimulatorRuntime] {
        runtimes.sorted(using: order + [KeyPathComparator(\SimulatorRuntime.identifier)])
    }

    /// The devices by the table's sort order; equal ones by UDID.
    public static func sorted(_ devices: [SimulatorDeviceRow], using order: [KeyPathComparator<SimulatorDeviceRow>]) -> [SimulatorDeviceRow] {
        devices.sorted(using: order + [KeyPathComparator(\SimulatorDeviceRow.device.udid)])
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

    /// The bytes by primary bucket of the items on the drive: existing, not a symlink, of a known category that is not a
    /// breakdown — the items the savings model counts, without its boot-volume limit. An item is on the boot group's row
    /// when the scan put it on the boot volume, and on any other row when its volume's mount point is that row's.
    public static func developerBytes(on row: DriveRow, report: ScanReport) -> [SavingsBucket: UInt64] {
        let mountPoints = Set(row.members.compactMap(\.mountPoint))
        var bytes: [SavingsBucket: UInt64] = [:]
        for item in report.items where item.exists && !item.isSymlink {
            let onDrive = row.isBootGroup ? item.onBootVolume : (item.volumeMountPoint.map(mountPoints.contains) ?? false) && !item.onBootVolume
            guard onDrive, let category = report.category(for: item), category.isBreakdownOf == nil else { continue }
            let (value, overflow) = bytes[category.primaryBucket, default: 0].addingReportingOverflow(item.allocatedBytes)
            bytes[category.primaryBucket] = overflow ? .max : value
        }
        return bytes
    }
}
