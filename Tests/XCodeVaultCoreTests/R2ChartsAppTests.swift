import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R2 in `AppModel`: the Storage filter and sort, the Simulators selection and sort, the Drives bars — over the made-up
/// Details fixture, through `AppEnvironment` fakes. No window, no scan of this Mac.
@MainActor
final class R2ChartsAppTests: XCTestCase {
    private func model(_ survey: AppModel.Survey = detailSampleSurvey()) async -> (AppModel, TempDir) {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        return (model, t)
    }

    func testClickingABarFiltersTheStorageTableAndClickingAgainClearsIt() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let all = model.storageRows(report)
        XCTAssertEqual(all, StorageTable.rows(report: report), "no filter, default sort: Core's order")
        let bars = model.storageBars(report)
        XCTAssertGreaterThanOrEqual(bars.count, 2, "the fixture has rows in several buckets")
        let bar = bars[1]
        model.clickStorageBar(bar.id)
        XCTAssertEqual(model.storageBucketFilter, bar.bucket)
        XCTAssertEqual(model.storageRows(report), all.filter { $0.bucket == bar.bucket })
        XCTAssertEqual(model.storageRows(report).count, bar.rowCount)
        XCTAssertEqual(model.storageBars(report), bars, "the chart keeps every bar while filtered")
        model.clickStorageBar(nil)
        XCTAssertEqual(model.storageBucketFilter, bar.bucket, "a click outside the bars keeps the filter")
        model.clickStorageBar(bar.id)
        XCTAssertNil(model.storageBucketFilter, "the selected bar again clears it")
        model.clickStorageBar(bars[0].id)
        model.clickStorageBar(bars[1].id)
        XCTAssertEqual(model.storageBucketFilter, bars[1].bucket, "another bar moves the filter")
        model.clearStorageFilter()
        XCTAssertNil(model.storageBucketFilter, "the chip's × and All clear it")
        XCTAssertEqual(model.storageRows(report), all)
    }

    func testTheStorageSortOrderReordersTheRows() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        model.storageSortOrder = [StorageTable.Column.path.comparator()]
        let paths = model.storageRows(report).map(\.item.path)
        XCTAssertEqual(paths, paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        model.storageSortOrder = [StorageTable.Column.size.comparator()]
        let sizes = model.storageRows(report).map(\.item.allocatedBytes)
        XCTAssertEqual(sizes, sizes.sorted())
    }

    func testClickingASimulatorBarSelectsItsRowAndScrollsToIt() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        XCTAssertNil(model.simulatorScrollTarget(report))
        let bars = SimulatorsChart.bars(report: report)
        let device = try XCTUnwrap(bars.first { $0.kind == .device })
        let runtime = try XCTUnwrap(bars.first { $0.kind == .runtime })
        model.clickSimulatorBar(device.id)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(deviceID: device.rowID))
        XCTAssertEqual(model.simulatorScrollTarget(report)?.table, .device)
        model.clickSimulatorBar(runtime.id)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(runtimeID: runtime.rowID))
        let target = try XCTUnwrap(model.simulatorScrollTarget(report))
        XCTAssertEqual(target.table, .runtime)
        XCTAssertGreaterThan(target.anchor, 0)
        XCTAssertLessThanOrEqual(target.anchor, 1)
        // A row selected in the table itself scrolls too; one that is not listed does not.
        model.selectDeviceRow("no-such-device")
        XCTAssertNil(model.simulatorScrollTarget(report))
    }

    /// Review I1 and M8: one selection across the two tables, and only a chart click scrolls the page.
    func testATableClickSelectsOneRowAcrossBothTablesAndDoesNotScroll() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let runtime = try XCTUnwrap(model.simulatorRuntimes(report).first), device = try XCTUnwrap(model.simulatorDevices(report).first)
        model.selectRuntimeRow(runtime.id)
        model.selectDeviceRow(device.id)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(deviceID: device.id), "the runtime is no longer selected")
        XCTAssertEqual(model.simulatorScrollTarget(report)?.table, .device)
        model.selectRuntimeRow(nil)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(deviceID: device.id), "the other table deselecting keeps it")
        XCTAssertEqual(model.simulatorScrollRequests, 0, "a click in a table never scrolls the page")
        let bar = try XCTUnwrap(SimulatorsChart.bars(report: report).first { $0.kind == .runtime })
        model.clickSimulatorBar(bar.id)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(runtimeID: bar.rowID))
        XCTAssertEqual(model.simulatorScrollRequests, 1, "a chart click does")
        model.clickSimulatorBar(nil)
        XCTAssertEqual(model.simulatorScrollRequests, 1, "a click outside the bars does not")
    }

    /// Review M5: the bucket menu sets the same filter a bar click does.
    func testTheBucketMenuSetsTheFilter() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let bar = try XCTUnwrap(model.storageBars(report).last)
        model.chooseStorageFilter(bar.bucket)
        XCTAssertEqual(model.storageBucketFilter, bar.bucket)
        XCTAssertEqual(model.storageRows(report).count, bar.rowCount)
        model.chooseStorageFilter(nil)
        XCTAssertNil(model.storageBucketFilter)
    }

    /// Review M6: after a rescan, a filter whose bucket has no bar and a row no longer listed are cleared; valid ones stay.
    func testARescanClearsAStaleFilterAndSelection() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let bars = model.storageBars(report)
        let absent = try XCTUnwrap(SavingsBucket.allCases.first { b in !bars.contains { $0.bucket == b } }, "a bucket with no rows")
        model.chooseStorageFilter(absent)
        model.selectDeviceRow("gone")
        await model.refresh()
        XCTAssertNil(model.storageBucketFilter)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection())
        let device = try XCTUnwrap(model.simulatorDevices(report).first)
        model.chooseStorageFilter(bars[0].bucket)
        model.selectDeviceRow(device.id)
        await model.refresh()
        XCTAssertEqual(model.storageBucketFilter, bars[0].bucket)
        XCTAssertEqual(model.simulatorSelection, SimulatorSelection(deviceID: device.id))
    }

    func testTheSimulatorTablesFollowTheirSortOrders() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(model.simulatorRuntimes(report), SimulatorsTable.runtimes(report: report))
        XCTAssertEqual(model.simulatorDevices(report), SimulatorsTable.devices(report: report))
        model.runtimeSortOrder = [SimulatorsTable.RuntimeColumn.platform.comparator()]
        XCTAssertEqual(model.simulatorRuntimes(report).map(\.platformDisplayName), ["iOS", "tvOS", "watchOS"])
        model.deviceSortOrder = [SimulatorsTable.DeviceColumn.name.comparator(.reverse)]
        XCTAssertEqual(model.simulatorDevices(report).map(\.device.name), ["iPhone 17 Pro", "iPad Air", "Apple Watch"])
    }

    func testEveryMeasuredDriveGetsItsBar() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let list = model.drivesList(report)
        for row in list.rows {
            let bar = try XCTUnwrap(model.driveBar(row, report: report), row.volume.volumeName)
            XCTAssertEqual(bar.segments.last?.kind, .free)
            if !bar.isClamped {
                XCTAssertEqual(bar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, row.volume.totalBytes, row.volume.volumeName)
            }
        }
        XCTAssertNotNil(list.rows.first { $0.vault != nil }, "the fixture's vault has a row and a bar")
    }
}
