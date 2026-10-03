import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

let iOSRuntimeID = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
let watchRuntimeID = "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"

/// The Details screens' fixture (S4 Task 6): the bucket views' scan plus two runtimes, devices with and without a measured
/// data size (one whose runtime is no longer installed), an external drive, a vault, a finding and journal entries. Never
/// measured: every path and size is made up.
func detailSampleSurvey() -> AppModel.Survey {
    let gb: UInt64 = 1_000_000_000
    let drive = VaultVolume(volumeUUID: "U", volumeName: "Drive", lastMountPoint: "/Volumes/Drive", registeredAt: Date(), sentinelID: "s")
    var survey = bucketSampleSurvey(checks: [
        VaultVolumeCheck(volume: drive, state: .verified, currentMountPoint: "/Volumes/Drive", shadowBytes: nil, detail: "Sentinel matches.")
    ])
    survey.0.runtimes = [
        SimulatorRuntime(
            identifier: "R2", runtimeIdentifier: watchRuntimeID, platformIdentifier: "com.apple.platform.watchsimulator", version: "11.5", build: "22T572",
            state: "Ready", sizeBytes: 4 * gb, path: "/Library/Developer/CoreSimulator/Images/R2.dmg"),
        SimulatorRuntime(
            identifier: "R1", runtimeIdentifier: iOSRuntimeID, platformIdentifier: "com.apple.platform.iphonesimulator", version: "26.0", build: "23A343",
            state: "Ready", sizeBytes: 9 * gb, path: "/Library/Developer/CoreSimulator/Images/R1.dmg"),
    ]
    let devices = "/Users/tester/Library/Developer/CoreSimulator/Devices/"
    survey.0.devices = [
        SimulatorDevice(udid: "D3", name: "Apple Watch", runtimeIdentifier: watchRuntimeID, state: "Shutdown", isAvailable: true),
        SimulatorDevice(
            udid: "D2", name: "iPad Air", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-0", state: "Shutdown", isAvailable: false,
            dataPath: devices + "D2/data", dataPathSize: 1 * gb),
        SimulatorDevice(
            udid: "D1", name: "iPhone 17 Pro", runtimeIdentifier: iOSRuntimeID, state: "Booted", isAvailable: true, dataPath: devices + "D1/data",
            dataPathSize: 3 * gb),
    ]
    survey.0.volumes = [
        Volume(
            deviceNode: "/dev/disk3s1", volumeName: "Macintosh HD", volumeUUID: "B", mountPoint: "/", filesystemPersonality: "APFS", filesystemType: "apfs",
            isInternal: true, isRemovableMedia: false, isEjectable: false, busProtocol: "PCI-Express", isSolidState: true, isWritable: true,
            ownersEnabled: true, totalBytes: 500 * gb, freeBytes: 100 * gb, isBootVolume: true),
        Volume(
            deviceNode: "/dev/disk5s1", volumeName: "Drive", volumeUUID: "U", mountPoint: "/Volumes/Drive", filesystemPersonality: "APFS",
            filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true,
            ownersEnabled: false, totalBytes: 1000 * gb, freeBytes: 640 * gb, isBootVolume: false),
    ]
    survey.0.summary.runtimeImageBytes = 13 * gb
    survey.1 = [
        Finding(
            id: "low-free", severity: .warning, title: "Low free space on the internal disk", detail: "100 GB free of 500 GB.", path: nil,
            remediation: "Review the Delete view.", evidence: nil)
    ]
    survey.4 = [
        JournalEntry(
            id: "op2", sequence: 2, timestamp: Date(timeIntervalSince1970: 1_800_000_000), kind: .clean, state: .completed,
            summary: "Moved 2 items to the Trash", paths: [], bytes: nil, detail: [:], toolVersion: "t"),
        JournalEntry(
            id: "op1", sequence: 1, timestamp: Date(timeIntervalSince1970: 1_799_000_000), kind: .clean, state: .completed, summary: "Deleted 1 item",
            paths: [], bytes: nil, detail: [:], toolVersion: "t"),
    ]
    return survey
}

/// The Details screens' rows (`StorageTable`, `SimulatorsTable`), the two Access/Delete decisions moved out of the views
/// (Task 5 review, minors 1 and 2), and the legacy savings numbers kept out of the app.
@MainActor
final class DetailViewsTests: XCTestCase {
    // MARK: - Storage

    func testStorageRowsAreTheExistingItemsLargestFirstEachInItsPrimaryBucket() {
        var items = bucketSampleItems()
        var gone = items[0]
        gone.exists = false
        gone.path = "/Users/tester/fixture/gone"
        items.append(gone)
        var unknown = items[1]
        unknown.categoryID = "notInTheCatalog"
        unknown.path = "/Users/tester/fixture/unknown"
        items.append(unknown)
        let report = sampleSurvey(items: items).0
        let rows = StorageTable.rows(report: report)
        XCTAssertEqual(rows.count, items.count - 1, "an item that does not exist is not listed")
        XCTAssertFalse(rows.contains { $0.item.path.hasSuffix("/gone") })
        XCTAssertEqual(rows.map(\.item.allocatedBytes), rows.map(\.item.allocatedBytes).sorted(by: >))
        for row in rows {
            let category = StorageCatalog.category(row.item.categoryID)
            XCTAssertEqual(row.bucket, category?.primaryBucket, row.item.categoryID)
            XCTAssertEqual(row.categoryName, category?.name ?? row.item.categoryID)
            XCTAssertEqual(row.strategy, category?.recommendedStrategy)
            XCTAssertEqual(row.isExperimental, category?.isExperimental ?? false)
        }
        let unknownRow = rows.first { $0.item.categoryID == "notInTheCatalog" }
        XCTAssertNil(unknownRow?.bucket, "a category the catalog does not know is never put in a bucket by guess")
        XCTAssertEqual(unknownRow?.outcome, "")
        // Rule 5: Archives are never in the Delete bucket, here either.
        XCTAssertNotEqual(rows.first { $0.item.categoryID == "archives" }?.bucket, .deleteAndRegenerate)
        XCTAssertEqual(rows.first { $0.item.categoryID == "derivedData" }?.bucket, StorageCatalog.category("derivedData")?.primaryBucket)
    }

    func testStorageRowsOfEqualSizeKeepAStableOrder() {
        let items = ["/b", "/a", "/c"].map { path -> StorageItem in
            var usage = DiskUsage.zero
            usage.allocatedBytes = 7
            return StorageItem(
                categoryID: "derivedData", path: path, exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false, usage: usage,
                volumeMountPoint: nil, onBootVolume: true)
        }
        XCTAssertEqual(StorageTable.rows(report: sampleSurvey(items: items).0).map(\.item.path), ["/a", "/b", "/c"])
    }

    // MARK: - Simulators

    func testRuntimesAreListedLargestFirst() {
        let report = detailSampleSurvey().0
        XCTAssertEqual(SimulatorsTable.runtimes(report: report).map(\.identifier), ["R1", "R2"])
        XCTAssertEqual(SimulatorsTable.runtimesBytes(report: report), 13_000_000_000)
    }

    func testDevicesCarryTheirSizeAndRuntimeLargestFirstUnmeasuredLast() {
        let report = detailSampleSurvey().0
        let rows = SimulatorsTable.devices(report: report)
        XCTAssertEqual(rows.map(\.device.udid), ["D1", "D2", "D3"])
        XCTAssertEqual(rows.map(\.bytes), [3_000_000_000, 1_000_000_000, nil])
        XCTAssertEqual(rows[0].runtime, "iphone 26.0")
        XCTAssertEqual(rows[2].runtime, "watch 11.5")
        // A device whose runtime is no longer installed shows the identifier it names, never another runtime's name.
        XCTAssertEqual(rows[1].runtime, "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
        XCTAssertEqual(SimulatorsTable.devicesBytes(report: report), 4_000_000_000)
    }

    func testNoRuntimesAndNoDevicesAreEmptyRows() {
        let report = sampleSurvey().0
        XCTAssertEqual(SimulatorsTable.runtimes(report: report), [])
        XCTAssertEqual(SimulatorsTable.devices(report: report), [])
        XCTAssertEqual(SimulatorsTable.devicesBytes(report: report), 0)
    }

    // MARK: - The dyld control's guidance (Task 5 review, minor 1)

    func testTheControlsGuidanceIsLeftOutOnlyWhenTheRowAboveGivesIt() throws {
        let list = DeleteList.make(plan: CleanPlan(actions: bucketSampleActions(), skipped: [], warnings: []), report: bucketSampleSurvey().0)
        let unavailableRow = try XCTUnwrap(AccessChecklist.deleteRow(helper: .unavailableInThisBuild, list: list))
        XCTAssertFalse(AccessChecklist.controlShowsGuidance(helper: .unavailableInThisBuild, besides: unavailableRow))
        XCTAssertTrue(AccessChecklist.controlShowsGuidance(helper: .unavailableInThisBuild, besides: nil), "no row above: the control says it")
        for state in HelperState.allCases where state != .unavailableInThisBuild {
            // Any other state's control is a button, which is never hidden.
            XCTAssertTrue(AccessChecklist.controlShowsGuidance(helper: state, besides: AccessChecklist.deleteRow(helper: state, list: list)), "\(state)")
        }
    }

    func testTheModelHidesTheDeleteControlsGuidanceWhenItsAccessRowShowsIt() async {
        let t = TempDir()
        for state in HelperState.allCases {
            let model = makeModel(SwitchableHelper(state), journal: t, survey: bucketSampleSurvey())
            await model.refresh()
            XCTAssertEqual(model.deleteControlShowsGuidance, state != .unavailableInThisBuild, "\(state)")
            XCTAssertEqual(model.deleteAccessRow == nil, state == .enabled, "\(state)")
            // The action itself is unchanged: in a build without the helper it is never run, whatever is shown.
            XCTAssertEqual(state.actionControl == .notAvailableInThisBuild, state == .unavailableInThisBuild)
        }
        // Without a root row there is no access row above the table, so the control keeps its guidance.
        let none = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: sampleSurvey(actions: []))
        await none.refresh()
        XCTAssertNil(none.deleteAccessRow)
        XCTAssertTrue(none.deleteControlShowsGuidance)
    }

    // MARK: - Uninstall (Task 5 review, minor 2)

    func testUninstallIsOfferedOnlyUnderTheEnabledHelpersRow() async {
        let t = TempDir()
        for state in HelperState.allCases {
            let model = makeModel(SwitchableHelper(state), journal: t, survey: bucketSampleSurvey())
            await model.refresh()
            for row in model.accessRows {
                let expected = row.need == .privilegedHelper && state == .enabled
                XCTAssertEqual(model.offersUninstall(row), expected, "\(state) \(row.need)")
                XCTAssertEqual(AccessChecklist.offersUninstall(row, helper: state), expected)
            }
        }
    }

    // MARK: - Legacy numbers (spec §10)

    /// The app renders `SavingsSummary`, never the legacy `ScanSummary` savings fields: they use the category-level
    /// experimental flag and count the runtime park as verified.
    func testTheAppNeverReferencesTheLegacySavingsFields() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XCodeVault")
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: app.path)).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("Views/OverviewView.swift"), "the scan reaches the views")
        XCTAssertTrue(files.contains("Views/DetailViews.swift"))
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for legacy in ["verifiedSavingsBytes", "estimatedInternalSavingsBytes"] where text.contains(legacy) {
                hits.append("\(file): \(legacy)")
            }
        }
        XCTAssertEqual(hits, [])
        // Control: the fields still exist in Core (`ScanSummary` stays for compatibility), so the scan above can match them.
        let core = try String(
            contentsOf: app.deletingLastPathComponent().appendingPathComponent("XCodeVaultCore/Scan/ScanReport.swift"), encoding: .utf8)
        XCTAssertTrue(core.contains("verifiedSavingsBytes") && core.contains("estimatedInternalSavingsBytes"))
    }
}
