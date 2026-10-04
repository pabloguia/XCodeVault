import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// `NavigationHistory` (R1): the history behind the app's **Back**.
final class NavigationHistoryTests: XCTestCase {
    func testMovingRecordsThePlaceLeftAndBackWalksBackwardsWithoutRecording() {
        var h = NavigationHistory<String>()
        XCTAssertFalse(h.canGoBack)
        h.moved(from: "a", to: "b")
        h.moved(from: "b", to: "c")
        XCTAssertEqual(h.places, ["a", "b"])
        XCTAssertEqual(h.back(), "b")
        XCTAssertEqual(h.back(), "a")
        XCTAssertNil(h.back(), "nothing left")
        XCTAssertFalse(h.canGoBack)
    }

    func testMovingToThePlaceShownRecordsNothing() {
        var h = NavigationHistory<String>()
        h.moved(from: "a", to: "a")
        XCTAssertEqual(h.places, [])
    }

    func testTheHistoryKeepsTheNewestPlacesUpToItsLimit() {
        var h = NavigationHistory<Int>(limit: 3)
        for i in 0..<10 { h.moved(from: i, to: i + 1) }
        XCTAssertEqual(h.places, [7, 8, 9])
        XCTAssertEqual(NavigationHistory<Int>(limit: 0).limit, 1, "a limit below one keeps one")
    }
}

/// `AppModel`'s **Back** (R1): every section change is recorded, Review included, and going back records nothing.
@MainActor
final class AppModelBackTests: XCTestCase {
    func testReviewThenBackReturnsToTheOverview() async {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: bucketSampleSurvey())
        await model.refresh()
        XCTAssertFalse(model.canGoBack, "nothing to go back to at launch")
        model.review(.deleteAndRegenerate)
        XCTAssertEqual(model.section, .delete)
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertEqual(model.section, .overview)
        XCTAssertFalse(model.canGoBack, "going back records nothing")
    }

    func testSidebarChangesAreRecordedLikeABrowserAndRepeatsAreNot() {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t)
        model.section = .storage
        model.section = .storage
        model.section = .drives
        model.review(.parkExternally)
        XCTAssertEqual(model.section, .park)
        model.goBack()
        XCTAssertEqual(model.section, .drives)
        model.goBack()
        XCTAssertEqual(model.section, .storage)
        model.goBack()
        XCTAssertEqual(model.section, .overview)
        model.goBack()
        XCTAssertEqual(model.section, .overview, "Back with nothing to go back to changes nothing")
    }

    func testReviewingKeepingChangesNothingAndRecordsNothing() {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t)
        model.review(.keepLocal)
        XCTAssertEqual(model.section, .overview)
        XCTAssertFalse(model.canGoBack)
    }
}

/// `DrivesList` (R1): the boot volume group as one row, a vault as a badge on its own volume's row, a section only for the
/// vaults that are not connected, and warnings folded.
final class DrivesListTests: XCTestCase {
    let gb: UInt64 = 1_000_000_000

    func volume(
        _ node: String, _ name: String, uuid: String?, mount: String?, boot: Bool = false, inside: Bool = true, bus: String = "PCI-Express",
        personality: String = "APFS", free: UInt64 = 100_000_000_000, writable: Bool = true
    ) -> Volume {
        Volume(
            deviceNode: node, volumeName: name, volumeUUID: uuid, mountPoint: mount, filesystemPersonality: personality, filesystemType: "apfs",
            isInternal: inside, isRemovableMedia: !inside, isEjectable: !inside, busProtocol: bus, isSolidState: true, isWritable: writable,
            ownersEnabled: true, totalBytes: 500 * gb, freeBytes: free, isBootVolume: boot)
    }

    func check(_ uuid: String, _ state: VaultVolumeState) -> VaultVolumeCheck {
        let v = VaultVolume(volumeUUID: uuid, volumeName: "Vault \(uuid)", lastMountPoint: "/Volumes/Vault", registeredAt: Date(), sentinelID: "s")
        return VaultVolumeCheck(volume: v, state: state, currentMountPoint: nil, shadowBytes: nil, detail: "d")
    }

    /// The names are deliberately not "Macintosh HD": the group is decided by boot, internal and container, never by name.
    func testTheBootSystemAndDataVolumesAreOneRowShowingTheDataVolume() {
        let system = volume("/dev/disk3s1s1", "Alpha", uuid: "S", mount: "/", boot: true, free: 90 * gb, writable: false)
        let data = volume("/dev/disk3s5", "Alpha - Data", uuid: "D", mount: "/System/Volumes/Data", boot: true, free: 90 * gb)
        let usb = volume("/dev/disk8s1", "Stick", uuid: "U", mount: "/Volumes/Stick", inside: false, bus: "USB")
        let list = DrivesList.make(volumes: [system, usb, data], checks: [])
        XCTAssertEqual(list.rows.count, 2)
        let boot = list.rows[0]
        XCTAssertTrue(boot.isBootGroup)
        XCTAssertEqual(boot.volume, data, "the Data volume's facts and free space")
        XCTAssertEqual(boot.members, [system, data])
        XCTAssertEqual(boot.qualification.blockers.filter { $0.contains("boot") }.count, 1, "the boot blocker once")
        XCTAssertFalse(boot.qualification.blockers.contains("Volume is read-only."), "the System volume's read-only blocker is not the row's")
        XCTAssertEqual(list.rows[1].volume, usb)
        XCTAssertFalse(list.rows[1].isBootGroup)
    }

    func testBootVolumesOnDifferentContainersOrExternalStayApart() {
        let a = volume("/dev/disk3s5", "A", uuid: "A", mount: "/System/Volumes/Data", boot: true)
        let b = volume("/dev/disk7s1", "B", uuid: "B", mount: "/Volumes/B", boot: true)
        let external = volume("/dev/disk3s9", "E", uuid: "E", mount: "/Volumes/E", boot: true, inside: false)
        let list = DrivesList.make(volumes: [a, b, external], checks: [])
        XCTAssertEqual(list.rows.map(\.volume), [a, b, external])
        XCTAssertEqual(list.rows.map(\.isBootGroup), [true, true, false])
        XCTAssertEqual(list.rows[0].members, [a])
    }

    func testAMountedVaultIsABadgeOnItsOwnRowAndOnlyUnconnectedVaultsHaveASection() {
        let drive = volume("/dev/disk5s1", "Drive", uuid: "U", mount: "/Volumes/Drive", inside: false, bus: "USB")
        let odd = volume("/dev/disk6s1", "Odd", uuid: "O", mount: "/Volumes/Odd", inside: false)
        let list = DrivesList.make(volumes: [drive, odd], checks: [check("U", .verified), check("O", .sentinelMissing), check("X", .absent)])
        XCTAssertEqual(list.rows[0].vault?.state, .verified)
        XCTAssertEqual(list.rows[0].vaultSymbolName, "externaldrive.badge.checkmark")
        XCTAssertEqual(list.rows[1].vault?.state, .sentinelMissing)
        XCTAssertEqual(list.rows[1].vaultSymbolName, "externaldrive.badge.exclamationmark")
        XCTAssertEqual(list.offlineVaults.map(\.volume.volumeUUID), ["X"], "a mounted vault never appears a second time")
        XCTAssertFalse(list.hasNoVaults)
    }

    func testNoVaultsAndAVolumeWithoutAUUID() {
        let bare = volume("/dev/disk9s1", "Bare", uuid: nil, mount: "/Volumes/Bare", inside: false)
        let list = DrivesList.make(volumes: [bare], checks: [])
        XCTAssertTrue(list.hasNoVaults)
        XCTAssertEqual(list.offlineVaults, [])
        XCTAssertNil(list.rows[0].vault)
        XCTAssertNil(list.rows[0].vaultSymbolName)
    }

    func testWarningsStartFoldedAndBlockersDoNot() {
        let usb = volume("/dev/disk8s1", "Stick", uuid: "U", mount: "/Volumes/Stick", inside: false, bus: "USB", personality: "Case-sensitive APFS")
        let plain = volume("/dev/disk9s1", "SSD", uuid: "P", mount: "/Volumes/SSD", inside: false, bus: "Thunderbolt")
        let rows = DrivesList.make(volumes: [usb, plain], checks: []).rows
        XCTAssertEqual(rows[0].qualification.warnings.count, 2)
        XCTAssertTrue(rows[0].warningsStartCollapsed)
        XCTAssertEqual(rows[1].qualification.warnings, [])
        XCTAssertFalse(rows[1].warningsStartCollapsed)
    }

    func testTheContainerKeyIsTheWholeDisk() {
        XCTAssertEqual(DrivesList.containerKey("/dev/disk3s5"), "disk3")
        XCTAssertEqual(DrivesList.containerKey("/dev/disk3s1s1"), "disk3", "the sealed system snapshot")
        XCTAssertEqual(DrivesList.containerKey("/dev/disk12s2"), "disk12")
        XCTAssertEqual(DrivesList.containerKey("disk4"), "disk4")
        XCTAssertEqual(DrivesList.containerKey(""), "")
        XCTAssertEqual(DrivesList.containerKey("/dev/other"), "other")
    }

    /// The app reads the same list: `AppModel.drivesList` is `DrivesList.make` over the scan and the vault checks.
    @MainActor
    func testTheModelsDrivesListIsCoresOverTheScan() async throws {
        let t = TempDir()
        let survey = detailSampleSurvey()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: survey)
        await model.refresh()
        let list = model.drivesList(try XCTUnwrap(model.report))
        XCTAssertEqual(list, DrivesList.make(volumes: survey.0.volumes, checks: survey.2))
        XCTAssertEqual(list.rows.count, 2)
        XCTAssertEqual(list.rows[1].vault?.state, .verified, "the sample's vault is a badge on the Drive row")
        XCTAssertEqual(list.offlineVaults, [])
    }
}

/// `DeleteNotes` (R1) and the Simulators tables' heights: what keeps both screens inside the window.
final class ScreenLayoutDecisionTests: XCTestCase {
    func testTheNotesCountEveryNoteAndStartFoldedWhileTheTableHasRows() throws {
        let survey = bucketSampleSurvey()
        var plan = survey.3
        plan.warnings = ["w1", "w2"]
        plan.skipped = ["s1", "s2", "s3"]
        let list = DeleteList.make(plan: plan, report: survey.0)
        XCTAssertFalse(list.groups.isEmpty)
        let root = plan.actions.filter { $0.privilegedAction != nil }.count
        XCTAssertEqual(root, 1, "the sample's dyld cache row")
        let notes = DeleteNotes.make(plan: plan, list: list, hasAccessRow: true)
        XCTAssertEqual(notes.count, 1 + 2 + root + list.otherTools.count + 3)
        XCTAssertFalse(notes.startsExpanded)
        XCTAssertEqual(DeleteNotes.make(plan: plan, list: list, hasAccessRow: false).count, notes.count - 1)
    }

    func testTheNotesStartOpenWhenTheTableIsEmptyAndAreAbsentWhenThereAreNone() {
        let survey = sampleSurvey()
        let empty = CleanPlan(actions: [], skipped: [], warnings: [])
        let list = DeleteList.make(plan: empty, report: survey.0)
        let none = DeleteNotes.make(plan: empty, list: list, hasAccessRow: false)
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(none.startsExpanded, "no panel at all")
        let warned = CleanPlan(actions: [], skipped: [], warnings: ["w"])
        let open = DeleteNotes.make(plan: warned, list: DeleteList.make(plan: warned, report: survey.0), hasAccessRow: false)
        XCTAssertEqual(open.count, 1)
        XCTAssertTrue(open.startsExpanded)
    }

    func testASimulatorsTableIsAsTallAsItsHeaderAndRows() {
        XCTAssertEqual(SimulatorsTable.fittedTableHeight(rowCount: 3), 28 + 3 * 24 + 2)
        XCTAssertEqual(SimulatorsTable.fittedTableHeight(rowCount: 0), SimulatorsTable.fittedTableHeight(rowCount: 1), "at least one row")
        XCTAssertEqual(SimulatorsTable.fittedTableHeight(rowCount: 2, rowHeight: 10, headerHeight: 5), 27)
        XCTAssertLessThan(SimulatorsTable.fittedTableHeight(rowCount: 60), SimulatorsTable.fittedTableHeight(rowCount: 61))
    }

    @MainActor
    func testTheModelsNotesAreCoresOverItsPlanListAndAccessRow() async throws {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: bucketSampleSurvey())
        XCTAssertNil(model.deleteNotes, "nothing before the first scan")
        await model.refresh()
        let plan = try XCTUnwrap(model.cleanPlan), list = try XCTUnwrap(model.deleteList)
        XCTAssertEqual(model.deleteNotes, DeleteNotes.make(plan: plan, list: list, hasAccessRow: model.deleteAccessRow != nil))
    }
}
