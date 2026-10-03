import AppKit
import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Items shaped like a developer Mac for the bucket views: every bucket has rows, some experimental, simulator devices
/// in Delete, Archives present (so a view that listed them for deletion would show it). Never measured: paths are fixtures.
func bucketSampleItems() -> [StorageItem] {
    func item(_ id: String, _ bytes: UInt64) -> StorageItem {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        return StorageItem(
            categoryID: id, path: "/Users/tester/fixture/\(id)", exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false, usage: usage,
            volumeMountPoint: nil, onBootVolume: true)
    }
    let gb: UInt64 = 1_000_000_000
    return [
        item("derivedData", 31 * gb), item("archives", 18 * gb), item("deviceSupport", 9 * gb), item("simulatorDevices", 6 * gb),
        item("simulatorRuntimeAssets", 7 * gb), item("runtimeLibrary", 4 * gb), item("xcodeCaches", 2 * gb),
    ]
}

func bucketSampleDevices() -> [SimulatorDevice] {
    ["A", "B", "C"].map { SimulatorDevice(udid: $0, name: "iPhone", runtimeIdentifier: "r", state: "Shutdown", isAvailable: true) }
}

/// A clean plan over `bucketSampleItems()`, as the planner would make it, with the dyld cache's root row.
func bucketSampleActions() -> [CleanAction] {
    func action(_ id: String, _ bytes: UInt64, _ path: String, root: Bool = false) -> CleanAction {
        CleanAction(
            categoryID: id, categoryName: StorageCatalog.category(id)?.name ?? id, path: path, bytes: bytes, isExperimental: true, risk: .low,
            requiresRoot: root, notes: [])
    }
    let gb: UInt64 = 1_000_000_000
    return [
        action("derivedData", 20 * gb, "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc"),
        action("derivedData", 11 * gb, "/Users/tester/Library/Developer/Xcode/DerivedData/Lib-def"),
        action("deviceSupport", 9 * gb, "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/18.6 (22G86)"),
        action("coreSimulatorSystemCaches", 5 * gb, PrivilegeRequirement.coreSimulatorDyldCachePath, root: true),
        action("xcodeCaches", 2 * gb, "/Users/tester/Library/Caches/com.apple.dt.Xcode"),
    ]
}

func bucketSampleSurvey(checks: [VaultVolumeCheck] = []) -> AppModel.Survey {
    sampleSurvey(
        actions: bucketSampleActions(), savings: sampleSavings(), items: bucketSampleItems(), devices: bucketSampleDevices(), checks: checks)
}

/// `AppModel`'s part of the bucket views (S4 Task 4), through `AppEnvironment` fakes.
@MainActor
final class BucketViewAppTests: XCTestCase {
    func testCopyCommandPutsExactlyTheRowsCommandOnThePasteboard() async {
        let t = TempDir()
        let copied = CopiedStrings()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: bucketSampleSurvey(), copied: copied)
        await model.refresh()
        let rows = model.rows(for: .parkExternally) + model.rows(for: .runFromExternal) + (model.deleteList?.otherTools ?? [])
        XCTAssertGreaterThan(rows.count, 3)
        for row in rows { model.copyCommand(row) }
        XCTAssertEqual(copied.strings, rows.map(\.command))
    }

    func testParkAndRunRowsAreThePlannersRowsInItsOrder() async {
        let t = TempDir()
        let survey = bucketSampleSurvey()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: survey)
        XCTAssertEqual(model.rows(for: .parkExternally), [], "nothing before the first scan")
        await model.refresh()
        for bucket in [SavingsBucket.parkExternally, .runFromExternal] {
            let planned = SavingsPlanner.rows(report: survey.0, bucket: bucket)
            XCTAssertFalse(planned.isEmpty, "\(bucket)")
            XCTAssertEqual(model.rows(for: bucket), planned)
            XCTAssertEqual(model.rows(for: bucket).map(\.command), planned.map(\.command))
        }
    }

    /// The model's Delete list is Core's, from the scan's clean plan: Archives (present in the scan) never in it.
    func testTheDeleteListIsCoresAndNeverListsArchives() async {
        let t = TempDir()
        let survey = bucketSampleSurvey()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: survey)
        await model.refresh()
        let list = model.deleteList
        XCTAssertNotNil(list)
        XCTAssertEqual(list, DeleteList.make(plan: survey.3, report: survey.0))
        XCTAssertTrue(survey.0.items.contains { $0.categoryID == "archives" })
        XCTAssertFalse(list?.groups.contains { $0.categoryID == "archives" } ?? true)
        XCTAssertFalse(list?.otherTools.contains { $0.categoryID == "archives" } ?? true)
        XCTAssertEqual(list?.otherTools.first { $0.categoryID == "simulatorDevices" }?.option.losesUserData, true)
    }

    func testTheVaultStatusFollowsTheChecks() async {
        let t = TempDir()
        let none = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: bucketSampleSurvey())
        await none.refresh()
        XCTAssertEqual(none.vaultStatus, .noVault)
        let v = VaultVolume(volumeUUID: "U", volumeName: "Drive", lastMountPoint: "/Volumes/Drive", registeredAt: Date(), sentinelID: "s")
        let offline = makeModel(
            SwitchableHelper(.notInstalled), journal: t,
            survey: bucketSampleSurvey(checks: [VaultVolumeCheck(volume: v, state: .absent, currentMountPoint: nil, shadowBytes: nil, detail: "")]))
        await offline.refresh()
        XCTAssertEqual(offline.vaultStatus, .offline)
        let ready = makeModel(
            SwitchableHelper(.notInstalled), journal: t,
            survey: bucketSampleSurvey(checks: [
                VaultVolumeCheck(volume: v, state: .verified, currentMountPoint: "/Volumes/Drive", shadowBytes: nil, detail: "")
            ]))
        await ready.refresh()
        XCTAssertEqual(ready.vaultStatus, .ready(volumeName: "Drive"))
    }

    /// One status symbol per state, each a real SF Symbol: a state is told by symbol and word, never by color (S4 Task 5).
    func testEveryAccessStateHasItsOwnSymbol() {
        let states: [AccessChecklist.State] = [.granted, .missing, .awaitingApproval, .unknown, .unavailableInThisBuild]
        let symbols = states.map(AccessRowView.symbol)
        XCTAssertEqual(Set(symbols).count, states.count)
        for symbol in symbols { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol) }
    }
}
