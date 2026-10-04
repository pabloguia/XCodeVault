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
    /// Reads answered in order, each after its delay, before falling back to `snapshot`: out-of-order completion.
    private var _queue: [(DriveSnapshot?, Double)] = []
    init(_ snapshot: DriveSnapshot?) { _snapshot = snapshot }
    func enqueue(_ snapshot: DriveSnapshot?, after seconds: Double) { lock.withLock { _queue.append((snapshot, seconds)) } }
    var snapshot: DriveSnapshot? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    @MainActor func fire() { lock.withLock { _fire }?() }

    var services: DriveServices {
        DriveServices(
            snapshot: {
                let next: (DriveSnapshot?, Double)? = self.lock.withLock {
                    self._reads += 1
                    return self._queue.isEmpty ? nil : self._queue.removeFirst()
                }
                if let next {
                    Thread.sleep(forTimeInterval: next.1)
                    return next.0
                }
                return self.lock.withLock { self._snapshot }
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
            if case .useDrive = prepared {
                let vault = VaultVolume(volumeUUID: "U", volumeName: "Media", lastMountPoint: "/Volumes/Media", registeredAt: Date(), sentinelID: "s")
                return .driveRegistered(DriveRegistration.Outcome(vault: vault, folders: [], foldersError: "Cannot create /Volumes/Media/XCodeVault/Archives"))
            }
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
        drives: ScriptedDrives, ops: OperationServices = .inert, checks: [VaultVolumeCheck]? = nil, copied: CopiedStrings = CopiedStrings(),
        box: SurveyBox? = nil
    ) -> AppModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r6-\(UUID().uuidString).jsonl")
        let survey = sampleSurvey(checks: checks ?? [vault()])
        var env = AppEnvironment(
            survey: { box?.survey ?? survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
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
        await eventually("blocked") { m.operationBlockers == [.diskChanged] }
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
        for kind in [OperationKind.addVolume, .addPartition, .eraseVolume, .eraseDisk] {
            XCTAssertFalse(kind.canBeStopped, "\(kind)")
            XCTAssertEqual(AppModel.quitChoice(running: true, stage: kind.runningStage, kind: kind), .keepRunningOnly(.diskPreparation), "\(kind)")
        }
        XCTAssertFalse(OperationKind.useDrive.canBeStopped)
        XCTAssertEqual(
            AppModel.quitChoice(running: true, stage: OperationKind.useDrive.runningStage, kind: .useDrive), .keepRunningOnly(.vaultRegistration),
            "Use This Drive runs no diskutil: its own reason (minor 7)")
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
        XCTAssertEqual(m.operationSheet?.kind, .addVolume, "a case-sensitive drive gets the recommended new volume (C1), not a registration")
    }

    // MARK: - Fix round 1

    /// H1: the disk at the same device id, with the same media name, is swapped while the erase review is open.
    func testADiskSwappedUnderTheOpenSheetBlocksItAndRunningRefuses() async throws {
        let rec = PreparedRecorder()
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives, ops: rec.services)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk6"), option: .eraseDisk(disk: "disk6"))
        await eventually("the review") { m.pendingDiskPlan != nil }
        let previewed = try XCTUnwrap(m.operationSheet?.previewedPlan)
        m.updateConfirmationText("USB Flash Disk")
        XCTAssertTrue(m.canConfirmOperation)
        drives.snapshot?.disks = drives.snapshot!.disks.map { d in
            var d = d
            if d.id == "disk6" { d.partitions[0].volumeUUID = R6DriveTests.u(698) }
            return d
        }
        await m.refreshDrives()
        XCTAssertEqual(m.operationBlockers, [.diskChanged])
        XCTAssertEqual(m.operationSheet?.confirmationText, "", "what was typed confirmed the other disk")
        XCTAssertFalse(m.canConfirmOperation)
        m.updateConfirmationText("USB Flash Disk")
        XCTAssertFalse(m.canConfirmOperation, "sticky until the sheet closes")
        await m.runOperation()
        XCTAssertTrue(rec.runs.isEmpty)
        XCTAssertEqual(m.operationSheet?.previewedPlan, previewed, "the previewed plan is never replaced")
        // Swapped back: still blocked — the user closes and previews again.
        drives.snapshot = try R6DriveTests.snapshot()
        await m.refreshDrives()
        XCTAssertEqual(m.operationBlockers, [.diskChanged])
    }

    /// H1: a re-plan with nothing changed keeps the previewed plan and still clears what was typed.
    func testEveryReplanClearsTheTypedNameAndKeepsThePreviewedPlan() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        m.openPreparation(try assessment(m, "disk6"), option: .eraseDisk(disk: "disk6"))
        await eventually("the review") { m.pendingDiskPlan != nil }
        let previewed = m.operationSheet?.previewedPlan
        m.updateConfirmationText("USB Flash Disk")
        await m.refreshDrives()
        XCTAssertEqual(m.operationSheet?.confirmationText, "")
        XCTAssertEqual(m.pendingDiskPlan, previewed)
        XCTAssertEqual(m.operationBlockers, [.typeName("USB Flash Disk")])
    }

    /// Minor 4: a read that finishes after a newer one is dropped.
    func testAnOlderDriveReadNeverOverwritesANewerOne() async throws {
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        var newer = try R6DriveTests.snapshot()
        newer.disks.removeAll { $0.id == "disk6" }
        drives.enqueue(try R6DriveTests.snapshot(), after: 0.3)
        drives.enqueue(newer, after: 0)
        let m = model(drives: drives)
        async let slow: Void = m.refreshDrives()
        try await Task.sleep(for: .milliseconds(50))
        await m.refreshDrives()
        await slow
        XCTAssertEqual(drives.reads, 2)
        XCTAssertFalse(m.driveAssessments.contains { $0.disk.id == "disk6" }, "the slow, older read was dropped")
    }

    /// Minor 5: an open preparation sheet gets the drive as it is now.
    func testARefreshUpdatesTheOpenSheetsDrive() async throws {
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
        await eventually("the review") { m.pendingDiskPlan != nil }
        drives.snapshot?.volumes = drives.snapshot!.volumes.map {
            var v = $0; if v.volumeName == "Media" { v.freeBytes = 1 }; return v
        }
        await m.refreshDrives()
        XCTAssertEqual(m.operationSheet?.drive?.volumes.first?.freeBytes, 1)
    }

    /// Minor 3 and 9: back from Prepare…, the only usable vault is chosen with its standard folder; a vault that goes
    /// away takes its standard folder with it, but not a folder chosen by hand.
    func testTheReturnedRunSheetChoosesTheNewVaultAndAGoneVaultClearsItsFolder() async throws {
        let box = SurveyBox(sampleSurvey(checks: []))
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: PreparedRecorder().services, box: box)
        await m.refresh()
        m.openRun(row("derivedData", .runFromExternal))
        XCTAssertNil(m.operationSheet?.inputs.vaultUUID)
        m.prepareFromDestination(try assessment(m, "disk6"))
        box.survey = sampleSurvey(checks: [vault()])
        await m.refresh()
        m.closeOperationSheet()
        XCTAssertEqual(m.operationSheet?.kind, .setDerivedData)
        XCTAssertEqual(m.operationSheet?.inputs.vaultUUID, R6DriveTests.u(1101))
        XCTAssertEqual(m.operationSheet?.inputs.folder, "/Volumes/Vault/XCodeVault/DerivedData")
        XCTAssertEqual(m.operationSheet?.inputs.standardFolderOf, "/Volumes/Vault/XCodeVault")
        box.survey = sampleSurvey(checks: [])
        await m.refresh()
        XCTAssertNil(m.operationSheet?.inputs.folder)
        XCTAssertNil(m.operationSheet?.inputs.standardFolderOf)
        m.updateOperationInputs {
            $0.folder = "/Users/t/Mine"
            $0.folderIsCustom = true
        }
        box.survey = sampleSurvey(checks: [vault()])
        await m.refresh()
        box.survey = sampleSurvey(checks: [])
        await m.refresh()
        XCTAssertEqual(m.operationSheet?.inputs.folder, "/Users/t/Mine", "a folder chosen by hand stays")
    }

    /// I1: the review of a missing standard folder checks the vault directory and says the folder will be created. A
    /// folder chosen by hand is never substituted or created.
    func testAMissingStandardFolderIsReviewedAndCreatedByTheRun() throws {
        var inputs = OperationInputs(vaultUUID: "U", folder: "/Volumes/Vault/XCodeVault/DerivedData", standardFolderOf: "/Volumes/Vault/XCodeVault")
        let plan = LiveOperations.standardFolderPlan(inputs, exists: { $0 == "/Volumes/Vault/XCodeVault" })
        XCTAssertEqual(plan.inputs.folder, "/Volumes/Vault/XCodeVault")
        XCTAssertEqual(plan.willCreate, "/Volumes/Vault/XCodeVault/DerivedData")
        XCTAssertNil(LiveOperations.standardFolderPlan(inputs, exists: { _ in true }).willCreate, "an existing folder is used as is")
        inputs.folderIsCustom = true
        XCTAssertNil(LiveOperations.standardFolderPlan(inputs, exists: { _ in false }).willCreate, "a folder chosen by hand is never created")
        inputs = OperationInputs(folder: "/Users/t/Mine")
        XCTAssertNil(LiveOperations.standardFolderPlan(inputs, exists: { _ in false }).willCreate)

        let reviewed = OperationPreview(
            destination: "/Volumes/Vault/XCodeVault",
            prepared: .location(XcodeLocations.Change(key: .derivedData, newValue: "/Volumes/Vault/XCodeVault"), acknowledgeTests: true))
        let p = LiveOperations.withNewFolder(
            reviewed, folder: "/Volumes/Vault/XCodeVault/DerivedData", vaultDirectory: "/Volumes/Vault/XCodeVault", vaultUUID: "U")
        XCTAssertEqual(p.willCreateFolder, "/Volumes/Vault/XCodeVault/DerivedData")
        XCTAssertEqual(p.destination, "/Volumes/Vault/XCodeVault/DerivedData")
        guard case .creatingFolder(let folder, let dir, let uuid, .location(let change, _))? = p.prepared else {
            return XCTFail("\(String(describing: p.prepared))")
        }
        XCTAssertEqual(folder, "/Volumes/Vault/XCodeVault/DerivedData")
        XCTAssertEqual(dir, "/Volumes/Vault/XCodeVault")
        XCTAssertEqual(uuid, "U", "the run verifies this vault before the mkdir (N1)")
        XCTAssertEqual(change.newValue, folder, "Xcode is pointed at the folder, not the vault directory")
        XCTAssertEqual(p.prepared?.kind, .setDerivedData)
    }

    /// A scratch vault the folder step verifies: registered, verified at `tmp`, on volume `uuid`. Never a real vault.
    private func world(_ tmp: TempDir, vault: VaultVolume, volume: String? = nil, registered: Bool = true) -> LiveOperations.FolderStepWorld {
        let mountPoint = tmp.path
        return LiveOperations.FolderStepWorld(
            vault: { _ in registered ? vault : nil }, check: { R6DriveTests.verified($0, at: mountPoint) }, volumeUUID: { _ in volume ?? vault.volumeUUID })
    }

    /// Fix round 2, A: the composed review — a missing standard folder is reviewed (against the vault directory, by a
    /// fake Core) and says "Will create folder…", not blocked.
    func testTheComposedPreviewOfAMissingStandardFolderIsNotBlocked() throws {
        let tmp = TempDir()
        let (_, dir) = R6DriveTests.scratchVault(tmp)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let inputs = OperationInputs(vaultUUID: "U", folder: dir + "/DerivedData", standardFolderOf: dir)
        var asked: [String?] = []
        let p = LiveOperations.preview(
            .setDerivedData, inputs, filesystem: { _ in nil },
            core: { kind, i in
                asked.append(i.folder)
                return OperationPreview(
                    destination: i.folder, prepared: .location(XcodeLocations.Change(key: .derivedData, newValue: i.folder), acknowledgeTests: true))
            })
        XCTAssertEqual(asked, [dir], "Core reviewed the vault directory, which exists")
        XCTAssertEqual(p.willCreateFolder, dir + "/DerivedData")
        XCTAssertEqual(p.blockers, [])
        XCTAssertNotNil(p.prepared)
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(L10n.tr("app.run.willCreateFolder", dir + "/DerivedData"), "Will create folder " + dir + "/DerivedData")
        // A folder chosen by hand that is missing goes to Core as is (and Core blocks it).
        var custom = inputs
        custom.folderIsCustom = true
        _ = LiveOperations.preview(
            .setDerivedData, custom, filesystem: { _ in nil },
            core: { _, i in
                asked.append(i.folder)
                return OperationPreview()
            })
        XCTAssertEqual(asked.last, dir + "/DerivedData")
    }

    /// Fix round 2, A and N1: the run creates the folder on the verified vault, then reaches its `then` step; on another
    /// volume it refuses, creates nothing and never reaches `then`.
    func testRunCreatingFolderCreatesThenRunsTheStep() throws {
        let tmp = TempDir()
        let (vault, dir) = R6DriveTests.scratchVault(tmp)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = LineBuffer()
        var reached = 0
        let result = try LiveOperations.runCreatingFolder(
            dir + "/Runtimes", vaultDirectory: dir, vaultUUID: vault.volumeUUID, observer: { log.add($0) }, world: world(tmp, vault: vault)
        ) {
            reached += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/Runtimes"), "the folder exists before the step")
            return .exported
        }
        guard case .exported = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reached, 1)
        XCTAssertEqual(log.drain().first?.text, "mkdir -p " + dir + "/Runtimes")
        for w in [world(tmp, vault: vault, volume: "BBBBBBBB-0000-4000-8000-000000000002"), world(tmp, vault: vault, registered: false)] {
            XCTAssertThrowsError(
                try LiveOperations.runCreatingFolder(dir + "/Archives", vaultDirectory: dir, vaultUUID: vault.volumeUUID, observer: { _ in }, world: w) {
                    reached += 1
                    return .exported
                })
        }
        XCTAssertEqual(reached, 1, "a refused folder step never reaches the operation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Archives"))
        XCTAssertThrowsError(
            try LiveOperations.createFolderStep(
                tmp.path + "/Mine", vaultDirectory: dir, vaultUUID: vault.volumeUUID, observer: { _ in }, world: world(tmp, vault: vault)))
    }

    /// N4: the previewed drive goes away, and a different disk appears under the same id: blocked, and it stays blocked.
    func testADriveThatGoesAwayAndComesBackDifferentStaysBlocked() async throws {
        let rec = PreparedRecorder()
        let drives = ScriptedDrives(try R6DriveTests.snapshot())
        let m = model(drives: drives, ops: rec.services)
        await m.refresh()
        m.openPreparation(try assessment(m, "disk6"), option: .eraseDisk(disk: "disk6"))
        await eventually("the review") { m.pendingDiskPlan != nil }
        drives.snapshot?.disks.removeAll { $0.id == "disk6" }
        await m.refreshDrives()
        XCTAssertEqual(m.operationBlockers, [.diskChanged])
        XCTAssertEqual(m.operationSheet?.diskChanged, true)
        var other = try R6DriveTests.snapshot()
        other.disks = other.disks.map { d in
            var d = d
            if d.id == "disk6" { d.partitions[0].volumeUUID = R6DriveTests.u(697) }
            return d
        }
        drives.snapshot = other
        await m.refreshDrives()
        XCTAssertEqual(m.operationBlockers, [.diskChanged])
        m.updateConfirmationText("USB Flash Disk")
        await m.runOperation()
        XCTAssertTrue(rec.runs.isEmpty)
    }

    /// Fix round 2, C: PABLO's shape — a ready, case-sensitive vault — offers the recommended new volume. Since R7-A it
    /// is not listed under the Destination (its verdict is in the picker); its fix sits beside the picker once it is the
    /// chosen destination (`R7AAppTests`).
    func testACaseSensitiveVaultIsListedUnderTheDestination() async throws {
        let pablo = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(301), mount: "/Volumes/Media")
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [vault(), pablo])
        await m.refresh()
        let media = try assessment(m, "disk2")
        XCTAssertEqual(media.verdict, .ready)
        XCTAssertEqual(media.recommendedOption, .addVolume(container: "disk3"))
        XCTAssertFalse(m.destinationDrives.contains { $0.verdict == .ready }, "a ready vault is only in the picker")
        m.prepareFromDestination(media)
        XCTAssertEqual(m.operationSheet?.kind, .addVolume)
    }

    /// I1: the default folder carries its vault directory; Choose Another Folder… drops it.
    func testOnlyTheStandardFolderMayBeCreated() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: PreparedRecorder().services)
        await m.refresh()
        m.openRun(row("derivedData", .runFromExternal))
        XCTAssertEqual(m.operationSheet?.inputs.standardFolderOf, "/Volumes/Vault/XCodeVault")
        await m.chooseOperationFolder()
        XCTAssertNil(m.operationSheet?.inputs.standardFolderOf)
    }

    /// I2: registered but the folders failed is its own outcome, with the reason, never "not registered".
    func testUseThisDriveReportsAPartialOutcome() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), ops: PreparedRecorder().services)
        await m.refresh()
        var snap = try R6DriveTests.snapshot()
        snap.volumes = snap.volumes.map {
            var v = $0; if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }; return v
        }
        m.driveSnapshot = snap
        m.openUseDrive(try assessment(m, "disk2"))
        await eventually("the review") { m.canConfirmOperation }
        await m.runOperation()
        XCTAssertTrue(m.operationSheet?.isSucceeded ?? false)
        XCTAssertEqual(m.registrationFoldersError, "Cannot create /Volumes/Media/XCodeVault/Archives")
        if let r = m.operationSheet?.result { XCTAssertEqual(OperationText.done(r), "Registered; the standard folders could not be created.") }
    }

    /// I4: the decisions the views used to make.
    func testTheViewsDecisionsAreModelAndCoreFunctions() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot(mediaOwners: false)))
        await m.refresh()
        XCTAssertEqual(m.destinationDrives.map(\.disk.id), ["disk2", "disk6", "disk9"])
        let media = try assessment(m, "disk2")
        XCTAssertEqual(media.ownershipMountPoints, ["/Volumes/Media"])
        XCTAssertEqual(media.volumeReasons, [], "the ownership block says it, not a second line")
        XCTAssertEqual(media.commandOptions.count, 3)
        let stick = try assessment(m, "disk6")
        XCTAssertEqual(stick.volumeReasons.map(\.volumeName), ["STICK"])
        XCTAssertEqual(stick.volumeReasons.count, 1, "one reason per volume")
        XCTAssertEqual(try assessment(m, "disk7").shownRefusals, [.timeMachine])
        XCTAssertTrue(OperationSheetState(row: nil, kind: .eraseDisk, inputs: OperationInputs()).showsExperimentalBadge)
        XCTAssertFalse(OperationSheetState(row: nil, kind: .useDrive, inputs: OperationInputs()).showsExperimentalBadge)
        XCTAssertEqual(DriveText.optionButton(.addVolume(container: "d"), recommended: true), "Add an APFS volume (erases nothing) — recommended…")
    }

    // MARK: - Fit (R1's lesson) and words

    func testThePreparationSheetAndTheDrivesScreenFit() async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
            await m.refresh()
            m.openPreparation(try assessment(m, "disk2"), option: .eraseDisk(disk: "disk2"))
            await eventually("the review") { m.pendingDiskPlan != nil }
            func fits(_ what: String) {
                let h = NSHostingController(rootView: OperationSheetView(model: m)).sizeThatFits(in: NSSize(width: 560, height: 1)).height
                XCTAssertLessThanOrEqual(h, R3SheetFitTests.ceiling, "\(language) \(what)")
            }
            fits("erase review")
            m.closeOperationSheet()
            m.openPreparation(try assessment(m, "disk2"), option: .addVolume(container: "disk3"))
            await eventually("the add-volume review") { m.pendingDiskPlan?.action == .addVolume }
            m.updateVolumeConfiguration { $0.quotaGigabytes = 500 }
            await eventually("the quota") { m.pendingDiskPlan?.configuration.quotaGigabytes == 500 }
            fits("add-volume review, quota on")
            m.closeOperationSheet()
            m.openPreparation(try assessment(m, "disk6"), option: .eraseDisk(disk: "disk6"))
            await eventually("the stick review") { m.pendingDiskPlan != nil }
            m.operationSheet?.diskChanged = true
            m.previewDriveOperation()
            XCTAssertEqual(m.operationBlockers, [.diskChanged])
            fits("disk changed")
            m.closeOperationSheet()
            var plain = try R6DriveTests.snapshot()
            plain.volumes = plain.volumes.map {
                var v = $0; if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }; return v
            }
            m.driveSnapshot = plain
            m.openUseDrive(try assessment(m, "disk2"))
            await eventually("the use-drive review") { m.operationSheet?.preview != nil }
            fits("Use This Drive review")
            m.closeOperationSheet()
            m.driveSnapshot = try R6DriveTests.snapshot()
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
