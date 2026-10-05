import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// The Plan in its three reviewed states, built by Core from fixtures (`PlanBuilderTests`): no drive; a drive like the
/// user's, whose case-sensitive vault needs the new volume; everything done. Shared by the fit test and the snapshots.
enum R7CPlans {
    static func noDrive() -> Plan {
        PlanBuilder.plan(report: PlanBuilderTests.report(), drives: [], vaults: [], locations: nil, history: [], findings: [])
    }

    static func pablo() throws -> Plan {
        let vaults = [PlanBuilderTests.mediaVault()]
        let drives = PlanBuilderTests.drives(try PlanBuilderTests.pabloSnapshot(), vaults: vaults)
        return PlanBuilder.plan(report: PlanBuilderTests.report(), drives: drives, vaults: vaults, locations: nil, history: [], findings: [])
    }

    static func done() throws -> Plan {
        let vault = R6DriveTests.vaultCheck()
        var r = Fixtures.minimalReport()
        r.items = [
            PlanBuilderTests.item("derivedData", 25 * PlanBuilderTests.gb, mount: "/Volumes/Vault", onBoot: false),
            PlanBuilderTests.item("archives", 18 * PlanBuilderTests.gb, mount: "/Volumes/Vault", onBoot: false),
        ]
        let parked = JournalTimeline.Row(
            id: "op1", kind: .runtimeOffload, outcome: .completed, started: Date(), summary: "Offload iOS 26.5 runtime", endSummary: nil,
            bytes: 10 * PlanBuilderTests.gb, recordCount: 2, sequence: 1)
        return PlanBuilder.plan(
            report: r, drives: PlanBuilderTests.drives(try R6DriveTests.snapshot(), vaults: [vault]), vaults: [vault],
            locations: XcodeLocations(derivedData: "/Volumes/Vault/XCodeVault/DerivedData", archives: "/Volumes/Vault/XCodeVault/Archives"),
            history: [parked], findings: [])
    }

    static func all() throws -> [(name: String, plan: Plan)] { [("nodrive", noDrive()), ("pablo", try pablo()), ("done", try done())] }
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
                report: try XCTUnwrap(m.report), drives: m.driveAssessments, vaults: m.vaultChecks, locations: locations, history: m.historyRows,
                findings: m.findings))
        XCTAssertEqual(plan.vaultUUID, R6DriveTests.vaultCheck().volume.volumeUUID)
        XCTAssertEqual(plan.step(.moveItems)?.items.first { $0.categoryID == "derivedData" }?.isDone, true)
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

    // MARK: - The words

    func testTheWords() throws {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let plan = try R7CPlans.pablo()
        func summary(_ upTo: UInt64, _ done: UInt64) -> String { GuideText.summary(PlanSummary(upTo: upTo, done: done, byOutcome: [:])) }
        XCTAssertEqual(summary(64_000_000_000, 18_000_000_000), "Up to 64 GB can be freed on this Mac; 18 GB is already done.")
        XCTAssertEqual(summary(64_000_000_000, 0), "Up to 64 GB can be freed on this Mac.")
        XCTAssertEqual(summary(0, 18_000_000_000), "Nothing is left to free on this Mac; 18 GB is already done.")
        XCTAssertFalse(summary(0, 0).isEmpty)
        XCTAssertEqual(Set(PlanStep.Kind.allCases.map(GuideText.title)).count, PlanStep.Kind.allCases.count)
        XCTAssertEqual(Set(PlanOutcome.allCases.map(GuideText.outcome)).count, 4, "four outcome labels")
        XCTAssertEqual(GuideText.outcome(.leavesAndComesBack), "Leaves this Mac, comes back when needed")
        XCTAssertEqual(GuideText.state(.done).kind, .success)
        XCTAssertEqual(GuideText.state(.next).kind, .info)
        XCTAssertEqual(GuideText.state(.blocked(.noExternalDrive)).kind, .neutral)
        XCTAssertEqual(GuideText.state(.notNeeded).kind, .neutral)
        for s: PlanStep.State in [.done, .next, .blocked(.needsEarlierStep), .notNeeded] {
            XCTAssertFalse(GuideText.state(s).text.isEmpty, "never color alone: every state has its word")
        }
        let prepare = try XCTUnwrap(plan.step(.prepareDrive))
        XCTAssertEqual(GuideText.actionTitle(try XCTUnwrap(prepare.action)), "Add a Case-insensitive Volume…")
        XCTAssertTrue(GuideText.explanation(prepare).contains("Media"))
        XCTAssertEqual(GuideText.actionTitle(.useDrive(diskID: "d", volumeUUID: "u")), "Use This Drive…")
        XCTAssertEqual(GuideText.actionTitle(.run(categoryID: "derivedData", bucket: .runFromExternal)), "Run…")
        XCTAssertNotNil(GuideText.warning("derivedDataTests"))
        let noDrive = R7CPlans.noDrive()
        XCTAssertEqual(GuideText.explanation(try XCTUnwrap(noDrive.step(.chooseDrive))), "Connect an external drive, such as a USB SSD or hard disk.")
        XCTAssertEqual(GuideText.explanation(try XCTUnwrap(noDrive.step(.moveItems))), "Deleting needs no drive. The rest waits for the vault.")
        for step in try R7CPlans.all().flatMap(\.plan.steps) { XCTAssertFalse(GuideText.explanation(step).isEmpty, step.id) }
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
    }

    // MARK: - Snapshots (XCV_SNAPSHOTS=1)

    func testSnapshots() throws {
        guard SnapshotWriter.isEnabled else { return }
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            for (name, plan) in try R7CPlans.all() {
                _ = try SnapshotWriter.write(GuidedPlanView(plan: plan), name: "r7c-plan-\(language)-\(name)", size: NSSize(width: 820, height: 1000))
            }
        }
    }
}
