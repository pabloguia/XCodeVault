import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R7-D: what the user's real-window check of R7 found — the volume `addVolume` made on their physical disk ignores
/// ownership, and the app kept recommending another new volume. Fixtures and fakes only: nothing reads this Mac's disks,
/// registry, journal or Xcode, and nothing opens Finder or touches the pasteboard.
@MainActor
final class R7DTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private final class Revealed: @unchecked Sendable {
        var paths: [[String]] = []
    }

    private func model(drives: ScriptedDrives, checks: [VaultVolumeCheck], copied: CopiedStrings = CopiedStrings(), revealed: Revealed = Revealed())
        -> AppModel
    {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r7d-\(UUID().uuidString).jsonl")
        let survey = bucketSampleSurvey(checks: checks)
        var env = AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.unavailableInThisBuild),
            approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { copied.strings.append($0) })
        env.drives = drives.services
        env.reveal = { revealed.paths.append($0) }
        return AppModel(environment: env)
    }

    // MARK: 1–2. Ownership is the recommended fix, and the Plan's step 2

    func testThePlansOwnershipStepShowsInFinderAndCopiesTheCommandRunningNothing() async throws {
        let copied = CopiedStrings()
        let revealed = Revealed()
        let m = model(
            drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), checks: [PlanBuilderTests.mediaVault()], copied: copied,
            revealed: revealed)
        await m.refresh()
        let step = try XCTUnwrap(m.plan?.step(.prepareDrive))
        let show = try XCTUnwrap(step.action)
        let copy = try XCTUnwrap(step.secondaryAction)
        XCTAssertEqual(m.planTarget(show, vault: nil), .reveal("/Volumes/XCodeVault"))
        XCTAssertEqual(m.planTarget(copy, vault: nil), .copyOwnershipCommand("/Volumes/XCodeVault"))
        m.performPlanAction(show)
        m.performPlanAction(copy)
        XCTAssertEqual(revealed.paths, [["/Volumes/XCodeVault"]])
        XCTAssertEqual(copied.strings, ["sudo diskutil enableOwnership /Volumes/XCodeVault"])
        XCTAssertNil(m.operationSheet, "nothing runs; no sheet")
        XCTAssertEqual(m.plan?.primary, .step(.prepareDrive))
        XCTAssertEqual(GuideText.actionTitle(show), "Show in Finder")
        // A path no drive shows ownership off on is Drives' to show.
        XCTAssertEqual(m.planTarget(.showInFinder(path: "/Users"), vault: nil), .section(.drives))
        XCTAssertEqual(m.planTarget(.copyOwnershipCommand(mountPoint: "/Volumes/Media"), vault: nil), .section(.drives))
    }

    func testTheDestinationsFixRevealsTheVolumeForOwnership() async throws {
        let revealed = Revealed()
        let m = model(drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), checks: [], revealed: revealed)
        await m.refresh()
        let disk2 = try XCTUnwrap(m.driveAssessments.first { $0.disk.id == "disk2" })
        XCTAssertEqual(DriveText.prepareTitle(disk2.prepareAction), "Turn On Ownership for XCodeVault…")
        m.prepareFromDestination(disk2)
        XCTAssertEqual(revealed.paths, [["/Volumes/XCodeVault"]])
        XCTAssertNil(m.operationSheet)
        XCTAssertEqual(
            DriveText.optionsFootnote(disk2),
            "Turning on ownership for “XCodeVault” is recommended: it erases nothing, and no new volume is needed. "
                + L10n.tr("app.drives.options.eraseDeletes"))
    }

    func testTheWords() {
        XCTAssertEqual(
            GuideText.wrongKind(drive: "PABLO", issue: .caseSensitive, ownershipVolume: "XCodeVault"),
            "PABLO holds your vault on a case-sensitive volume; XCodeVault on the same drive needs ownership turned on.")
        XCTAssertFalse(GuideText.wrongKind(drive: "P", issue: .caseSensitive, ownershipVolume: nil).contains(" or "), "exactly what is missing")
        XCTAssertEqual(GuideText.blockText(.ownershipFirst("XCodeVault"), subject: ""), "Turn on ownership for XCodeVault first (step 2).")
        let second = PlanStep(
            kind: .registerVault, state: .next, subject: "XCodeVault", note: .secondVault(existing: "PABLO"), bytes: nil, isExperimental: false,
            action: nil, items: [], option: nil, findingCount: 0)
        XCTAssertEqual(
            GuideText.explanation(second),
            "Register XCodeVault as a second vault and create its standard folders. Your vault on PABLO stays registered, and nothing on it moves.")
    }

    // MARK: 3. Reload re-reads the drives

    func testRefreshReReadsTheDrivesSoAnOwnershipChangeShows() async throws {
        let drives = ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false))
        let m = model(drives: drives, checks: [PlanBuilderTests.mediaVault()])
        await m.refresh()
        XCTAssertEqual(m.plan?.step(.prepareDrive)?.state, .next)
        let reads = drives.reads
        // The user turns ownership on in Finder; then ⌘R / the toolbar's refresh.
        drives.snapshot = try R7ACoreTests.snapshotWithMadeVolume(owners: true)
        await m.refresh()
        XCTAssertGreaterThan(drives.reads, reads, "refresh() reads the drives as well as the scan")
        XCTAssertEqual(m.plan?.step(.prepareDrive)?.state, .done)
        XCTAssertEqual(m.plan?.step(.registerVault)?.state, .next)
        let action = try XCTUnwrap(m.plan?.step(.registerVault)?.action)
        m.performPlanAction(action)
        XCTAssertEqual(m.operationSheet?.kind, .useDrive)
        XCTAssertEqual(m.operationSheet?.inputs.driveVolumeUUID, R6DriveTests.u(302), "Use This Drive pre-filled for XCodeVault")
    }

    // MARK: 4. Copy Command copies the template, commented, then the filled line

    func testCopyCommandCopiesTheTemplateCommentedThenTheFilledLine() async throws {
        let copied = CopiedStrings()
        let m = model(drives: ScriptedDrives(try R6DriveTests.snapshot()), checks: [R6DriveTests.vaultCheck()], copied: copied)
        await m.refresh()
        let dd = try XCTUnwrap(m.rows(for: .runFromExternal).first { $0.categoryID == "derivedData" })
        let expected = "# " + dd.command + "\nxcodevaultctl locations set-derived-data /Volumes/Vault/XCodeVault/DerivedData"
        XCTAssertEqual(m.copiedCommand(dd), expected)
        m.copyCommand(dd)
        XCTAssertEqual(copied.strings, [expected])
        let none = model(drives: ScriptedDrives(nil), checks: [])
        await none.refresh()
        XCTAssertEqual(none.copiedCommand(dd), dd.command, "without a vault, the template only")
    }

    // MARK: 5. A second vault on the same physical disk

    func testASecondVaultOnTheSameDiskIsAllowed() throws {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        func volume(_ node: String, _ name: String, _ uuid: String, _ mp: String) -> Volume {
            Volume(
                deviceNode: "/dev/" + node, volumeName: name, volumeUUID: uuid, mountPoint: mp, filesystemPersonality: "APFS", filesystemType: "apfs",
                isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true,
                ownersEnabled: true, totalBytes: 10, freeBytes: 5, isBootVolume: false)
        }
        let first = volume("disk3s1", "PABLO", R6DriveTests.u(301), t.dir("pablo"))
        let second = volume("disk3s2", "XCodeVault", R6DriveTests.u(302), t.dir("xcv"))
        for v in [first, second] {
            let id = v.volumeUUID!
            try reg.register(v, journal: journal, isMountPoint: { _ in true }, volumeUUID: { _ in id })
        }
        XCTAssertEqual(try reg.volumes().map(\.volumeUUID), [R6DriveTests.u(301), R6DriveTests.u(302)], "both stay registered")
        // The disk guards: a disk holding a vault refuses erasing and repartitioning, and still allows what a second vault
        // needs — nothing for registering, and adding a volume.
        let snap = try R7ACoreTests.snapshotWithMadeVolume()
        let disk = try XCTUnwrap(snap.disks.first { $0.id == "disk2" })
        let registered: Set<String> = [R6DriveTests.u(301)]
        XCTAssertTrue(DiskSafety.refusals(for: .addVolume, target: "disk3", on: disk, in: snap, registeredVaultUUIDs: registered).isEmpty)
        XCTAssertFalse(DiskSafety.refusals(for: .eraseDisk, target: "disk2", on: disk, in: snap, registeredVaultUUIDs: registered).isEmpty)
    }
}
