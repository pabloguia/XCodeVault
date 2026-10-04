import Foundation
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Scripted drive services: the snapshot is the fixture's, every read is counted, and the mount observation is a closure
/// the test fires. Nothing reads this Mac's disks; nothing runs diskutil.
final class ScriptedDrives: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: DriveSnapshot?
    private var _reads = 0
    private var _fire: (@MainActor @Sendable () -> Void)?
    init(_ snapshot: DriveSnapshot?) { _snapshot = snapshot }
    var snapshot: DriveSnapshot? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    @MainActor func fire() { lock.withLock { _fire }?() }

    var services: DriveServices {
        DriveServices(
            snapshot: {
                self.lock.withLock {
                    self._reads += 1
                    return self._snapshot
                }
            },
            observe: { changed in
                self.lock.withLock { self._fire = changed }
                return NSObject()
            }, debounce: .milliseconds(30))
    }
}

/// Records exactly what a confirmation would run, and runs nothing.
final class PreparedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [PreparedOperation] = []
    var runs: [PreparedOperation] { lock.withLock { _runs } }
    var services: OperationServices {
        var s = OperationServices.inert
        s.run = { prepared, _, observer in
            self.lock.withLock { self._runs.append(prepared) }
            observer(LogLine(.command, "diskutil (scripted)"))
            if case .diskPreparation(let plan, _) = prepared { return .drivePrepared(plan) }
            throw RuntimeOperationError("scripted: not a drive operation")
        }
        s.chooseFolder = { _ in "/Users/t/Elsewhere" }
        return s
    }
}

@MainActor
final class R6AppModelTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func vault() -> VaultVolumeCheck {
        VaultVolumeCheck(
            volume: VaultVolume(volumeUUID: R6DriveTests.u(1101), volumeName: "Vault", lastMountPoint: "/Volumes/Vault", registeredAt: Date(), sentinelID: "s"),
            state: .verified, currentMountPoint: "/Volumes/Vault", shadowBytes: nil, detail: "")
    }

    private func model(
        drives: ScriptedDrives, ops: OperationServices = .inert, checks: [VaultVolumeCheck]? = nil, copied: CopiedStrings = CopiedStrings()
    ) -> AppModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r6-\(UUID().uuidString).jsonl")
        let survey = sampleSurvey(checks: checks ?? [vault()])
        var env = AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { copied.strings.append($0) }, operations: ops)
        env.drives = drives.services
        return AppModel(environment: env)
    }

    private func row(_ categoryID: String, _ bucket: SavingsBucket) -> SavingsPlanRow {
        SavingsPlanRow(
            categoryID: categoryID, categoryName: categoryID, bytes: 1,
            option: SavingsOption(bucket: bucket, isExperimental: true, appliesToExistingData: true, losesUserData: false),
            command: "xcodevaultctl x", itemCount: 1, actsImmediately: false, noteIDs: [])
    }

    private func assessment(_ m: AppModel, _ id: String) throws -> DriveAssessment {
        try XCTUnwrap(m.driveAssessments.first { $0.disk.id == id })
    }

    // MARK: - Detection

    func testTheInertEnvironmentReadsNoDisks() async {
        let m = AppModel(
            environment: AppEnvironment(
                survey: { sampleSurvey() }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
                approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in }))
        await m.refresh()
        XCTAssertNil(m.driveSnapshot)
        XCTAssertEqual(m.driveAssessments, [])
    }

    func testAScanReadsTheDrivesAndABurstOfMountEventsReadsThemOnce() async throws {
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives)
        m.startObservingDrives()
        m.startObservingDrives()
        await m.refresh()
        XCTAssertEqual(drives.reads, 1)
        XCTAssertEqual(m.driveAssessments.map(\.verdict), [.ready, .canBeUsed, .needsPreparation, .needsPreparation, .cannotBeUsed])
        drives.snapshot?.disks.removeAll { $0.id == "disk6" }
        for _ in 0..<5 { drives.fire() }
        await eventually("one debounced read") { drives.reads == 2 }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(drives.reads, 2, "five events, one read")
        XCTAssertFalse(m.driveAssessments.contains { $0.disk.id == "disk6" }, "the unplugged stick left the list")
    }

    // MARK: - Preparation

    func testAnEraseNeedsTheExactNameAndRunsWithWhatWasTyped() async throws {
        let rec = PreparedRecorder()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: rec.services)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk6"), option: .eraseDisk(disk: "disk6"))
        await eventually("the review") { m.operationSheet?.preview != nil }
        XCTAssertEqual(m.operationSheet?.kind, .eraseDisk)
        XCTAssertTrue(m.operationSheet?.kind.deletesData ?? false, "destructive button, Cancel the default")
        XCTAssertEqual(m.pendingDiskPlan?.arguments, ["eraseDisk", "APFS", "XCodeVault", "GPT", "disk6"])
        XCTAssertEqual(m.pendingDiskPlan?.destroys.map(\.name), ["STICK"])
        XCTAssertFalse(m.canConfirmOperation)
        XCTAssertEqual(m.operationBlockers, [.typeName("USB Flash Disk")])
        await m.runOperation()
        XCTAssertTrue(rec.runs.isEmpty, "nothing runs before the name is typed")
        m.updateConfirmationText("usb flash disk")
        XCTAssertFalse(m.canConfirmOperation, "case matters")
        m.updateConfirmationText("USB Flash Disk")
        XCTAssertTrue(m.canConfirmOperation)
        await m.runOperation()
        XCTAssertEqual(rec.runs.count, 1)
        guard case .diskPreparation(let plan, let typed)? = rec.runs.first else { return XCTFail("\(rec.runs)") }
        XCTAssertEqual(typed, "USB Flash Disk", "Core gets the typed name and checks it again")
        XCTAssertEqual(plan.action, .eraseDisk)
        XCTAssertTrue(m.operationSheet?.isSucceeded ?? false)
        XCTAssertEqual(m.operationSheet?.secondStep, OperationSheetState.SecondStep.none, "nothing is chained after an erase")
    }

    func testChangingTheOptionPlansAgainAndForgetsTheTypedName() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"))
        await eventually("the review") { m.operationSheet?.preview != nil }
        XCTAssertEqual(m.operationSheet?.kind, .addVolume, "the least destructive option first")
        XCTAssertTrue(m.canConfirmOperation, "adding a volume erases nothing: no name to type")
        XCTAssertEqual(m.preparationChoices.count, 3)
        m.choosePreparationOption(.eraseVolume(volume: "disk3s1", name: "Media"))
        m.updateConfirmationText("Media")
        m.choosePreparationOption(.eraseDisk(disk: "disk2"))
        await eventually("re-planned") { m.pendingDiskPlan?.action == .eraseDisk }
        XCTAssertEqual(m.operationSheet?.confirmationText, "")
        XCTAssertFalse(m.canConfirmOperation)
    }

    func testTheFormIsCheckedByCore() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
        await eventually("the review") { m.operationSheet?.preview != nil }
        m.updateVolumeConfiguration {
            $0.name = "Dev Vault"
            $0.quotaGigabytes = 200
        }
        await eventually("re-planned") { m.pendingDiskPlan?.configuration.name == "Dev Vault" }
        XCTAssertEqual(m.pendingDiskPlan?.arguments, ["apfs", "addVolume", "disk3", "APFS", "Dev Vault", "-quota", "200g"])
        m.updateVolumeConfiguration { $0.name = "-x" }
        await eventually("refused") { m.operationSheet?.preview?.prepared == nil && m.operationSheet?.preview != nil }
        XCTAssertFalse(m.canConfirmOperation)
    }

    func testAVaultDiskOffersNothingAndADrivesThatWentAwayBlocks() async throws {
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives)
        await m.refresh()
        XCTAssertEqual(try assessment(m, "disk10").options, [])
        m.openPreparation(try assessment(m, "disk6"), option: .eraseVolume(volume: "disk6s1", name: "STICK"))
        await eventually("the review") { m.operationSheet?.preview?.prepared != nil }
        drives.snapshot?.disks.removeAll { $0.id == "disk6" }
        await m.refreshDrives()
        await eventually("blocked") { m.operationBlockers == [.driveGone] }
        XCTAssertFalse(m.canConfirmOperation)
    }

    func testUseThisDrivePlansTheRegistration() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        let a = try assessment(m, "disk2")
        m.openUseDrive(a)
        await eventually("the review") { m.operationSheet?.preview != nil }
        guard case .useDrive(let v)? = m.operationSheet?.preview?.prepared else { return XCTFail("not planned") }
        XCTAssertEqual(v.volumeName, "Media")
        XCTAssertEqual(m.operationSheet?.preview?.destination, "/Volumes/Media/XCodeVault")
        XCTAssertTrue(m.canConfirmOperation)
    }

    func testQuittingNeverStopsADrivePreparation() {
        for kind in [OperationKind.addVolume, .addPartition, .eraseVolume, .eraseDisk, .useDrive] {
            XCTAssertFalse(kind.canBeStopped, "\(kind)")
            XCTAssertEqual(AppModel.quitChoice(running: true, stage: kind.runningStage, kind: kind), .keepRunningOnly(.diskPreparation), "\(kind)")
        }
        XCTAssertEqual(OperationKind.eraseDisk.runningStage, .preparing)
        XCTAssertNil(OperationKind.forOption(.enableOwnership(mountPoint: "/Volumes/X")), "ownership runs nothing")
    }

    func testOwnershipShowsFinderAndCopiesTheSudoCommand() async throws {
        let copied = CopiedStrings()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot(mediaOwners: false)), copied: copied)
        await m.refresh()
        XCTAssertEqual(try assessment(m, "disk2").options.last, .enableOwnership(mountPoint: "/Volumes/Media"))
        m.copyOwnershipCommand("/Volumes/Media")
        XCTAssertEqual(copied.strings, ["sudo diskutil enableOwnership /Volumes/Media"])
    }

    // MARK: - The Run sheet's destination

    func testTheFolderStartsAtTheVaultsStandardFolder() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        for (cat, bucket, folder) in [
            ("derivedData", SavingsBucket.runFromExternal, "/Volumes/Vault/XCodeVault/DerivedData"),
            ("archives", .runFromExternal, "/Volumes/Vault/XCodeVault/Archives"),
            ("runtimeLibrary", .runFromExternal, "/Volumes/Vault/XCodeVault/Runtimes"),
            ("simulatorRuntimeAssets", .parkExternally, "/Volumes/Vault/XCodeVault/Runtimes"),
        ] {
            m.openRun(row(cat, bucket))
            XCTAssertEqual(m.operationSheet?.inputs.folder, folder, cat)
            XCTAssertEqual(m.operationSheet?.inputs.vaultUUID, R6DriveTests.u(1101), cat)
            m.closeOperationSheet()
        }
        m.openRun(row("archives", .parkExternally))
        XCTAssertNil(m.operationSheet?.inputs.folder, "externalize keeps the engine's own path")
        XCTAssertEqual(m.operationSheet?.inputs.vaultUUID, R6DriveTests.u(1101))
        m.closeOperationSheet()
    }

    func testAnotherFolderOverridesAndClearingTheVaultClearsItsFolder() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: PreparedRecorder().services)
        await m.refresh()
        m.openRun(row("derivedData", .runFromExternal))
        await m.chooseOperationFolder()
        XCTAssertEqual(m.operationSheet?.inputs.folder, "/Users/t/Elsewhere")
        XCTAssertEqual(m.operationSheet?.inputs.folderIsCustom, true)
        XCTAssertNil(m.operationSheet?.inputs.vaultUUID)
        m.chooseDestination(vaultUUID: R6DriveTests.u(1101))
        XCTAssertEqual(m.operationSheet?.inputs.folder, "/Volumes/Vault/XCodeVault/DerivedData")
        m.chooseDestination(vaultUUID: nil)
        XCTAssertNil(m.operationSheet?.inputs.folder)
    }

    func testDestinationListsReadyVaultsFirstThenDrivesToPrepare() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        XCTAssertEqual(m.destinationChoices.map(\.verdict), [.ready, .canBeUsed, .needsPreparation, .needsPreparation])
        XCTAssertEqual(m.destinationChoices.map(\.name), ["Vault", "Media", "STICK", "Transfer"])
    }

    func testPrepareFromTheRunSheetComesBackToIt() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        m.openRun(row("derivedData", .runFromExternal))
        let original = m.operationSheet?.id
        m.prepareFromDestination(try assessment(m, "disk6"))
        XCTAssertEqual(m.operationSheet?.kind, .eraseVolume)
        XCTAssertNotNil(m.suspendedOperationSheet)
        m.closeOperationSheet()
        XCTAssertEqual(m.operationSheet?.id, original)
        XCTAssertEqual(m.operationSheet?.kind, .setDerivedData)
        XCTAssertNil(m.suspendedOperationSheet)
        m.prepareFromDestination(try assessment(m, "disk2"))
        XCTAssertEqual(m.operationSheet?.kind, .useDrive, "a drive that can be used as it is is registered, not erased")
    }

    // MARK: - Fit (R1's lesson) and words

    func testThePreparationSheetAndTheDrivesScreenFit() async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
            await m.refresh()
            m.openPreparation(try assessment(m, "disk2"), option: .eraseDisk(disk: "disk2"))
            await eventually("the review") { m.pendingDiskPlan != nil }
            let sheet = NSHostingController(rootView: OperationSheetView(model: m)).sizeThatFits(in: NSSize(width: 560, height: 1)).height
            XCTAssertLessThanOrEqual(sheet, R3SheetFitTests.ceiling, "\(language) erase review")
            m.closeOperationSheet()
            m.section = .drives
            let report = try XCTUnwrap(m.report)
            let screen = NSHostingController(rootView: MainView(model: m).detail(report)).sizeThatFits(in: NSSize(width: 1000, height: 1)).height
            XCTAssertLessThanOrEqual(screen, ScreenFitTests.ceiling, "\(language) Drives with external drives")
        }
    }

    func testEveryDriveWordIsTranslated() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            var words = DriveVerdict.allCases.map(DriveText.verdict) + DiskRefusal.allCases.map(DriveText.refusal)
            words += [OperationKind.addVolume, .addPartition, .eraseVolume, .eraseDisk, .useDrive].flatMap {
                [OperationText.title($0), OperationText.failedTitle($0)]
            }
            words += [AppModel.blockerText(.driveGone), AppModel.blockerText(.typeName("X")), OperationText.stage(.preparing)]
            for w in words { XCTAssertFalse(w.hasPrefix("app."), "\(w) in \(locale)") }
        }
    }
}

/// R6 PNGs for a visual review (`XCV_SNAPSHOTS=1`, `$TMPDIR/xcv-snapshots/`): the external drive rows and the preparation
/// sheet's erase review, in English and Japanese. Off-screen: no window.
@MainActor
final class R6SnapshotTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    func testWriteDriveSnapshots() async throws {
        guard SnapshotWriter.isEnabled else { return }
        var written: [String] = []
        for locale in ["en", "ja"] {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let drives = ScriptedDrives(try R6DriveTests.snapshot(mediaOwners: false))
            var env = AppEnvironment(
                survey: { sampleSurvey(checks: [R6SnapshotTests.vault()]) }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
                approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in })
            env.drives = drives.services
            let model = AppModel(environment: env)
            await model.refresh()
            let rows = VStack(alignment: .leading, spacing: 16) {
                ForEach(model.driveAssessments) { ExternalDriveRowView(assessment: $0, actions: ExternalDriveActions()) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            written.append(try SnapshotWriter.write(rows, name: "r6-external-drives-\(locale)", size: NSSize(width: 900, height: 720)))
            let disk = try XCTUnwrap(model.driveAssessments.first { $0.disk.id == "disk2" })
            model.openPreparation(disk, option: .eraseDisk(disk: "disk2"))
            await eventually("the review") { model.pendingDiskPlan != nil }
            written.append(try SnapshotWriter.write(OperationSheetView(model: model), name: "r6-erase-review-\(locale)", size: NSSize(width: 560, height: 520)))
            model.closeOperationSheet()
            model.openPreparation(disk, option: .addVolume(container: "disk3"))
            await eventually("the review") { model.pendingDiskPlan?.action == .addVolume }
            written.append(
                try SnapshotWriter.write(OperationSheetView(model: model), name: "r6-add-volume-review-\(locale)", size: NSSize(width: 560, height: 520)))
            model.closeOperationSheet()
        }
        print("snapshots:\n" + written.joined(separator: "\n"))
    }

    nonisolated static func vault() -> VaultVolumeCheck {
        VaultVolumeCheck(
            volume: VaultVolume(volumeUUID: R6DriveTests.u(1101), volumeName: "Vault", lastMountPoint: "/Volumes/Vault", registeredAt: Date(), sentinelID: "s"),
            state: .verified, currentMountPoint: "/Volumes/Vault", shadowBytes: nil, detail: "")
    }
}
