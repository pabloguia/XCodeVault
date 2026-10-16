import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R5, commit 1 of the HIG review (§5): the decisions behind the feedback and the destructive actions, in Core.
final class R5FeedbackCoreTests: XCTestCase {
    let gb: UInt64 = 1_000_000_000

    func volume(_ node: String, _ name: String, uuid: String?, mount: String?, boot: Bool = false, inside: Bool = true, writable: Bool = true) -> Volume {
        Volume(
            deviceNode: node, volumeName: name, volumeUUID: uuid, mountPoint: mount, filesystemPersonality: "APFS", filesystemType: "apfs",
            isInternal: inside, isRemovableMedia: !inside, isEjectable: !inside, busProtocol: inside ? "PCI-Express" : "USB", isSolidState: true,
            isWritable: writable, ownersEnabled: true, totalBytes: 500 * gb, freeBytes: 100 * gb, isBootVolume: boot)
    }

    func check(_ uuid: String, _ state: VaultVolumeState) -> VaultVolumeCheck {
        let v = VaultVolume(volumeUUID: uuid, volumeName: "Vault \(uuid)", lastMountPoint: "/Volumes/Vault", registeredAt: Date(), sentinelID: "s")
        return VaultVolumeCheck(volume: v, state: state, currentMountPoint: nil, shadowBytes: nil, detail: "d")
    }

    /// HIG review DR1: the boot volume never shows whether it can be a vault, or why not — expected, not an error.
    func testTheBootVolumeShowsNoQualificationDetail() {
        let data = volume("/dev/disk3s5", "Data", uuid: "D", mount: "/System/Volumes/Data", boot: true)
        let usb = volume("/dev/disk8s1", "Stick", uuid: "U", mount: "/Volumes/Stick", inside: false)
        let other = volume("/dev/disk3s7", "Other System", uuid: "OS", mount: "/Volumes/Other", boot: true)
        let rows = DrivesList.make(volumes: [data, usb, other], checks: []).rows
        XCTAssertTrue(rows[0].isBootGroup)
        XCTAssertFalse(rows[0].qualification.blockers.isEmpty, "the boot blocker exists in Core")
        XCTAssertFalse(rows[0].showsQualificationDetail, "and the row does not show it")
        XCTAssertTrue(rows[1].showsQualificationDetail)
        XCTAssertFalse(rows[2].showsQualificationDetail, "another install's boot-role volume is not a candidate either")
    }

    /// HIG review DR3: one verdict per vault, from the check (can it be used) and the drive (does it still qualify).
    func testAVaultHasOneVerdict() {
        let fine = volume("/dev/disk5s1", "Fine", uuid: "F", mount: "/Volumes/Fine", inside: false)
        let readOnly = volume("/dev/disk6s1", "ReadOnly", uuid: "R", mount: "/Volumes/ReadOnly", inside: false, writable: false)
        let broken = volume("/dev/disk7s1", "Broken", uuid: "B", mount: "/Volumes/Broken", inside: false)
        let plain = volume("/dev/disk9s1", "Plain", uuid: "P", mount: "/Volumes/Plain", inside: false)
        let rows = DrivesList.make(
            volumes: [fine, readOnly, broken, plain], checks: [check("F", .verified), check("R", .movedMountPoint), check("B", .sentinelMissing)]
        ).rows
        let expectedFine: DriveRow.VaultVerdict = rows[0].qualification.verdict == .suitable ? .ready : .readyWithWarnings
        XCTAssertEqual(rows[0].vaultVerdict, expectedFine, "usable on a drive that qualifies")
        XCTAssertEqual(rows[1].qualification.verdict, .unsuitable, "a read-only drive no longer qualifies")
        XCTAssertEqual(rows[1].vaultVerdict, .needsAttention, "usable, but the drive needs attention: never \"verified\" beside \"unsuitable\"")
        XCTAssertEqual(rows[2].vaultVerdict, .notUsable, "the check decides whether it can be used")
        XCTAssertNil(rows[3].vaultVerdict, "no vault, no verdict")
    }

    /// HIG review A1: Full Disk Access off while every folder was read is optional, with its own word.
    func testFullDiskAccessIsOptionalWhenNothingWasRefused() {
        let optional = AccessChecklist.rows(fullDiskAccess: .notGranted, helper: .notInstalled, savings: SavingsSummary(), plan: [])[0]
        XCTAssertFalse(optional.isNeeded)
        XCTAssertEqual(optional.statusKey, AccessChecklist.Key.fdaStatusOff)
        XCTAssertEqual(optional.action, .openFullDiskAccessSettings, "the button stays: granting it may still add to the totals")
        let refused = AccessChecklist.rows(fullDiskAccess: .notGranted, helper: .notInstalled, savings: SavingsSummary(), plan: [], privacyRefusalCount: 2)[0]
        XCTAssertTrue(refused.isNeeded)
        XCTAssertEqual(refused.statusKey, AccessChecklist.Key.fdaStatusMissing)
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for row in AccessChecklist.rows(fullDiskAccess: fda, helper: helper, savings: SavingsSummary(), plan: [], privacyRefusalCount: 1) {
                    XCTAssertTrue(row.isNeeded || row.state == .granted, "\(fda) \(helper) \(row.need): only the optional case is not needed")
                }
            }
        }
    }

    /// HIG review A2: the hint shows only after the user opened the pane, and only beside the Settings button.
    func testTheHintFollowsTheTripToSettings() {
        let rows = AccessChecklist.rows(fullDiskAccess: .notGranted, helper: .notInstalled, savings: SavingsSummary(), plan: [])
        XCTAssertFalse(AccessChecklist.showsHint(rows[0], openedSettings: false))
        XCTAssertTrue(AccessChecklist.showsHint(rows[0], openedSettings: true))
        XCTAssertFalse(AccessChecklist.showsHint(rows[1], openedSettings: true), "the helper row has no hint")
    }

    /// HIG review D3: the confirmation names the undo costs of exactly the rows it acts on.
    func testTheUndoCostsAreTheSelectedDeletableRows() {
        func action(_ category: String, _ path: String, root: Bool = false) -> CleanAction {
            CleanAction(
                categoryID: category, categoryName: category, path: path, bytes: 10, isExperimental: false, risk: .low, requiresRoot: root, notes: [])
        }
        let derived = action("derivedData", "/dd/a")
        let plan = CleanPlan(actions: [derived, action("derivedData", "/dd/b", root: true)], skipped: [], warnings: [])
        let list = DeleteList.make(plan: plan, report: sampleSurvey().0)
        XCTAssertEqual(list.undoCosts(selected: ["/dd/a"]), [.regenerable])
        XCTAssertEqual(list.undoCosts(selected: ["/dd/b"]), [], "a root row is never acted on here, so it adds no cost")
        XCTAssertEqual(list.undoCosts(selected: []), [])
    }
}

/// The app's side of commit 1: alerts with a title that says what failed, inline results, the helper sheet's two states,
/// the hint after the trip to Settings, and Show in Finder / Copy Path.
@MainActor
final class R5FeedbackAppTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private let vault = PrivilegedAction.createVaultDirectory(volumeUUID: "U")

    func testEveryAlertNamesWhatFailed() async {
        let t = TempDir()
        let unavailable = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t)
        unavailable.installHelper(then: vault)
        await eventually("the unavailable build is reported") { unavailable.lastError != nil }
        XCTAssertEqual(unavailable.lastError?.title, L10n.tr("app.error.helper.title"))

        let failing = makeModel(SwitchableHelper(.enabled, reply: PrivilegedActionReply(ok: false, message: "nope")), journal: t)
        await failing.perform(.emptyCoreSimulatorDyldCache)
        XCTAssertEqual(failing.lastError, AppError(title: L10n.tr("app.error.emptyDyldCache.title"), message: "nope"))
        XCTAssertNil(failing.feedback, "a failure is never shown as done")

        let refused = makeModel(SwitchableHelper(.enabled, unregisterError: Refusal(description: "busy")), journal: t)
        await refused.uninstallHelper()
        XCTAssertEqual(refused.lastError, AppError(title: L10n.tr("app.error.uninstall.title"), message: "busy"))

        let throwing = makeModel(SwitchableHelper(.enabled), journal: t, clean: { _, _ in throw CleanError("Xcode.app is running") })
        await throwing.refresh()
        await throwing.applyClean(actions: [], useTrash: true)
        XCTAssertEqual(throwing.lastError?.title, L10n.tr("app.error.clean.trash.title"))
        XCTAssertEqual(throwing.lastError?.message, "Xcode.app is running", "a described error gives its description, never a type name")
        XCTAssertFalse(throwing.lastError?.message.contains("CleanError") ?? true)
    }

    func testAnErrorWithoutADescriptionFallsBackToItsText() {
        XCTAssertEqual(AppError(title: "T", error: Refusal(description: "raw")).message, "raw")
        struct Described: LocalizedError {
            var errorDescription: String? { "What failed." }
            var recoverySuggestion: String? { "What to do." }
        }
        XCTAssertEqual(AppError(title: "T", error: Described()).message, "What failed.\n\nWhat to do.")
    }

    func testASuccessIsInlineAndClearsOnTheNextAction() async {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.enabled), journal: t)
        model.refreshPermissions()
        await model.perform(vault)
        XCTAssertEqual(model.feedback?.title, L10n.tr("app.feedback.createVaultDirectory"))
        XCTAssertEqual(model.feedback?.kind, .notice, "a step is left: `vault init` again")
        XCTAssertEqual(model.feedback?.detail.last, vault.afterSuccess(in: L10n.locale))
        XCTAssertNil(model.lastError)
        model.request(.emptyCoreSimulatorDyldCache)
        XCTAssertNil(model.feedback, "the next action clears it")
        await eventually("the cache action ran") { model.feedback != nil }
        XCTAssertEqual(model.feedback?.kind, .success)
        model.dismissFeedback()
        XCTAssertNil(model.feedback)
    }

    func testACleanReportsWhatItDidAndWhatItCouldNot() async {
        let t = TempDir()
        let deleted = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/tmp/dd", bytes: 2_000_000, isExperimental: false, risk: .low,
            requiresRoot: false, notes: [])
        let model = makeModel(
            SwitchableHelper(.enabled), journal: t, survey: sampleSurvey(actions: [deleted]),
            clean: { plan, _ in CleanResult(deleted: plan.actions, failedPairs: [.init(path: "/tmp/other", error: "in use")]) })
        await model.refresh()
        await model.applyClean(actions: [deleted], useTrash: true)
        XCTAssertEqual(model.feedback?.title, L10n.plural("app.feedback.clean.trash", count: 1, ByteCount.format(UInt64(2_000_000))))
        XCTAssertEqual(model.feedback?.detail, [L10n.tr("app.clean.trashNote")], "with the Trash, the space comes when it is emptied")
        XCTAssertEqual(model.lastError?.title, L10n.plural("app.error.clean.partial", count: 1))
        XCTAssertTrue(model.lastError?.message.contains("/tmp/other") ?? false)
        await model.applyClean(actions: [deleted], useTrash: false)
        XCTAssertEqual(model.feedback?.title, L10n.plural("app.feedback.clean.deleted", count: 1, ByteCount.format(UInt64(2_000_000))))
    }

    /// HIG review N12: the wait for approval is the sheet's second state; closing the sheet stops it.
    func testTheHelperSheetHoldsTheWaitAndClosingItStops() async throws {
        let t = TempDir()
        let helper = SwitchableHelper(.awaitingApproval)
        let model = makeModel(helper, journal: t)
        model.refreshPermissions()
        model.request(vault)
        XCTAssertTrue(model.helperSheetIsPresented, "the request")
        model.installHelper(then: model.pendingPrivilegedAction)
        XCTAssertFalse(model.showsHelperSheet)
        XCTAssertNotNil(model.helperProgress)
        XCTAssertTrue(model.helperSheetIsPresented, "the same sheet, waiting")
        model.dismissHelperSheet()
        XCTAssertFalse(model.helperSheetIsPresented)
        XCTAssertNil(model.helperProgress, "closing the sheet stops the wait")
        helper.current = .enabled
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.performed, [], "a stopped wait runs nothing")
        // Install… from Access, with no action: the sheet shows the wait as well.
        let fromAccess = makeModel(SwitchableHelper(.awaitingApproval), journal: t)
        fromAccess.handle(.installHelper)
        XCTAssertTrue(fromAccess.helperSheetIsPresented)
        fromAccess.dismissHelperSheet()
    }

    func testTheHintShowsOnlyAfterTheTripToSettings() throws {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted)
        model.refreshPermissions()
        let row = try XCTUnwrap(model.accessRows.first)
        XCTAssertFalse(model.showsAccessHint(row))
        model.openFullDiskAccessSettings()
        XCTAssertTrue(model.showsAccessHint(row))
        XCTAssertFalse(model.showsAccessHint(model.accessRows[1]))
    }

    /// Safety LOW-3: the context menu and ⌘⌫ confirm exactly the rows given, and only when Delete Selected… would delete one.
    func testTheContextMenuConfirmsOnlyDeletableRows() async {
        let t = TempDir()
        func action(_ path: String, root: Bool) -> CleanAction {
            CleanAction(
                categoryID: "derivedData", categoryName: "DerivedData", path: path, bytes: 1, isExperimental: false, risk: .low, requiresRoot: root,
                notes: [])
        }
        let actions = [action("/dd/a", root: false), action("/dd/r", root: true)]
        let model = makeModel(SwitchableHelper(.enabled), journal: t, survey: sampleSurvey(actions: actions))
        XCTAssertNil(model.deletionToConfirm(["/dd/a"]), "no list before the scan")
        await model.refresh()
        XCTAssertEqual(model.deletionToConfirm(["/dd/a", "/dd/r"]), ["/dd/a", "/dd/r"], "the rows given; the count is still the deletable ones")
        XCTAssertNil(model.deletionToConfirm(["/dd/r"]), "a root row alone opens no confirmation")
        XCTAssertNil(model.deletionToConfirm([]))
        XCTAssertNil(model.deletionToConfirm(["/not/listed"]))
    }

    func testShowInFinderAndCopyPathTakeTheSelection() {
        let t = TempDir()
        let revealed = CopiedStrings()
        let copied = CopiedStrings()
        let journalURL = URL(fileURLWithPath: t.path + "/j.jsonl")
        let model = AppModel(
            environment: AppEnvironment(
                survey: { sampleSurvey() }, fullDiskAccess: { .granted }, helper: SwitchableHelper(.enabled), approvalFlow: { HelperApprovalFlow(helper: $0) },
                runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL)) }, clean: { _, _ in CleanResult(deleted: [], failedPairs: []) },
                open: { _ in }, copy: { copied.strings.append($0) }, reveal: { revealed.strings += $0 }))
        model.showInFinder(["/b", "/a"])
        XCTAssertEqual(revealed.strings, ["/a", "/b"])
        model.copyPaths(["/b", "/a"])
        XCTAssertEqual(copied.strings, ["/a\n/b"])
        model.showInFinder([])
        model.copyPaths([])
        XCTAssertEqual(revealed.strings.count, 2, "nothing selected, nothing revealed")
        XCTAssertEqual(copied.strings.count, 1)
    }

    /// HIG review D2, D3: the confirmation names each cost present, where the deletion is recorded and, with the Trash, when
    /// the space comes back; it never claims "rebuilt automatically" for a selection with nothing regenerable.
    func testTheDeleteConfirmationFollowsTheSelection() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let regenerable = AppText.deleteConfirmation(costs: [.regenerable], useTrash: false)
        XCTAssertTrue(regenerable.contains(L10n.tr("app.clean.confirm.regenerable")))
        XCTAssertTrue(regenerable.contains(L10n.tr("app.clean.confirm.history")))
        XCTAssertFalse(regenerable.contains(L10n.tr("app.clean.trashNote")))
        let lossy = AppText.deleteConfirmation(costs: [.redownloadable, .userRecreatable], useTrash: true)
        XCTAssertFalse(lossy.contains(L10n.tr("app.clean.confirm.regenerable")))
        XCTAssertTrue(lossy.contains(L10n.tr("app.clean.confirm.userRecreatable")))
        XCTAssertTrue(lossy.contains(L10n.tr("app.clean.trashNote")))
        // Safety LOW-1: non-regenerable data gets its own line, never "you recreate them yourself".
        let lost = AppText.deleteConfirmation(costs: [.nonRegenerable], useTrash: false)
        XCTAssertTrue(lost.contains(L10n.tr("app.clean.confirm.nonRegenerable")))
        XCTAssertFalse(lost.contains(L10n.tr("app.clean.confirm.userRecreatable")))
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for action in [PrivilegedAction.createVaultDirectory(volumeUUID: "U"), .emptyCoreSimulatorDyldCache] {
                for text in [
                    AppText.privilegedButton(action), AppText.privilegedConfirmTitle(action), AppText.privilegedDone(action), AppText.privilegedFailed(action),
                ] {
                    XCTAssertFalse(text.isEmpty || text.hasPrefix("app."), "\(locale): \(text)")
                }
            }
            if locale == "en" { XCTAssertTrue(AppText.privilegedButton(.emptyCoreSimulatorDyldCache).contains("Experimental"), "rule 10") }
            for verdict in DriveRow.VaultVerdict.allCases { XCTAssertFalse(AppText.vaultVerdict(verdict).hasPrefix("app."), "\(locale) \(verdict)") }
        }
    }
}
