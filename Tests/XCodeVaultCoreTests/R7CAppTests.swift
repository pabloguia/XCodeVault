import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// The Plan in its reviewed states, built by Core from fixtures (`PlanBuilderTests`): no drive; a drive like the user's,
/// whose case-sensitive vault needs the new volume; everything done; simulator devices (the F1 line); and a crowded one —
/// many items, several parked runtimes, a long drive name. Shared by the fit test and the snapshots.
enum R7CPlans {
    typealias T = PlanBuilderTests
    static let gb = PlanBuilderTests.gb

    static func noDrive() -> Plan { T.plan() }

    static func pablo() throws -> Plan {
        let vaults = [T.mediaVault()]
        return T.plan(drives: T.drives(try T.pabloSnapshot(), vaults: vaults), vaults: vaults)
    }

    static func done() throws -> Plan {
        let (_, vault, drives) = try T.good()
        var r = Fixtures.minimalReport()
        r.items = [T.item("archives", 18 * gb, mount: "/Volumes/Vault", onBoot: false)]
        let parked = ParkedRuntimes.current([T.offload(1, "op1")], installed: [])
        return T.plan(r, drives: drives, vaults: [vault], locations: T.onVault, parked: parked)
    }

    static func devices() throws -> Plan {
        let (_, vault, drives) = try T.good()
        return T.plan(T.report([T.item("simulatorDevices", 7 * gb)]), drives: drives, vaults: [vault])
    }

    /// Many items, four parked runtimes, a long drive name on a case-sensitive drive that is being prepared.
    static func crowded() throws -> Plan {
        var s = try T.pabloSnapshot()
        let long = "Externe Festplatte für Xcode-Archivierung und Sicherungskopien"
        s.volumes = s.volumes.map {
            var v = $0
            if v.volumeName == "Media" { v.volumeName = long }
            return v
        }
        let extra = [
            "simulatorDevices", "deviceSupport", "previews", "deviceLogs", "xcodePackages", "simulatorUserCaches", "simulatorDeadContainers",
            "simulatorLogStore", "xctestDevices", "playgroundDevices",
        ].enumerated().map { i, id in T.item(id, UInt64(i + 1) * gb) }
        let parked = ParkedRuntimes.current(
            [
                T.offload(1, "a"), T.offload(2, "b", build: "23G1"),
                T.offload(3, "c", rid: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5", build: "22T572"),
                T.offload(4, "d", rid: "com.apple.CoreSimulator.SimRuntime.tvOS-26-0", build: "23J352"),
            ], installed: [])
        return T.plan(T.report(extra), drives: T.drives(s, vaults: []), parked: parked, findings: [])
    }

    static func all() throws -> [(name: String, plan: Plan)] {
        [("nodrive", noDrive()), ("pablo", try pablo()), ("done", try done()), ("devices", try devices()), ("crowded", try crowded())]
    }
}

/// R7-C: the guided Plan's app part — the sidebar item, the step→sheet mapping (`AppModel.planTarget` and
/// `performPlanAction`), the words (`GuideText`), and the snapshots. Through `AppEnvironment` fakes only: nothing scans
/// this Mac, reads its Xcode defaults, touches a disk, a journal or a vault, or opens a window.
@MainActor
final class R7CAppTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func model(
        drives: ScriptedDrives? = nil, checks: [VaultVolumeCheck] = [R6DriveTests.vaultCheck()], locations: XcodeLocations? = nil
    ) -> AppModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r7c-\(UUID().uuidString).jsonl")
        let survey = bucketSampleSurvey(checks: checks)
        var env = AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in })
        env.xcodeLocations = { locations }
        if let drives { env.drives = drives.services }
        return AppModel(environment: env)
    }

    private func assessment(_ m: AppModel, _ id: String) throws -> DriveAssessment {
        try XCTUnwrap(m.driveAssessments.first { $0.disk.id == id })
    }

    // MARK: - The sidebar

    func testThePlanIsTheFirstSaveSpaceItem() {
        XCTAssertEqual(SidebarSection.saveSpace.first, .plan)
        XCTAssertEqual(SidebarSection.plan.symbol, "list.number")
        XCTAssertEqual(SidebarSection.plan.title, "Plan")
        XCTAssertNil(SidebarSection.plan.bucket)
    }

    // MARK: - The model's plan

    func testThePlanIsDerivedFromWhatTheModelRead() async throws {
        let locations = XcodeLocations(derivedData: "/Volumes/Vault/XCodeVault/DerivedData", archives: nil)
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), locations: locations)
        XCTAssertNil(m.plan, "nothing before the first scan")
        await m.refresh()
        XCTAssertEqual(m.xcodeLocations, locations, "read with the scan, through the environment")
        let plan = try XCTUnwrap(m.plan)
        XCTAssertEqual(
            plan,
            PlanBuilder.plan(
                report: try XCTUnwrap(m.report), drives: m.driveAssessments, vaults: m.vaultChecks, locations: locations,
                parked: m.parkedRuntimes, findings: m.findings))
        XCTAssertEqual(plan.vaultUUID, R6DriveTests.vaultCheck().volume.volumeUUID)
        XCTAssertEqual(plan.step(.moveItems)?.items.first { $0.id == "runFromExternal:derivedData" }?.isDone, true)
    }

    func testTheInertEnvironmentReadsNoXcodeLocations() async {
        let env = AppEnvironment(
            survey: { sampleSurvey() }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in })
        XCTAssertNil(env.xcodeLocations())
    }

    // MARK: - The step→sheet mapping (the whole of what the Plan can reach)

    func testEachPlanActionOpensItsExistingScreen() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        XCTAssertEqual(m.planTarget(.showDrives, vault: nil), .section(.drives))
        XCTAssertEqual(m.planTarget(.showBucket(.deleteAndRegenerate), vault: nil), .section(.delete))
        XCTAssertEqual(m.planTarget(.showBucket(.parkExternally), vault: nil), .section(.park))
        XCTAssertEqual(m.planTarget(.showBucket(.runFromExternal), vault: nil), .section(.runExternally))
        XCTAssertEqual(m.planTarget(.showHealth, vault: nil), .section(.health))
        for (action, section) in [(PlanAction.showDrives, SidebarSection.drives), (.showBucket(.deleteAndRegenerate), .delete), (.showHealth, .health)] {
            m.section = .plan
            m.performPlanAction(action)
            XCTAssertEqual(m.section, section)
            XCTAssertNil(m.operationSheet, "a screen, not a sheet")
        }
    }

    func testPrepareOpensThePreparationSheetOnTheProposedOption() async throws {
        let media = PlanBuilderTests.mediaVault()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [media])
        await m.refresh()
        let plan = try XCTUnwrap(m.plan)
        let action = try XCTUnwrap(plan.step(.prepareDrive)?.action)
        let option = PreparationOption.addVolume(container: "disk3")
        XCTAssertEqual(action, .prepareDrive(diskID: "disk2", option: option))
        XCTAssertEqual(m.planTarget(action, vault: plan.vaultUUID), .preparation(try assessment(m, "disk2"), option))
        m.performPlanAction(action)
        let sheet = try XCTUnwrap(m.operationSheet)
        XCTAssertEqual(sheet.kind, OperationKind.forOption(option))
        XCTAssertEqual(sheet.inputs.diskID, "disk2")
        XCTAssertEqual(sheet.inputs.driveOption, option)
        XCTAssertEqual(sheet.phase, .review, "it opens on its own review: nothing runs")
    }

    func testUseDriveOpensUseThisDriveForTheProposedVolume() async throws {
        let media = PlanBuilderTests.mediaVault()
        let m = model(drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume()), checks: [media])
        await m.refresh()
        let action = try XCTUnwrap(m.plan?.step(.registerVault)?.action)
        XCTAssertEqual(action, .useDrive(diskID: "disk2", volumeUUID: R6DriveTests.u(302)))
        m.performPlanAction(action)
        let sheet = try XCTUnwrap(m.operationSheet)
        XCTAssertEqual(sheet.kind, .useDrive)
        XCTAssertEqual(sheet.inputs.driveVolumeUUID, R6DriveTests.u(302))
        XCTAssertEqual(sheet.phase, .review)
    }

    /// With two usable vaults the Run sheet has no default; the Plan's own vault is pre-chosen, with its standard folder.
    func testRunOpensTheRunSheetOnThePlansVault() async throws {
        let good = R6DriveTests.vaultCheck()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [good, PlanBuilderTests.mediaVault()])
        await m.refresh()
        XCTAssertNil(m.defaultVaultUUID, "two usable vaults: no default of its own")
        let plan = try XCTUnwrap(m.plan)
        XCTAssertEqual(plan.vaultUUID, good.volume.volumeUUID, "the case-insensitive vault, not the one its drive fixes")
        let item = try XCTUnwrap(plan.step(.moveItems)?.items.first { $0.id == "runFromExternal:derivedData" })
        let action = try XCTUnwrap(item.action)
        guard case .run(let row, let vault) = m.planTarget(action, vault: plan.vaultUUID) else { return XCTFail("not a Run sheet") }
        XCTAssertEqual(row.categoryID, "derivedData")
        XCTAssertEqual(vault, good.volume.volumeUUID)
        m.performPlanAction(action)
        let sheet = try XCTUnwrap(m.operationSheet)
        XCTAssertEqual(sheet.row?.categoryID, "derivedData")
        XCTAssertEqual(sheet.inputs.vaultUUID, good.volume.volumeUUID)
        XCTAssertEqual(sheet.inputs.folder, "/Volumes/Vault/XCodeVault/DerivedData")
        XCTAssertEqual(sheet.phase, .review)
    }

    /// Something the plan names that is no longer there opens the screen that lists it, never a sheet.
    func testAGoneDriveOrRowFallsBackToItsScreen() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        XCTAssertEqual(m.planTarget(.prepareDrive(diskID: "disk99", option: .addVolume(container: "disk3")), vault: nil), .section(.drives))
        XCTAssertTrue(try assessment(m, "disk2").options.contains(.eraseDisk(disk: "disk2")), "the drive offers an erase in Drives")
        XCTAssertEqual(
            m.planTarget(.prepareDrive(diskID: "disk2", option: .eraseDisk(disk: "disk2")), vault: nil), .section(.drives), "the Plan never opens an erase")
        XCTAssertEqual(m.planTarget(.useDrive(diskID: "disk2", volumeUUID: "nope"), vault: nil), .section(.drives))
        XCTAssertEqual(m.planTarget(.run(categoryID: "nope", bucket: .parkExternally), vault: nil), .section(.park))
    }

    // MARK: - F5: a forged option opens no sheet

    func testAForgedOptionFallsBackToDrives() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot(mediaOwners: false)), checks: [])
        await m.refresh()
        let disk2 = try assessment(m, "disk2")
        let forged: [PreparationOption] = [
            .eraseVolume(volume: "disk3s1", name: "Media"), .eraseDisk(disk: "disk2"), .enableOwnership(mountPoint: "/Volumes/Media"),
        ]
        for option in forged {
            XCTAssertTrue(disk2.options.contains(option), "the drive offers \(option) in Drives: only the Plan refuses it")
            XCTAssertFalse(disk2.isRecommended(option))
            XCTAssertEqual(m.planTarget(.prepareDrive(diskID: "disk2", option: option), vault: nil), .section(.drives), "\(option)")
            m.section = .plan
            m.performPlanAction(.prepareDrive(diskID: "disk2", option: option))
            XCTAssertNil(m.operationSheet, "\(option): no sheet")
            XCTAssertEqual(m.section, .drives)
        }
    }

    // MARK: - F6: from the Plan, the preparation sheet erases nothing

    func testThePreparationSheetFromThePlanOffersNoErasingOption() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [PlanBuilderTests.mediaVault()])
        await m.refresh()
        let action = try XCTUnwrap(m.plan?.step(.prepareDrive)?.action)
        m.performPlanAction(action)
        XCTAssertEqual(m.operationSheet?.nonErasingOnly, true)
        XCTAssertFalse(m.preparationChoices.isEmpty)
        XCTAssertTrue(m.preparationChoices.allSatisfy { !$0.erases }, "\(m.preparationChoices)")
        let kind = m.operationSheet?.kind
        m.choosePreparationOption(.eraseDisk(disk: "disk2"))
        XCTAssertEqual(m.operationSheet?.kind, kind, "an erase cannot be chosen in it")
        XCTAssertEqual(m.operationSheet?.inputs.driveOption, .addVolume(container: "disk3"))
        // From Drives the same drive's sheet still offers its erase options.
        m.closeOperationSheet()
        m.openPreparation(try assessment(m, "disk2"))
        XCTAssertEqual(m.operationSheet?.nonErasingOnly, false)
        XCTAssertEqual(m.preparationChoices, try assessment(m, "disk2").commandOptions, "unfiltered from Drives")
        m.closeOperationSheet()
        let free = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [])
        await free.refresh()
        free.openPreparation(try XCTUnwrap(free.driveAssessments.first { $0.disk.id == "disk2" }))
        XCTAssertTrue(free.preparationChoices.contains { $0.erases }, "erasing stays possible from Drives")
    }

    // MARK: - F7: a stale vault from the Plan

    func testAStaleOrOfflineVaultHandedToRunIsNotUsed() async throws {
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        let row = try XCTUnwrap(m.rows(for: .runFromExternal).first { $0.categoryID == "derivedData" })
        m.openRun(row, vault: "00000000-0000-0000-0000-00000000DEAD")
        XCTAssertEqual(m.operationSheet?.inputs.vaultUUID, m.defaultVaultUUID, "an unknown vault falls back to the default")
        m.closeOperationSheet()
        let offline = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(777), state: .absent, mount: nil)
        let m2 = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [offline])
        await m2.refresh()
        m2.openRun(row, vault: offline.volume.volumeUUID)
        XCTAssertNil(m2.operationSheet?.inputs.vaultUUID, "an offline vault is never pre-chosen")
        XCTAssertNil(m2.operationSheet?.inputs.folder)
    }

    func testTheVaultVanishingBetweenThePlanAndTheSheet() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r7c-\(UUID().uuidString).jsonl")
        let good = R6DriveTests.vaultCheck()
        let box = SurveyBox(bucketSampleSurvey(checks: [good]))
        var env = AppEnvironment(
            survey: { box.survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in })
        env.drives = ScriptedDrives(try R6DriveTests.snapshot()).services
        let m = AppModel(environment: env)
        await m.refresh()
        let action = try XCTUnwrap(m.plan?.step(.moveItems)?.items.first { $0.id == "runFromExternal:derivedData" }?.action)
        XCTAssertEqual(m.plan?.vaultUUID, good.volume.volumeUUID)
        // The vault is unplugged and the next scan sees it absent; the button the user saw is pressed afterwards.
        box.survey = bucketSampleSurvey(checks: [R6DriveTests.vaultCheck(state: .absent, mount: nil)])
        await m.refresh()
        m.performPlanAction(action)
        XCTAssertNil(m.operationSheet?.inputs.vaultUUID, "the gone vault is not pre-chosen")
        XCTAssertNil(m.operationSheet?.inputs.folder, "and no folder on it")
    }

    // MARK: - The screen the app opens on

    func testTheAppOpensOnThePlanWhileSomethingIsToDo() async throws {
        XCTAssertNil(AppModel.launchSection(nil))
        XCTAssertEqual(AppModel.launchSection(R7CPlans.noDrive()), .plan, "deleting is partly available")
        XCTAssertEqual(AppModel.launchSection(try R7CPlans.pablo()), .plan)
        XCTAssertEqual(AppModel.launchSection(try R7CPlans.done()), .overview, "nothing left: the Overview")
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()))
        await m.refresh()
        XCTAssertEqual(m.section, .plan)
        XCTAssertFalse(m.canGoBack, "no Back entry for a screen the user did not choose")
        m.section = .storage
        await m.refresh()
        XCTAssertEqual(m.section, .storage, "never moves the user after the first scan")
    }

    // MARK: - The words

    func testTheWords() throws {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let plan = try R7CPlans.pablo()
        func summary(_ upTo: UInt64, _ done: UInt64) -> String { GuideText.summary(PlanSummary(upTo: upTo, done: done, byOutcome: [:])) }
        XCTAssertEqual(summary(64_000_000_000, 18_000_000_000), "Up to 64 GB can be freed on this Mac; 18 GB is already done.")
        XCTAssertEqual(summary(64_000_000_000, 0), "Up to 64 GB can be freed on this Mac.")
        XCTAssertEqual(summary(0, 18_000_000_000), "Nothing is left to free on this Mac; 18 GB is already done.")
        XCTAssertFalse(summary(0, 0).isEmpty)
        XCTAssertNil(GuideText.lostLine(PlanSummary(upTo: 1, done: 0, byOutcome: [:])))
        XCTAssertEqual(
            GuideText.lostLine(try R7CPlans.devices().summary), "Another 7 GB if you also delete simulator devices (what you made in them is lost).")
        XCTAssertEqual(Set(PlanStep.Kind.allCases.map(GuideText.title)).count, PlanStep.Kind.allCases.count)
        XCTAssertEqual(Set(PlanOutcome.allCases.map(GuideText.outcome)).count, PlanOutcome.allCases.count)
        XCTAssertEqual(GuideText.outcome(.parkedOnDrive), "Parked on the drive")
        XCTAssertEqual(GuideText.outcomeDetail(.parkedOnDrive), "it comes back to this Mac only when you restore it; that needs the drive")
        XCTAssertEqual(GuideText.outcome(.deletedLost), "Deleted; you recreate it yourself")
        XCTAssertEqual(GuideText.outcomeDetail(.deletedLost), "nothing recreates it — you lose what you made in it")
        XCTAssertFalse(GuideText.outcome(.parkedOnDrive).contains("when needed"), "never suggests the return is automatic")
        XCTAssertTrue(GuideText.legend.contains("connected"))
        XCTAssertEqual(GuideText.state(.done).kind, .success)
        XCTAssertEqual(GuideText.state(.next).kind, .info)
        XCTAssertEqual(GuideText.state(.partly).text, "Partly available")
        XCTAssertEqual(GuideText.state(.blocked(.noExternalDrive)).kind, .neutral)
        XCTAssertEqual(GuideText.state(.notNeeded).kind, .neutral)
        for s: PlanStep.State in [.done, .next, .partly, .blocked(.needsEarlierStep), .notNeeded] {
            XCTAssertFalse(GuideText.state(s).text.isEmpty, "never color alone: every state has its word")
        }
        let prepare = try XCTUnwrap(plan.step(.prepareDrive))
        XCTAssertEqual(GuideText.actionTitle(try XCTUnwrap(prepare.action)), "Add a Case-insensitive Volume…")
        XCTAssertTrue(GuideText.explanation(prepare).contains("Media"))
        XCTAssertEqual(
            GuideText.explanation(try XCTUnwrap(plan.step(.chooseDrive))),
            "Media holds your vault, but its volume is case-sensitive or ignores ownership; the next step adds a suitable volume.")
        XCTAssertEqual(GuideText.explanation(try XCTUnwrap(plan.step(.registerVault))), "Add the volume first (step 2).")
        XCTAssertEqual(
            GuideText.blockText(.vaultShadowed(name: "V", bytes: 3_000_000_000), subject: ""),
            "Shadow data was found where your vault V mounts: 3 GB on this Mac. Health says what to do.")
        XCTAssertTrue(GuideText.blockText(.vaultShadowed(name: "V", bytes: nil), subject: "").contains("Shadow data"))
        XCTAssertEqual(
            GuideText.blockText(.vaultReplaced("V"), subject: ""), "A different volume is mounted where your vault V should be. Drives shows what is connected."
        )
        XCTAssertEqual(GuideText.actionTitle(.useDrive(diskID: "d", volumeUUID: "u")), "Use This Drive…")
        XCTAssertEqual(GuideText.actionTitle(.run(categoryID: "derivedData", bucket: .runFromExternal)), "Run…")
        XCTAssertNotNil(GuideText.warning("derivedDataTests"))
        XCTAssertEqual(GuideText.name(.newDerivedData), "New builds go to the drive")
        XCTAssertEqual(GuideText.name(.oldDerivedData), "Old DerivedData on this Mac")
        XCTAssertEqual(GuideText.name(.newArchives), "New Archives")
        XCTAssertEqual(GuideText.name(.existingArchives), "Existing Archives")
        XCTAssertEqual(GuideText.name(.category("simulatorRuntimeAssets")), "Simulator runtimes")
        XCTAssertEqual(GuideText.name(.parkedRuntime("iOS 26.5 (23F77)")), "iOS 26.5 (23F77)")
        let noDrive = R7CPlans.noDrive()
        XCTAssertEqual(GuideText.explanation(try XCTUnwrap(noDrive.step(.chooseDrive))), "Connect an external drive, such as a USB SSD or hard disk.")
        XCTAssertEqual(GuideText.explanation(try XCTUnwrap(noDrive.step(.moveItems))), "Deleting is available now; the rest waits for the vault.")
        for step in try R7CPlans.all().flatMap(\.plan.steps) { XCTAssertFalse(GuideText.explanation(step).isEmpty, step.id) }
    }

    /// Every catalog category has a localized name: no English Core name leaks into another language.
    func testEveryCategoryHasALocalizedName() {
        for c in StorageCatalog.all { XCTAssertNotNil(GuideText.categoryName(c.id), c.id) }
        L10n.configure(override: "ja", environment: [:], preferred: [])
        XCTAssertEqual(GuideText.name(.category("simulatorRuntimeAssets")), "シミュレータのランタイム")
        XCTAssertNotEqual(GuideText.name(.newArchives), "New Archives")
    }

    func testEveryExperimentalStepAndItemCarriesTheMarker() throws {
        // The marker is drawn from `isExperimental`; Core sets it on every preparation and every experimental option.
        let pablo = try R7CPlans.pablo()
        XCTAssertTrue(try XCTUnwrap(pablo.step(.prepareDrive)).isExperimental)
        for item in pablo.steps.flatMap(\.items) {
            let bucket = item.id.split(separator: ":").first.map(String.init)
            let option = StorageCatalog.category(item.categoryID)?.savingsOptionDetails.first { $0.bucket.rawValue == bucket }
            if let option { XCTAssertEqual(item.isExperimental, option.isExperimental, item.id) }
        }
        let devices = try XCTUnwrap(try R7CPlans.devices().step(.moveItems)?.items.first { $0.categoryID == "simulatorDevices" })
        XCTAssertTrue(devices.losesUserData, "drawn with the Loses-your-data tag")
    }

    // MARK: - Snapshots (XCV_SNAPSHOTS=1)

    func testSnapshots() throws {
        guard SnapshotWriter.isEnabled else { return }
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            for (name, plan) in try R7CPlans.all() {
                _ = try SnapshotWriter.write(GuidedPlanView(plan: plan), name: "r7c-plan-\(language)-\(name)", size: NSSize(width: 820, height: 1400))
            }
        }
    }
}
