import XCTest

@testable import XCodeVaultCore

/// R2 in Core: the Storage chart's bars, its filter and the table's sort; the Simulators chart's bars, the selection a
/// click makes and both tables' sort; the Drives screen's per-drive bar. Made-up reports only: nothing here scans.
final class R2ChartsTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    private func item(_ id: String, _ bytes: UInt64, path: String? = nil, symlink: Bool = false, mount: String? = nil, onBoot: Bool = true)
        -> StorageItem
    {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        return StorageItem(
            categoryID: id, path: path ?? "/fixture/\(id)/\(bytes)", exists: true, isSymlink: symlink, symlinkTarget: nil, isMountPoint: false,
            usage: usage, volumeMountPoint: mount, onBootVolume: onBoot)
    }

    private func report(_ items: [StorageItem]) -> ScanReport {
        var r = Fixtures.minimalReport()
        r.items = items
        return r
    }

    private func bucket(_ id: String) -> SavingsBucket { StorageCatalog.category(id)!.primaryBucket }

    /// Items in at least three buckets, one of them a breakdown and one a symlink, and one of no known category.
    private func storageReport() -> ScanReport {
        report([
            item("derivedData", 5 * gb), item("archives", 7 * gb), item("simulatorDevices", 9 * gb), item("simulatorDeadContainers", 2 * gb),
            item("xcodeCaches", 1 * gb), item("commandLineTools", 3 * gb), item("swiftPMCaches", 4 * gb, symlink: true), item("unknownThing", 6 * gb),
        ])
    }

    // MARK: - Storage chart and filter

    func testTheBucketBarsSumEachBucketsRowsOnceInBarOrder() {
        let rows = StorageTable.rows(report: storageReport())
        let bars = StorageTable.bucketBars(rows: rows)
        XCTAssertGreaterThanOrEqual(Set(bars.map(\.bucket)).count, 3, "the fixture spans several buckets")
        // Only buckets with rows, in the disk bar's order.
        XCTAssertEqual(bars.map(\.bucket), DiskBar.bucketOrder.filter { b in rows.contains { $0.bucket == b } })
        for bar in bars {
            let expected = rows.filter { $0.bucket == bar.bucket && !$0.item.isSymlink && StorageCatalog.category($0.item.categoryID)?.isBreakdownOf == nil }
                .reduce(UInt64(0)) { $0 + $1.item.allocatedBytes }
            XCTAssertEqual(bar.bytes, expected, "\(bar.bucket)")
            XCTAssertEqual(bar.rowCount, rows.filter { $0.bucket == bar.bucket }.count)
            XCTAssertEqual(StorageTable.bucket(forBarID: bar.id), bar.bucket)
        }
        // The breakdown and the symlink are listed but not counted; the unknown category has no bucket and no bar.
        XCTAssertFalse(rows.first { $0.item.categoryID == "simulatorDeadContainers" }!.countsInBucketTotal)
        XCTAssertFalse(rows.first { $0.item.categoryID == "swiftPMCaches" }!.countsInBucketTotal)
        XCTAssertTrue(rows.first { $0.item.categoryID == "derivedData" }!.countsInBucketTotal)
        XCTAssertNil(rows.first { $0.item.categoryID == "unknownThing" }!.bucket)
        XCTAssertEqual(StorageTable.bucketBars(rows: []), [])
    }

    func testFilteringByBucketKeepsOnlyThatBucketsRowsInOrder() {
        let r = storageReport()
        let all = StorageTable.rows(report: r)
        XCTAssertEqual(StorageTable.rows(report: r, bucket: nil), all)
        for b in SavingsBucket.allCases {
            let filtered = StorageTable.rows(report: r, bucket: b)
            XCTAssertEqual(filtered, all.filter { $0.bucket == b })
        }
        XCTAssertFalse(StorageTable.rows(report: r, bucket: bucket("derivedData")).isEmpty)
    }

    func testAClickTogglesTheFilter() {
        let a = SavingsBucket.deleteAndRegenerate, b = SavingsBucket.parkExternally
        XCTAssertEqual(StorageTable.filter(after: nil, clicked: a), a)
        XCTAssertEqual(StorageTable.filter(after: a, clicked: b), b)
        XCTAssertNil(StorageTable.filter(after: a, clicked: a), "the selected bar again clears the filter")
        XCTAssertEqual(StorageTable.filter(after: a, clicked: nil), a, "a click outside the bars changes nothing")
        XCTAssertNil(StorageTable.filter(after: nil, clicked: nil))
        XCTAssertNil(StorageTable.bucket(forBarID: "nonsense"))
        XCTAssertNil(StorageTable.bucket(forBarID: nil))
    }

    func testSortingByEachColumnOrdersTheRows() {
        let rows = StorageTable.rows(report: storageReport())
        for column in StorageTable.Column.allCases {
            for order in [SortOrder.forward, .reverse] {
                let sorted = StorageTable.sorted(rows, using: [column.comparator(order)])
                XCTAssertEqual(Set(sorted.map(\.id)), Set(rows.map(\.id)), "\(column): the same rows")
                let keys: [String] = sorted.map { row in
                    switch column {
                    case .size: String(format: "%020llu", row.item.allocatedBytes)
                    case .bucket: String(row.bucketSortKey)
                    case .category: row.categoryName
                    case .outcome: row.outcome
                    case .strategy: row.strategySortKey
                    case .path: row.item.path
                    }
                }
                for (x, y) in zip(keys, keys.dropFirst()) {
                    let inOrder = order == .forward ? x.localizedStandardCompare(y) != .orderedDescending : x.localizedStandardCompare(y) != .orderedAscending
                    XCTAssertTrue(inOrder, "\(column) \(order): \(x) then \(y)")
                }
            }
        }
        // The default is size, largest first: `rows(report:)`'s own order.
        XCTAssertEqual(StorageTable.sorted(rows, using: StorageTable.defaultSortOrder), rows)
        XCTAssertEqual(StorageTable.sorted(rows, using: [StorageTable.Column.size.comparator()]).first?.item.allocatedBytes, 1 * gb)
        // Equal keys keep a fixed order: by path.
        let ties = StorageTable.sorted(rows, using: [StorageTable.Column.bucket.comparator()])
        XCTAssertEqual(ties, StorageTable.sorted(rows.reversed(), using: [StorageTable.Column.bucket.comparator()]))
    }

    // MARK: - Simulators chart and selection

    private func simulatorsReport() -> ScanReport {
        var r = Fixtures.minimalReport()
        r.runtimes = [
            SimulatorRuntime(
                identifier: "R1", runtimeIdentifier: "rt.ios", platformIdentifier: "com.apple.platform.iphonesimulator", version: "26.0", sizeBytes: 9 * gb),
            SimulatorRuntime(
                identifier: "R2", runtimeIdentifier: "rt.watch", platformIdentifier: "com.apple.platform.watchsimulator", version: "11.5", sizeBytes: 3 * gb),
            SimulatorRuntime(identifier: "R3", runtimeIdentifier: "rt.tv", platformIdentifier: "com.apple.platform.appletvsimulator", version: "26.0"),
        ]
        r.devices = [
            SimulatorDevice(
                udid: "D1", name: "iPhone 17", runtimeIdentifier: "rt.ios", state: "Booted", isAvailable: true, dataPath: "/d/D1", dataPathSize: 3 * gb),
            SimulatorDevice(
                udid: "D2", name: "iPhone 17", runtimeIdentifier: "rt.ios", state: "Shutdown", isAvailable: true, dataPath: "/d/D2", dataPathSize: 1 * gb),
            SimulatorDevice(udid: "D3", name: "Apple Watch", runtimeIdentifier: "rt.watch", state: "Shutdown", isAvailable: true),
        ]
        return r
    }

    func testTheSimulatorBarsAreTheMeasuredOnesLargestFirst() {
        let r = simulatorsReport()
        let bars = SimulatorsChart.bars(report: r)
        XCTAssertEqual(bars.map(\.id), ["runtime:R1", "runtime:R2", "device:D1", "device:D2"], "equal sizes: runtimes first")
        XCTAssertEqual(bars.map(\.name), ["iOS 26.0", "watchOS 11.5", "iPhone 17", "iPhone 17"])
        XCTAssertEqual(Set(bars.map(\.id)).count, bars.count, "two devices with one name keep two bars")
        XCTAssertEqual(SimulatorsChart.unmeasuredCount(report: r), 2, "R3 and D3: in the tables, not in the chart")
        XCTAssertEqual(bars.map(\.symbolName), ["shippingbox", "shippingbox", "iphone", "iphone"])
        XCTAssertEqual(SimulatorsChart.height(barCount: 0), 120)
        XCTAssertEqual(SimulatorsChart.height(barCount: 80), 80 * 34 + 34)
    }

    func testAClickOnABarSelectsItsRowInItsTable() {
        let none = SimulatorSelection()
        XCTAssertEqual(none.selecting(barID: "runtime:R1"), SimulatorSelection(runtimeID: "R1"))
        XCTAssertEqual(none.selecting(barID: "device:D2"), SimulatorSelection(deviceID: "D2"))
        let picked = SimulatorSelection(runtimeID: "R1")
        XCTAssertEqual(picked.selecting(barID: "device:D1"), SimulatorSelection(deviceID: "D1"), "one selection, never one per table")
        XCTAssertEqual(picked.selecting(barID: nil), picked, "outside the bars: unchanged")
        XCTAssertEqual(picked.selecting(barID: "volume:X"), picked)
        XCTAssertEqual(picked.selecting(barID: "device:"), picked)
        XCTAssertEqual(picked.selecting(barID: "device:a:b"), SimulatorSelection(deviceID: "a:b"), "only the first colon separates")
        // Every bar's id selects that bar's row.
        for bar in SimulatorsChart.bars(report: simulatorsReport()) {
            let s = none.selecting(barID: bar.id)
            XCTAssertEqual(bar.kind == .runtime ? s.runtimeID : s.deviceID, bar.rowID)
        }
    }

    func testTheRowAnchorPlacesTheRowInsideItsTable() {
        XCTAssertNil(SimulatorsChart.rowAnchor(index: nil, rowCount: 3))
        XCTAssertNil(SimulatorsChart.rowAnchor(index: 3, rowCount: 3))
        let first = SimulatorsChart.rowAnchor(index: 0, rowCount: 10)!
        let last = SimulatorsChart.rowAnchor(index: 9, rowCount: 10)!
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, last)
        XCTAssertLessThanOrEqual(last, 1)
    }

    func testBothSimulatorTablesSortByEachColumn() {
        let r = simulatorsReport()
        let runtimes = SimulatorsTable.runtimes(report: r)
        XCTAssertEqual(SimulatorsTable.sorted(runtimes, using: SimulatorsTable.defaultRuntimeSortOrder), runtimes, "default: largest first")
        for column in SimulatorsTable.RuntimeColumn.allCases {
            for order in [SortOrder.forward, .reverse] {
                let sorted = SimulatorsTable.sorted(runtimes, using: [column.comparator(order)])
                XCTAssertEqual(Set(sorted.map(\.id)), Set(runtimes.map(\.id)))
                let keys: [String] = sorted.map { rt in
                    switch column {
                    case .size: String(format: "%020llu", rt.sizeSortKey)
                    case .platform: rt.platformDisplayName
                    case .version: rt.versionSortKey
                    case .state: rt.stateSortKey
                    case .mounted: String(rt.mountedSortKey)
                    case .image: rt.pathSortKey
                    }
                }
                // Tied keys are equal strings, so the sorted copy is the same sequence whatever order the ties take.
                let expected = keys.sorted {
                    order == .forward ? $0.localizedStandardCompare($1) == .orderedAscending : $0.localizedStandardCompare($1) == .orderedDescending
                }
                XCTAssertEqual(keys, expected, "\(column) \(order)")
            }
        }
        XCTAssertEqual(
            SimulatorsTable.sorted(runtimes, using: [SimulatorsTable.RuntimeColumn.platform.comparator()]).map(\.platformDisplayName),
            ["iOS", "tvOS", "watchOS"])

        let devices = SimulatorsTable.devices(report: r)
        XCTAssertEqual(SimulatorsTable.sorted(devices, using: SimulatorsTable.defaultDeviceSortOrder), devices, "default: largest first")
        XCTAssertEqual(
            SimulatorsTable.sorted(devices, using: [SimulatorsTable.DeviceColumn.size.comparator()]).map(\.id), ["D3", "D2", "D1"], "unmeasured as smallest")
        XCTAssertEqual(
            SimulatorsTable.sorted(devices, using: [SimulatorsTable.DeviceColumn.name.comparator()]).map(\.id), ["D3", "D1", "D2"], "equal names by UDID")
        XCTAssertEqual(SimulatorsTable.sorted(devices, using: [SimulatorsTable.DeviceColumn.state.comparator(.reverse)]).map(\.id), ["D2", "D3", "D1"])
        XCTAssertEqual(
            SimulatorsTable.sorted(devices, using: [SimulatorsTable.DeviceColumn.runtime.comparator()]).map(\.runtime),
            ["iOS 26.0", "iOS 26.0", "watchOS 11.5"])
        XCTAssertEqual(SimulatorsTable.sorted(devices, using: [SimulatorsTable.DeviceColumn.path.comparator(.reverse)]).map(\.id), ["D2", "D1", "D3"])
    }

    // MARK: - Drives

    private func volume(_ name: String, mount: String, boot: Bool = false, total: UInt64, free: UInt64) -> Volume {
        Volume(
            deviceNode: boot ? "/dev/disk3s5" : "/dev/disk9s1", volumeName: name, volumeUUID: name, mountPoint: mount, filesystemPersonality: "APFS",
            filesystemType: "apfs", isInternal: boot, isRemovableMedia: false, isEjectable: !boot, busProtocol: boot ? "PCI-Express" : "USB",
            isSolidState: true, isWritable: true, ownersEnabled: true, totalBytes: total, freeBytes: free, isBootVolume: boot)
    }

    func testTheGeneralDiskBarMatchesTheOverviewsBar() {
        var host = Fixtures.minimalReport().host
        host.dataVolumeTotalBytes = 500 * gb
        host.dataVolumeFreeBytes = 100 * gb
        let savings = SavingsCalculator.summarize(items: storageReport().items) { StorageCatalog.category($0) }
        let bytes = Dictionary(uniqueKeysWithValues: DiskBar.bucketOrder.map { ($0, savings[$0].primaryBytes) })
        XCTAssertEqual(DiskBar(host: host, savings: savings), DiskBar(totalBytes: 500 * gb, freeBytes: 100 * gb, bucketBytes: bytes))
        let clamped = DiskBar(totalBytes: 10, freeBytes: 8, bucketBytes: [.keepLocal: 5])
        XCTAssertTrue(clamped.isClamped)
        XCTAssertEqual(clamped.segments.map(\.kind), [.bucket(.keepLocal), .free])
    }

    func testEachDrivesBarSplitsItsSizeIntoOtherDeveloperDataAndFree() throws {
        var r = report([
            item("derivedData", 5 * gb), item("simulatorDevices", 9 * gb), item("simulatorDeadContainers", 2 * gb),
            item("archives", 7 * gb, mount: "/Volumes/Drive", onBoot: false), item("xcodeCaches", 1 * gb, mount: "/Volumes/Drive", onBoot: false),
            item("swiftPMCaches", 4 * gb, symlink: true), item("archives", 50 * gb, mount: "/Volumes/Other", onBoot: false),
        ])
        r.volumes = [
            volume("Macintosh HD", mount: "/", boot: true, total: 500 * gb, free: 100 * gb),
            volume("Data", mount: "/System/Volumes/Data", boot: true, total: 500 * gb, free: 100 * gb),
            volume("Drive", mount: "/Volumes/Drive", total: 1000 * gb, free: 600 * gb),
            volume("Unmeasured", mount: "/Volumes/U", total: 0, free: 0),
        ]
        let list = DrivesList.make(volumes: r.volumes, checks: [])
        XCTAssertEqual(list.rows.count, 3)
        let boot = list.rows[0], drive = list.rows[1]
        XCTAssertTrue(boot.isBootGroup)

        // The boot group: the boot volume's items, the breakdown and the symlink left out.
        let bootBytes = DiskBar.developerBytes(on: boot, report: r)
        var expected: [SavingsBucket: UInt64] = [:]
        expected[bucket("derivedData"), default: 0] += 5 * gb
        expected[bucket("simulatorDevices"), default: 0] += 9 * gb
        XCTAssertEqual(bootBytes, expected)
        let bootBar = try XCTUnwrap(DiskBar.drive(boot, report: r))
        XCTAssertEqual(bootBar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, 500 * gb, "the segments fill the volume")
        XCTAssertEqual(bootBar.segments.first?.kind, .otherData)
        XCTAssertEqual(bootBar.segments.last, DiskBar.Segment(kind: .free, bytes: 100 * gb))

        // Another drive: only the items whose volume is mounted where it is.
        var driveExpected: [SavingsBucket: UInt64] = [:]
        driveExpected[bucket("archives"), default: 0] += 7 * gb
        driveExpected[bucket("xcodeCaches"), default: 0] += 1 * gb
        XCTAssertEqual(DiskBar.developerBytes(on: drive, report: r), driveExpected)
        let driveBar = try XCTUnwrap(DiskBar.drive(drive, report: r))
        XCTAssertEqual(driveBar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, 1000 * gb)
        XCTAssertFalse(driveBar.isClamped)

        // A volume whose size was not measured gets no bar rather than a made-up one.
        XCTAssertNil(DiskBar.drive(list.rows[2], report: r))
    }

    func testAVolumesTotalSizeSurvivesTheReportsRoundTrip() throws {
        var r = report([])
        r.volumes = [volume("Drive", mount: "/Volumes/Drive", total: 1000 * gb, free: 600 * gb)]
        let decoded = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.volumes.first?.totalBytes, 1000 * gb)
    }
}
