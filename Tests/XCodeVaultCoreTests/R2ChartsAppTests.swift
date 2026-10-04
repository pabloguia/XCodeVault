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
        XCTAssertEqual(model.storageBucketFilter, [bar.bucket])
        XCTAssertTrue(model.storageIsFiltered)
        XCTAssertEqual(model.storageRows(report), all.filter { $0.bucket == bar.bucket })
        XCTAssertEqual(model.storageRows(report).count, bar.rowCount)
        XCTAssertEqual(model.storageBars(report), bars, "the chart keeps every bar while filtered")
        model.clickStorageBar(nil)
        XCTAssertEqual(model.storageBucketFilter, [bar.bucket], "a click outside the bars keeps the filter")
        model.clickStorageBar(bar.id)
        XCTAssertEqual(model.storageBucketFilter, [], "the only bar shown, clicked again, shows every bucket")
        model.clickStorageBar(bars[0].id)
        model.clickStorageBar(bars[1].id, extending: true)
        XCTAssertEqual(model.storageBucketFilter, [bars[0].bucket, bars[1].bucket], "⌘-click adds a bucket")
        XCTAssertEqual(model.storageFilterBuckets, [bars[0].bucket, bars[1].bucket], "in the chart's order")
        model.toggleStorageBucket(bars[0].bucket)
        XCTAssertEqual(model.storageBucketFilter, [bars[1].bucket], "a chip takes one away")
        model.storageQuery = "zzz-nothing"
        XCTAssertEqual(model.storageRows(report), [], "the search combines with the buckets")
        model.clearStorageFilter()
        XCTAssertEqual(model.storageBucketFilter, [], "Show All")
        XCTAssertEqual(model.storageQuery, "", "Show All clears the search too")
        XCTAssertFalse(model.storageIsFiltered)
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

    func testStorageSelectionGivesPathsForShowInFinder() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let row = try XCTUnwrap(model.storageRows(report).first)
        XCTAssertEqual(model.storagePaths([row.id], report: report), [row.item.path], "a row's id is not its path; the paths are")
        XCTAssertEqual(model.storagePaths(["no-such-row"], report: report), [])
    }

    func testClickingASimulatorBarSelectsItsRowAndScrollsToIt() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        XCTAssertNil(model.simulatorScrollTarget(report))
        let bars = SimulatorsChart.bars(report: report)
        let device = try XCTUnwrap(bars.first { $0.kind == .device })
        let runtime = try XCTUnwrap(bars.first { $0.kind == .runtime })
        model.clickSimulatorBar(device.id)
        XCTAssertEqual(model.simulatorSelection, [device.id])
        XCTAssertEqual(model.simulatorScrollTarget(report), device.id)
        XCTAssertEqual(model.simulatorScrollRequests, 1)
        model.simulatorQuery = "zzz-nothing"
        model.clickSimulatorBar(runtime.id)
        XCTAssertEqual(model.simulatorSelection, [runtime.id])
        XCTAssertEqual(model.simulatorQuery, "", "a search that would hide the clicked row is cleared")
        XCTAssertEqual(model.simulatorScrollTarget(report), runtime.id)
        model.clickSimulatorBar(nil)
        XCTAssertEqual(model.simulatorScrollRequests, 2, "a click outside the bars does nothing")
        XCTAssertEqual(model.simulatorSelection, [runtime.id])
        model.clearSimulatorSelection()
        XCTAssertEqual(model.simulatorSelection, [])
        XCTAssertNil(model.simulatorScrollTarget(report))
    }

    /// Review M6: after a rescan, buckets with no bar and rows no longer listed leave the filter and the selections.
    func testARescanClearsAStaleFilterAndSelection() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        let bars = model.storageBars(report)
        let absent = try XCTUnwrap(SavingsBucket.allCases.first { b in !bars.contains { $0.bucket == b } }, "a bucket with no rows")
        model.storageBucketFilter = [absent, bars[0].bucket]
        model.simulatorSelection = ["device:gone"]
        model.storageSelection = ["gone"]
        await model.refresh()
        XCTAssertEqual(model.storageBucketFilter, [bars[0].bucket])
        XCTAssertEqual(model.simulatorSelection, [])
        XCTAssertEqual(model.storageSelection, [])
        let device = try XCTUnwrap(model.simulatorRows(report, kind: .device).first)
        model.simulatorSelection = [device.id]
        await model.refresh()
        XCTAssertEqual(model.simulatorSelection, [device.id])
    }

    func testTheSimulatorTableFollowsItsSortOrder() async throws {
        let (model, _) = await model()
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(model.simulatorRows(report, kind: .runtime), SimulatorsTable.listRows(report: report, kind: .runtime))
        model.simulatorSortOrder = [SimulatorsTable.ListColumn.name.comparator()]
        let platforms = model.simulatorRows(report, kind: .runtime).map { $0.name.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(platforms, ["iOS", "tvOS", "watchOS"])
        model.simulatorSortOrder = [SimulatorsTable.ListColumn.name.comparator(.reverse)]
        XCTAssertEqual(model.simulatorRows(report, kind: .device).map(\.name), ["iPhone 17 Pro", "iPad Air", "Apple Watch"])
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
