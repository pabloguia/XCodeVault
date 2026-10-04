import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R7-A: the fixes from the user's real-window check of R6 (2026-10-04), the app's part (`AppModel`, the views' words and
/// fit), through `AppEnvironment` fakes: nothing scans this Mac, touches a disk, a journal or a vault, or opens a window.
@MainActor
final class R7AAppTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func model(
        drives: ScriptedDrives? = nil, ops: OperationServices = .inert, checks: [VaultVolumeCheck] = [R6DriveTests.vaultCheck()],
        copied: CopiedStrings = CopiedStrings()
    ) -> AppModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r7a-\(UUID().uuidString).jsonl")
        let survey = bucketSampleSurvey(checks: checks)
        var env = AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { copied.strings.append($0) }, operations: ops)
        if let drives { env.drives = drives.services }
        return AppModel(environment: env)
    }

    private func assessment(_ m: AppModel, _ id: String) throws -> DriveAssessment {
        try XCTUnwrap(m.driveAssessments.first { $0.disk.id == id })
    }

    // MARK: 2. Run Externally

    func testEachDirRowSuggestsTheVaultsFolderAndCopyCopiesIt() async throws {
        let copied = CopiedStrings()
        let m = model(copied: copied)
        await m.refresh()
        let rows = m.rows(for: .runFromExternal)
        let dd = try XCTUnwrap(rows.first { $0.categoryID == "derivedData" })
        XCTAssertEqual(
            m.commandSuggestion(dd),
            .filled(
                command: "xcodevaultctl locations set-derived-data /Volumes/Vault/XCodeVault/DerivedData", folder: "/Volumes/Vault/XCodeVault/DerivedData"))
        m.copyCommand(dd)
        XCTAssertEqual(copied.strings, ["xcodevaultctl locations set-derived-data /Volumes/Vault/XCodeVault/DerivedData"])
        for row in rows where row.command.contains("<dir>") {
            guard case .filled(let command, _) = m.commandSuggestion(row) else { return XCTFail(row.categoryID) }
            XCTAssertFalse(command.contains("<dir>"), row.categoryID)
        }
    }

    func testWithNoUsableVaultTheRowPointsToDrivesAndCopyCopiesTheTemplate() async throws {
        let copied = CopiedStrings()
        let m = model(checks: [R6DriveTests.vaultCheck(state: .absent, mount: nil)], copied: copied)
        await m.refresh()
        let dd = try XCTUnwrap(m.rows(for: .runFromExternal).first { $0.categoryID == "derivedData" })
        XCTAssertEqual(m.commandSuggestion(dd), .noVault)
        m.copyCommand(dd)
        XCTAssertEqual(copied.strings, [dd.command])
        let archive = try XCTUnwrap(m.rows(for: .parkExternally).first { $0.categoryID == "archives" })
        XCTAssertEqual(m.commandSuggestion(archive), .none, "a command without <dir> suggests nothing")
    }

    // MARK: 3. The Run sheet's destination

    func testAReadyVaultIsOnlyInThePickerAndItsFixSitsBesideIt() async throws {
        let pablo = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(301), mount: "/Volumes/Media")
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [R6DriveTests.vaultCheck(), pablo])
        await m.refresh()
        XCTAssertFalse(m.destinationDrives.contains { $0.verdict == .ready }, "the verdict is said once, in the picker")
        let derivedData = SavingsPlanRow(
            categoryID: "derivedData", categoryName: "DerivedData", bytes: 1,
            option: SavingsOption(bucket: .runFromExternal, isExperimental: true, appliesToExistingData: false, losesUserData: false),
            command: "xcodevaultctl locations set-derived-data <dir>", itemCount: 1, actsImmediately: true, noteIDs: [])
        m.openRun(derivedData)
        XCTAssertNil(m.destinationFix, "two vaults: none chosen, no fix shown")
        m.chooseDestination(vaultUUID: R6DriveTests.u(1101))
        XCTAssertNil(m.destinationFix, "a vault with nothing to fix: no button")
        m.chooseDestination(vaultUUID: R6DriveTests.u(301))
        let fix = try XCTUnwrap(m.destinationFix)
        XCTAssertEqual(fix.disk.id, "disk2")
        XCTAssertEqual(DriveText.prepareTitle(fix.prepareAction), "Add a Case-insensitive Volume…", "it says what it does")
        m.prepareFromDestination(fix)
        XCTAssertEqual(m.operationSheet?.kind, .addVolume)
    }

    func testTheFolderIsShownOnceAndOtherDestinationsStillSayTo() {
        var s = OperationSheetState(row: nil, kind: .setDerivedData, inputs: OperationInputs())
        s.inputs.folder = "/Volumes/PABLO/XCodeVault/DerivedData"
        XCTAssertFalse(s.showsDestinationFact(OperationPreview(destination: "/Volumes/PABLO/XCodeVault/DerivedData")), "the Folder row says it")
        XCTAssertTrue(s.showsDestinationFact(OperationPreview(destination: "/Volumes/PABLO/elsewhere")))
        XCTAssertFalse(s.showsDestinationFact(OperationPreview()))
        let archive = OperationSheetState(row: nil, kind: .externalizeArchives, inputs: OperationInputs())
        XCTAssertTrue(archive.showsDestinationFact(OperationPreview(destination: "/Volumes/PABLO/XCodeVault/archives")))
    }

    func testEveryButtonTitleSaysWhatItDoes() {
        XCTAssertEqual(DriveText.prepareTitle(.useDrive), "Use This Drive…")
        XCTAssertEqual(DriveText.prepareTitle(.prepare(.addVolume(container: "d"))), "Add a Case-insensitive Volume…")
        XCTAssertEqual(DriveText.prepareTitle(.prepare(.addPartition(after: "d", freeBytes: 1))), "Add a Case-insensitive Partition…")
        XCTAssertEqual(DriveText.prepareTitle(.prepare(.eraseVolume(volume: "d", name: "n"))), "Erase “n”…")
        XCTAssertEqual(DriveText.prepareTitle(.prepare(.eraseDisk(disk: "d"))), "Erase the Disk…")
        XCTAssertNil(DriveText.prepareTitle(.prepare(.enableOwnership(mountPoint: "/m"))), "runs nothing: Drives explains it")
        XCTAssertNil(DriveText.prepareTitle(.nothing))
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for action: DriveAssessment.PrepareAction in [.useDrive, .prepare(.addVolume(container: "d")), .prepare(.eraseDisk(disk: "d"))] {
                XCTAssertFalse(DriveText.prepareTitle(action)?.hasPrefix("app.") ?? true, "\(action) in \(locale)")
            }
        }
    }

    // MARK: 5. The add-volume sheet

    func testTheAddVolumeSheetSaysWhereTheVolumeWillAppear() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
        await eventually("the review") { m.pendingDiskPlan != nil }
        XCTAssertEqual(m.newVolumeMountPreview?.mountPoint, "/Volumes/XCodeVault")
        XCTAssertEqual(m.newVolumeMountPreview?.isTaken, false)
        m.updateVolumeConfiguration { $0.name = "Media" }
        await eventually("re-planned") { m.pendingDiskPlan?.configuration.name == "Media" }
        let taken = try XCTUnwrap(m.newVolumeMountPreview)
        XCTAssertTrue(taken.isTaken, "Media is mounted at /Volumes/Media")
        XCTAssertEqual(taken.actualMountPoint, "/Volumes/Media 1")
        XCTAssertEqual(taken.suggestedName, "Media2")
        m.choosePreparationOption(.eraseDisk(disk: "disk2"))
        await eventually("the erase") { m.pendingDiskPlan?.action == .eraseDisk }
        XCTAssertNil(m.newVolumeMountPreview, "an erase re-mounts what it replaces: no warning that would be wrong")
    }

    // MARK: 6. Use This Drive after adding a volume

    func testAfterAddingAVolumeTheResultOffersUseThisDriveAsItsOwnReview() async throws {
        let rec = PreparedRecorder()
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives, ops: rec.services)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
        await eventually("the review") { m.canConfirmOperation }
        XCTAssertNil(m.madeVolume, "nothing before the run")
        drives.snapshot = try R7ACoreTests.snapshotWithMadeVolume()
        await m.runOperation()
        XCTAssertTrue(m.operationSheet?.isSucceeded ?? false)
        XCTAssertEqual(m.madeVolume?.volume.volumeUUID, R6DriveTests.u(302))
        XCTAssertEqual(rec.runs.count, 1, "the preparation ran; nothing was registered")
        XCTAssertEqual(m.operationSheet?.secondStep, OperationSheetState.SecondStep.none, "nothing chained")
        m.useMadeVolume()
        XCTAssertEqual(m.operationSheet?.kind, .useDrive)
        XCTAssertEqual(m.operationSheet?.phase, .review, "its own review: the user confirms it")
        XCTAssertEqual(m.operationSheet?.inputs.driveVolumeUUID, R6DriveTests.u(302))
        await eventually("the review") { m.operationSheet?.preview != nil }
        XCTAssertEqual(m.operationConfirmTitle, L10n.tr("app.run.confirm.useDrive", "XCodeVault"))
        XCTAssertEqual(rec.runs.count, 1, "still nothing registered")
    }

    func testNoUseThisDriveWhenThePreparationMadeNothingNew() async throws {
        let rec = PreparedRecorder()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: rec.services)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
        await eventually("the review") { m.canConfirmOperation }
        await m.runOperation()
        XCTAssertTrue(m.operationSheet?.isSucceeded ?? false)
        XCTAssertNil(m.madeVolume, "the disks show no new volume: nothing offered")
    }

    // MARK: 1. Labels in full, wrapping

    func testEveryChartLabelIsTheFullName() {
        let bars = SavingsBucket.allCases.map { StorageTable.BucketBar(bucket: $0, bytes: 8_000, rowCount: 1) }
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(StorageBucketChart.chartBars(bars).map(\.label), SavingsBucket.allCases.map(AppText.bucketShortName), locale)
        }
        let simulator = [SimulatorBar(kind: .device, rowID: "D", name: "iPhone SE (3rd generation)", bytes: 4_420_000_000)]
        XCTAssertEqual(SimulatorsChartView.chartBars(simulator).map(\.label), ["iPhone SE (3rd generation)"])
        XCTAssertFalse(SimulatorsChartView.chartBars(simulator).contains { $0.label.contains("…") })
    }

    /// A label longer than the column wraps — the row grows taller — rather than being cut.
    func testALongLabelWrapsRatherThanTruncates() {
        func height(_ label: String) -> CGFloat {
            let list = BarList(
                bars: [ChartBar(id: "a", label: label, bytes: 1_000, color: .teal, accessibilityLabel: label)], isFilteredOut: { _ in false },
                icon: { _ in Image(systemName: "iphone") }, click: { _, _ in })
            return NSHostingController(rootView: list.frame(width: 600)).sizeThatFits(in: NSSize(width: 600, height: 1)).height
        }
        let short = height("iOS 26.5")
        let long = height("Apple Watch Ultra 3 (49 mm) – Speicherplatz für Simulatordaten und Laufzeitumgebungen, vollständig ausgeschrieben")
        let japanese = height("iPhone 17 Pro Max（シミュレータのデータ、ランタイム、およびデバイスサポートファイルをすべて含む）")
        XCTAssertGreaterThan(long, short * 1.5, "the German label wraps onto more lines")
        XCTAssertGreaterThan(japanese, short * 1.5, "the Japanese label wraps onto more lines")
    }
}

/// R7-A PNGs for a visual review (`XCV_SNAPSHOTS=1`, `$TMPDIR/xcv-snapshots/`): the DerivedData review with PABLO's fix
/// beside the picker, the add-volume review with a taken name, and its result offering Use This Drive. Off-screen: no
/// window. Nothing here asserts how they look.
@MainActor
final class R7ASnapshotTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    func testWriteR7ASnapshots() async throws {
        guard SnapshotWriter.isEnabled else { return }
        var written: [String] = []
        let size = NSSize(width: 560, height: OperationSheetView.idealHeight)
        for locale in ["en", "ja"] {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let ops = ScriptedOperations()
            ops.preview = { _, _ in
                OperationPreview(
                    destination: "/Volumes/Media/XCodeVault/DerivedData",
                    warnings: [
                        "DerivedData on an external physical volume: `xcodebuild test` fails to load test bundles there on macOS 26 (E2, reproduced).",
                        "If this volume is disconnected, Xcode's behaviour is not yet verified (E6 pending): run `xcodevaultctl doctor` after reconnecting.",
                    ], prepared: .migration(R3RunInAppTests.plan()), willCreateFolder: "/Volumes/Media/XCodeVault/DerivedData")
            }
            let pablo = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(301), mount: "/Volumes/Media")
            let drives = ScriptedDrives(try R6DriveTests.snapshot())
            var env = makeR3Model(ops, survey: sampleSurvey(checks: [pablo])).environment
            env.drives = drives.services
            let m = AppModel(environment: env)
            await m.refresh()
            m.openRun(r3Row(categoryID: "derivedData", bucket: .runFromExternal))
            await eventually("the review") { m.operationSheet?.preview != nil }
            written.append(try SnapshotWriter.write(OperationSheetView(model: m), name: "r7a-derived-data-review-\(locale)", size: size))

            let rec = PreparedRecorder()
            var prepEnv = env
            prepEnv.operations = rec.services
            let p = AppModel(environment: prepEnv)
            await p.refresh()
            p.openPreparation(try XCTUnwrap(p.driveAssessments.first { $0.disk.id == "disk2" }), option: .addVolume(container: "disk3"))
            await eventually("the add-volume review") { p.pendingDiskPlan != nil }
            p.updateVolumeConfiguration { $0.name = "Media" }
            await eventually("the taken name") { p.newVolumeMountPreview?.isTaken == true && p.pendingDiskPlan?.configuration.name == "Media" }
            written.append(try SnapshotWriter.write(OperationSheetView(model: p), name: "r7a-add-volume-taken-\(locale)", size: size))
            p.updateVolumeConfiguration { $0.name = "XCodeVault" }
            await eventually("re-planned") { p.canConfirmOperation && p.pendingDiskPlan?.configuration.name == "XCodeVault" }
            drives.snapshot = try R7ACoreTests.snapshotWithMadeVolume()
            await p.runOperation()
            written.append(try SnapshotWriter.write(OperationSheetView(model: p), name: "r7a-add-volume-done-\(locale)", size: size))
        }
        print("snapshots:\n" + written.joined(separator: "\n"))
    }
}
