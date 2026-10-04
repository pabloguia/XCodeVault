import Foundation
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Scripted operations for the Run sheet: previews answer what the test set, runs emit the test's lines and return its
/// result, and nothing outside the process is touched — no ditto, simctl, xcodebuild or defaults, no panel. Every
/// property is behind the lock: the runs read them on other threads.
final class ScriptedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var _previews: [(OperationKind, OperationInputs)] = []
    private var _removals: [Bool] = []
    private var _restores: [(XcodeLocations.Key, String?)] = []
    private var _runs = 0
    private var _measures = 0
    private var _preview: @Sendable (OperationKind, OperationInputs) -> OperationPreview = { _, _ in OperationPreview() }
    private var _lines: [LogLine] = []
    private var _result: Result<OperationResult, Refusal> = .success(.exported)
    private var _removeResult: @Sendable (MigrationOutcome) -> Result<MigrationOutcome, Refusal> = { o in
        var r = o
        r.sourceRemoved = true
        return .success(r)
    }
    private var _measured: UInt64?
    private var _folder: String?
    private var _holds = false
    private var _holdsPreview = false
    private var _logDirectory: String?
    private let gate = DispatchSemaphore(value: 0)
    private let previewGate = DispatchSemaphore(value: 0)

    private func get<T>(_ k: KeyPath<ScriptedOperations, T>) -> T { lock.withLock { self[keyPath: k] } }
    var preview: @Sendable (OperationKind, OperationInputs) -> OperationPreview {
        get { lock.withLock { _preview } }
        set { lock.withLock { _preview = newValue } }
    }
    var lines: [LogLine] {
        get { lock.withLock { _lines } }
        set { lock.withLock { _lines = newValue } }
    }
    var result: Result<OperationResult, Refusal> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var removeResult: @Sendable (MigrationOutcome) -> Result<MigrationOutcome, Refusal> {
        get { lock.withLock { _removeResult } }
        set { lock.withLock { _removeResult = newValue } }
    }
    var measured: UInt64? {
        get { lock.withLock { _measured } }
        set { lock.withLock { _measured = newValue } }
    }
    var folder: String? {
        get { lock.withLock { _folder } }
        set { lock.withLock { _folder = newValue } }
    }
    /// While set, a run waits for `release()` — or for its commands to be stopped — before it returns.
    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }
    /// While set, a preview waits for `releasePreview()`.
    var holdsPreview: Bool {
        get { lock.withLock { _holdsPreview } }
        set { lock.withLock { _holdsPreview = newValue } }
    }
    /// Where the full logs go; nil keeps none.
    var logDirectory: String? {
        get { lock.withLock { _logDirectory } }
        set { lock.withLock { _logDirectory = newValue } }
    }

    var previews: [(OperationKind, OperationInputs)] { lock.withLock { _previews } }
    var removals: [Bool] { lock.withLock { _removals } }
    var restores: [(XcodeLocations.Key, String?)] { lock.withLock { _restores } }
    var runs: Int { lock.withLock { _runs } }
    var measures: Int { lock.withLock { _measures } }
    func release() { gate.signal() }
    func releasePreview() { previewGate.signal() }

    var services: OperationServices {
        OperationServices(
            preview: { kind, inputs in
                self.lock.withLock { self._previews.append((kind, inputs)) }
                if self.holdsPreview { self.previewGate.wait() }
                return self.preview(kind, inputs)
            },
            run: { _, children, observer in
                self.lock.withLock { self._runs += 1 }
                for l in self.lines { observer(l) }
                if self.holds {
                    // Released by the test, or stopped as `ChildProcesses.stopAndWait` stops a real command.
                    while self.gate.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
                        if children.isStopped { throw Refusal(description: "terminated: exit 15") }
                    }
                }
                return try self.result.get()
            },
            removeSource: { outcome, confirmed, observer in
                self.lock.withLock { self._removals.append(confirmed) }
                observer(LogLine(.command, "rename aside"))
                return try self.removeResult(outcome).get()
            },
            restoreLocation: { key, previous, _, observer in
                self.lock.withLock { self._restores.append((key, previous)) }
                observer(LogLine(.command, "/usr/bin/defaults \(previous == nil ? "delete" : "write") com.apple.dt.Xcode \(key.defaultsKey)"))
            },
            measure: { _ in
                self.lock.withLock {
                    self._measures += 1
                    return self._measured
                }
            },
            chooseFolder: { _ in self.folder },
            pollInterval: .milliseconds(1),
            logFile: { name in
                guard let dir = self.logDirectory else { return nil }
                return OperationLogFile.create(name: name, in: URL(fileURLWithPath: dir))
            })
    }
}

/// A survey a test changes between scans.
final class SurveyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _survey: AppModel.Survey
    init(_ survey: AppModel.Survey) { _survey = survey }
    var survey: AppModel.Survey {
        get { lock.withLock { _survey } }
        set { lock.withLock { _survey = newValue } }
    }
}

/// Counts the scans the model ran.
final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    var n: Int { lock.withLock { _n } }
    func bump() { lock.withLock { _n += 1 } }
}

@MainActor
final class R3RunInAppTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func row(_ categoryID: String, _ bucket: SavingsBucket, name: String = "Archives", bytes: UInt64 = 18_000_000_000) -> SavingsPlanRow {
        SavingsPlanRow(
            categoryID: categoryID, categoryName: name, bytes: bytes,
            option: SavingsOption(bucket: bucket, isExperimental: true, appliesToExistingData: true, losesUserData: false),
            command: "xcodevaultctl x", itemCount: 1, actsImmediately: false, noteIDs: [])
    }

    private func vaultCheck(_ uuid: String = "U-1", name: String = "PABLO") -> VaultVolumeCheck {
        VaultVolumeCheck(
            volume: VaultVolume(volumeUUID: uuid, volumeName: name, lastMountPoint: "/Volumes/\(name)", registeredAt: Date(), sentinelID: "s"),
            state: .verified, currentMountPoint: "/Volumes/\(name)", shadowBytes: nil, detail: "")
    }

    nonisolated static func plan() -> MigrationPlan {
        MigrationPlan(
            operationID: "OP-1", direction: .externalize, categoryID: "archives", source: "/Users/t/Library/Developer/Xcode/Archives",
            destination: "/Volumes/PABLO/XCodeVault/archives/Archives", vaultUUID: "U-1", sourceBytes: 18_000_000_000, sourceFiles: 10,
            deepVerify: true, warnings: [])
    }

    nonisolated static func outcome() -> MigrationOutcome {
        MigrationOutcome(
            plan: Self.plan(),
            verification: TreeVerifier.Report(
                sourceFiles: 10, destinationFiles: 10, sourceBytes: 1, destinationBytes: 1, hashedFiles: 10, mismatches: [], truncated: false),
            sourceRemoved: false)
    }

    private func model(
        _ ops: ScriptedOperations, survey: AppModel.Survey = sampleSurvey(), scans: ScanCounter = ScanCounter(), copied: CopiedStrings = CopiedStrings(),
        box: SurveyBox? = nil
    )
        -> AppModel
    {
        let t = TempDir()
        let url = URL(fileURLWithPath: t.path + "/j.jsonl")
        let helper = SwitchableHelper(.unavailableInThisBuild)
        return AppModel(
            environment: AppEnvironment(
                survey: {
                    scans.bump()
                    return box?.survey ?? survey
                }, fullDiskAccess: { .granted }, helper: helper, approvalFlow: { HelperApprovalFlow(helper: $0) },
                runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { copied.strings.append($0) },
                operations: ops.services))
    }

    // MARK: - Decisions

    func testExactlySixRowsRunAndSimulatorDevicesStayCopyOnly() {
        XCTAssertEqual(OperationKind.forRow(row("archives", .parkExternally)), .externalizeArchives)
        XCTAssertEqual(OperationKind.forRow(row("simulatorRuntimeAssets", .parkExternally)), .offloadRuntime)
        XCTAssertEqual(OperationKind.forRow(row("derivedData", .runFromExternal)), .setDerivedData)
        XCTAssertEqual(OperationKind.forRow(row("archives", .runFromExternal)), .setArchives)
        XCTAssertEqual(OperationKind.forRow(row("runtimeLibrary", .runFromExternal)), .exportRuntime)
        XCTAssertEqual(OperationKind.forRow(row("simulatorRuntimeAssets", .deleteAndRegenerate)), .deleteRuntime)
        XCTAssertNil(OperationKind.forRow(row("simulatorDevices", .deleteAndRegenerate)), "devices stay copy-only this round")
        XCTAssertNil(OperationKind.forRow(row("derivedData", .deleteAndRegenerate)), "clean rows are the Delete table's")
        XCTAssertNil(OperationKind.forRow(row("archives", .keepLocal)))
        XCTAssertTrue(OperationKind.offloadRuntime.deletesData && OperationKind.deleteRuntime.deletesData)
        XCTAssertFalse(OperationKind.externalizeArchives.deletesData, "the copy keeps its source (rule 4)")
    }

    func testTheExportPlatformComesFromTheRuntimeIdentifier() {
        func rt(_ rid: String?) -> SimulatorRuntime { SimulatorRuntime(identifier: "X", runtimeIdentifier: rid) }
        XCTAssertEqual(OperationKind.exportPlatform(for: rt("com.apple.CoreSimulator.SimRuntime.iOS-26-5")), "iOS")
        XCTAssertEqual(OperationKind.exportPlatform(for: rt("com.apple.CoreSimulator.SimRuntime.xrOS-2-5")), "visionOS")
        XCTAssertEqual(OperationKind.exportPlatform(for: rt("com.apple.CoreSimulator.SimRuntime.watchOS-11-0")), "watchOS")
        XCTAssertNil(OperationKind.exportPlatform(for: rt("com.apple.CoreSimulator.SimRuntime.macOS-15-0")))
        XCTAssertNil(OperationKind.exportPlatform(for: rt(nil)))
    }

    func testMissingChoicesBlockBeforeCoreIsAsked() {
        XCTAssertEqual(AppModel.inputBlockers(.externalizeArchives, OperationInputs()), [.chooseVault])
        XCTAssertEqual(AppModel.inputBlockers(.offloadRuntime, OperationInputs()), [.chooseRuntime, .chooseFolder])
        XCTAssertEqual(AppModel.inputBlockers(.deleteRuntime, OperationInputs(runtimeID: "R")), [])
        XCTAssertEqual(AppModel.inputBlockers(.setDerivedData, OperationInputs(folder: "/x")), [])
    }

    func testBlockersAreLocalizedAndCoreSentencesAreShownAsGiven() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(AppModel.blockerText(.core("Xcode.app is running.")), "Xcode.app is running.")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for b in [OperationBlocker.chooseVault, .chooseFolder, .chooseRuntime, .acknowledgeTests] {
                XCTAssertFalse(AppModel.blockerText(b).hasPrefix("app."), "\(b) in \(locale)")
            }
        }
    }

    func testTheTestsRiskIsTheCheckboxNotTheCLIFlag() {
        struct E: Error {}
        let passes = LiveOperations.locationPreflight(acknowledged: false) { _ in ["w"] }
        XCTAssertEqual(passes.warnings, ["w"])
        XCTAssertEqual(passes.blockers, [])
        let needsAck = LiveOperations.locationPreflight(acknowledged: false) { ack in
            guard ack else { throw RuntimeOperationError("Re-run with --i-understand-tests-may-fail") }
            return ["E2"]
        }
        XCTAssertEqual(needsAck.blockers, [.acknowledgeTests])
        XCTAssertEqual(needsAck.warnings, ["E2"], "the risk is still said")
        let refused = LiveOperations.locationPreflight(acknowledged: false) { _ in throw RuntimeOperationError("Xcode.app is running") }
        XCTAssertEqual(refused.blockers, [.core("Xcode.app is running")], "a refusal the checkbox cannot lift is Core's")
        let acked = LiveOperations.locationPreflight(acknowledged: true) { _ in throw RuntimeOperationError("not writable") }
        XCTAssertEqual(acked.blockers, [.core("not writable")])
    }

    func testExportFirstIsOfferedOnlyWhenTheLibraryWasReadAndHasNoInstaller() {
        let rt = SimulatorRuntime(identifier: "R", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", build: "23F77")
        XCTAssertFalse(LiveOperations.installerMissing(runtime: rt, library: nil), "an unreadable library is not a missing installer")
        XCTAssertFalse(LiveOperations.installerMissing(runtime: nil, library: []))
        XCTAssertTrue(LiveOperations.installerMissing(runtime: rt, library: []))
    }

    func testTheSecondStepFollowsTheResult() {
        XCTAssertEqual(AppModel.secondStep(after: .copied(Self.outcome())), .removeOriginal)
        var removed = Self.outcome()
        removed.sourceRemoved = true
        XCTAssertEqual(AppModel.secondStep(after: .copied(removed)), .none)
        var restore = Self.outcome()
        restore.plan.direction = .restore
        XCTAssertEqual(AppModel.secondStep(after: .copied(restore)), .none, "removing a source applies to externalizations only")
        XCTAssertEqual(AppModel.secondStep(after: .locationApplied(.derivedData, previous: nil)), .undo)
        XCTAssertEqual(AppModel.secondStep(after: .offloaded), .none)
        XCTAssertEqual(AppModel.secondStep(after: .runtimeDeleted), .none)
    }

    func testTheBannerNamesTheMigrationAndItsRecoveryCommands() {
        func e(_ id: String, _ seq: Int, _ state: JournalEntry.State, _ summary: String, _ phase: String) -> JournalEntry {
            JournalEntry(
                id: id, sequence: seq, timestamp: Date(), kind: .migration, state: state, summary: summary, paths: [], bytes: nil,
                detail: ["phase": phase], toolVersion: "t")
        }
        let entries = [e("A", 1, .planned, "externalize archives: /a → /b", "PLAN"), e("A", 2, .started, "COPY", "COPY")]
        XCTAssertEqual(
            AppModel.interruptedBanner(entries, running: []),
            [
                InterruptedMigration(
                    id: "A", summary: "externalize archives: /a → /b",
                    commands: ["xcodevaultctl migration status", "xcodevaultctl migration abort A"])
            ])
        XCTAssertEqual(AppModel.interruptedBanner(entries, running: ["A"]), [], "the operation the sheet runs is not interrupted")
    }

    // MARK: - The sheet, end to end over fakes

    func testRunOpensOnTheReviewWithTheOnlyUsableVault() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(source: "/a", destination: "/b", bytes: 5, prepared: .migration(Self.plan())) }
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        XCTAssertTrue(m.canRun(row("archives", .parkExternally)))
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.operationSheet?.preview != nil && m.operationSheet?.isPreviewing == false }
        XCTAssertEqual(m.operationSheet?.inputs.vaultUUID, "U-1")
        XCTAssertEqual(ops.previews.first?.0, .externalizeArchives)
        XCTAssertTrue(m.canConfirmOperation)
        XCTAssertEqual(ops.runs, 0, "a review runs nothing")
    }

    func testTwoVaultsMeanTheUserChooses() async {
        let ops = ScriptedOperations()
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck("U-1"), vaultCheck("U-2", name: "OTHER")]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the review") { m.operationSheet?.preview != nil }
        XCTAssertNil(m.operationSheet?.inputs.vaultUUID)
        XCTAssertEqual(m.operationBlockers, [.chooseVault])
        XCTAssertFalse(m.canConfirmOperation)
        XCTAssertTrue(ops.previews.isEmpty, "Core is not asked until the choices are made")
    }

    func testABlockerDisablesTheConfirmation() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(blockers: [.core("Vault has 1 GB free.")], prepared: .migration(Self.plan())) }
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.operationSheet?.preview != nil && m.operationSheet?.isPreviewing == false }
        XCTAssertFalse(m.canConfirmOperation)
        await m.runOperation()
        XCTAssertEqual(ops.runs, 0, "a blocked operation never runs")
    }

    func testTheCopyStreamsItsLogVerifiesAndOffersTheSeparateRemoval() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.lines = [LogLine(.command, "/usr/bin/ditto /a /b"), LogLine(.exit, "0")]
        ops.result = .success(.copied(Self.outcome()))
        let scans = ScanCounter()
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]), scans: scans)
        await m.refresh()
        let before = scans.n
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        await m.runOperation()
        let s = try? XCTUnwrap(m.operationSheet)
        XCTAssertEqual(s?.phase, .succeeded(.removeOriginal))
        XCTAssertEqual(s?.stage, .done)
        XCTAssertEqual(
            s?.log.lines.map(\.rendered), ["== copying", "$ /usr/bin/ditto /a /b", "[exit 0]", "== verifying", "== done"],
            "the command, its exit, and the stages in order")
        XCTAssertEqual(s?.secondStep, .removeOriginal)
        XCTAssertGreaterThan(scans.n, before, "a run is followed by a rescan")

        // The removal is a second, explicit step behind the non-regenerable checkbox (rules 4 and 5).
        XCTAssertTrue(m.removalNeedsConfirmation, "Archives are non-regenerable")
        XCTAssertFalse(m.canRemoveOriginal)
        await m.removeOriginal()
        XCTAssertEqual(ops.removals, [], "nothing is removed without the checkbox")
        m.operationSheet?.confirmRemoval = true
        XCTAssertTrue(m.canRemoveOriginal)
        await m.removeOriginal()
        XCTAssertEqual(ops.removals, [true], "the checkbox's value is what Core is given")
        XCTAssertEqual(m.operationSheet?.secondStep, .originalRemoved)
        XCTAssertFalse(m.canRemoveOriginal, "once removed, never offered again")
    }

    func testAFailedRemovalCanBeTriedAgainAndCoreDecidesAgain() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.result = .success(.copied(Self.outcome()))
        ops.removeResult = { _ in .failure(Refusal(description: "Xcode.app is running")) }
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        await m.runOperation()
        m.operationSheet?.confirmRemoval = true
        await m.removeOriginal()
        XCTAssertEqual(m.operationSheet?.secondStep, .removeFailed("Xcode.app is running"))
        XCTAssertTrue(m.canRemoveOriginal)
    }

    func testAFailedRunSaysSoAndOffersNoSecondStep() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.lines = [LogLine(.command, "/usr/bin/ditto /a /b"), LogLine(.stderr, "No space left"), LogLine(.exit, "1")]
        ops.result = .failure(Refusal(description: "ditto exited 1"))
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        await m.runOperation()
        XCTAssertEqual(m.operationSheet?.phase, .failed("ditto exited 1"))
        XCTAssertEqual(m.operationSheet?.stage, .failed, "a copy that failed never shows verifying")
        XCTAssertEqual(m.operationSheet?.secondStep, OperationSheetState.SecondStep.none)
        XCTAssertFalse(m.canRemoveOriginal)
    }

    func testOneOperationAtATimeAndQuittingAsksWhileItRuns() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.lines = [LogLine(.command, "/usr/bin/ditto /a /b")]
        ops.result = .success(.copied(Self.outcome()))
        ops.holds = true
        ops.measured = 9_000_000_000
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        XCTAssertFalse(m.quitNeedsConfirmation)
        let running = Task { await m.runOperation() }
        await eventually("running") { m.operationSheet?.phase == .running && m.operationSheet?.progressBytes != nil }
        XCTAssertTrue(m.isOperationRunning)
        XCTAssertTrue(m.quitNeedsConfirmation)
        XCTAssertEqual(m.operationProgressFraction, 0.5, "the vault copy measured against the plan's size")
        XCTAssertEqual(m.runningJournalIDs, ["OP-1"])
        let sheet = m.operationSheet?.id
        m.openRun(row("derivedData", .runFromExternal))
        XCTAssertEqual(m.operationSheet?.id, sheet, "a second operation cannot start")
        m.closeOperationSheet()
        XCTAssertNotNil(m.operationSheet, "the sheet cannot be closed while it runs")
        m.showHistoryFromOperation()
        XCTAssertNotNil(m.operationSheet)
        ops.release()
        await running.value
        XCTAssertFalse(m.quitNeedsConfirmation)
        XCTAssertNil(m.operationProgressFraction, "done is not copying")
        m.showHistoryFromOperation()
        XCTAssertNil(m.operationSheet)
        XCTAssertEqual(m.section, .history)
    }

    /// Review L4: **Undo** puts back the folder Xcode used before, when it had one, and says so; otherwise it resets to
    /// the default, and says that.
    func testUndoRestoresThePreviousFolderOrResetsToTheDefault() async {
        for previous in ["/Users/t/OldDD", nil] as [String?] {
            let ops = ScriptedOperations()
            ops.folder = "/Volumes/PABLO/DD"
            ops.preview = { _, inputs in
                OperationPreview(
                    source: previous, destination: inputs.folder,
                    prepared: .location(XcodeLocations.Change(key: .derivedData, newValue: inputs.folder), acknowledgeTests: true))
            }
            ops.result = .success(.locationApplied(.derivedData, previous: previous))
            let m = model(ops)
            await m.refresh()
            m.openRun(row("derivedData", .runFromExternal))
            await eventually("the review") { m.operationSheet?.preview != nil }
            XCTAssertEqual(m.operationBlockers, [.chooseFolder])
            await m.chooseOperationFolder()
            await eventually("the preview") { m.canConfirmOperation }
            XCTAssertEqual(ops.previews.last?.1.folder, "/Volumes/PABLO/DD", "the panel's folder reaches the preview")
            L10n.configure(override: "en", environment: [:], preferred: [])
            let undoText = OperationText.undo(.setDerivedData, current: m.operationSheet?.preview?.source)
            await m.runOperation()
            XCTAssertEqual(m.operationSheet?.secondStep, .undo)
            let label = OperationText.undoAction(restoring: m.undoRestores ?? nil)
            await m.undoLocation()
            XCTAssertEqual(ops.restores.map(\.0), [.derivedData])
            XCTAssertEqual(ops.restores.first?.1, previous, "the previous folder is what Core is asked to put back")
            XCTAssertEqual(m.operationSheet?.secondStep, .undone)
            if let previous {
                XCTAssertTrue(label.contains(previous), label)
                XCTAssertTrue(undoText.contains(previous), undoText)
                XCTAssertTrue(m.operationSheet?.log.text.contains("defaults write") == true)
            } else {
                XCTAssertEqual(label, "Undo: Reset to Default")
                XCTAssertTrue(undoText.contains("default"), undoText)
                XCTAssertTrue(m.operationSheet?.log.text.contains("defaults delete") == true)
            }
        }
    }

    func testExportInstallerFirstRunsTheExportThenReturnsToOffload() async {
        let ops = ScriptedOperations()
        ops.preview = { kind, inputs in
            kind == .offloadRuntime
                ? OperationPreview(blockers: [.core("No installer")], installerMissing: true)
                : OperationPreview(destination: inputs.folder, prepared: .deleteRuntime(identifier: "unused", Self.xcode(), Self.host()))
        }
        ops.result = .success(.exported)
        var survey = sampleSurvey()
        survey.0.runtimes = [
            SimulatorRuntime(identifier: "R", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", sizeBytes: 8)
        ]
        let m = model(ops, survey: survey)
        await m.refresh()
        m.openRun(row("simulatorRuntimeAssets", .parkExternally, name: "Simulator runtimes"))
        m.updateOperationInputs {
            $0.runtimeID = "R"
            $0.folder = "/Volumes/PABLO/Runtimes"
        }
        await eventually("the offload preview") { m.operationSheet?.preview?.installerMissing == true }
        m.exportInstallerFirst()
        XCTAssertEqual(m.operationSheet?.kind, .exportRuntime)
        XCTAssertEqual(m.operationSheet?.inputs, OperationInputs(folder: "/Volumes/PABLO/Runtimes", platform: "iOS", buildVersion: "26.5"))
        await eventually("the export preview") { m.canConfirmOperation }
        await m.runOperation()
        await eventually("back to offload") { m.operationSheet?.kind == .offloadRuntime && m.operationSheet?.preview != nil }
        XCTAssertEqual(m.operationSheet?.phase, .review)
        XCTAssertEqual(m.operationSheet?.inputs.runtimeID, "R")
        XCTAssertTrue(m.operationSheet?.exportedFirst == true)
    }

    func testCopyLogCopiesTheKeptLines() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .deleteRuntime(identifier: "R", Self.xcode(), Self.host())) }
        ops.lines = [LogLine(.command, "/usr/bin/xcrun simctl runtime delete R"), LogLine(.exit, "0")]
        ops.result = .success(.runtimeDeleted)
        let copied = CopiedStrings()
        let m = model(ops, copied: copied)
        await m.refresh()
        m.openRun(row("simulatorRuntimeAssets", .deleteAndRegenerate, name: "Simulator runtimes"))
        m.updateOperationInputs { $0.runtimeID = "R" }
        await eventually("the preview") { m.canConfirmOperation }
        await m.runOperation()
        m.copyOperationLog()
        XCTAssertEqual(copied.strings, ["== deleting\n$ /usr/bin/xcrun simctl runtime delete R\n[exit 0]\n== done"])
    }

    func testTheInterruptedBannerComesFromTheScannedJournal() async {
        var survey = sampleSurvey()
        survey.4 = [
            JournalEntry(
                id: "M", sequence: 1, timestamp: Date(), kind: .migration, state: .started, summary: "COPY", paths: [], bytes: nil,
                detail: ["phase": "COPY", "direction": "externalize"], toolVersion: "t")
        ]
        let m = model(ScriptedOperations(), survey: survey)
        await m.refresh()
        XCTAssertEqual(m.interruptedMigrations.map(\.id), ["M"])
        XCTAssertEqual(m.interruptedMigrations.first?.commands.last, "xcodevaultctl migration abort M")
    }

    nonisolated static func xcode() -> XcodeInstallation {
        XcodeInstallation(
            path: "/Applications/Xcode.app", developerDirectory: "/Applications/Xcode.app/Contents/Developer", version: "26.5", build: "17F42",
            isSelected: true, capabilities: XcodeCapabilities())
    }

    nonisolated static func host() -> HostEnvironment {
        HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "x", architecture: "x86_64", homeDirectory: "/tmp", dataVolumeFreeBytes: 1 << 40,
            dataVolumeTotalBytes: 1 << 41, userName: "t", isRoot: false)
    }

    // MARK: - Review round 1

    /// Safety M1: what Quit may do, per stage.
    func testTheQuitChoiceDependsOnTheStage() {
        XCTAssertEqual(AppModel.quitChoice(running: false, stage: .copying), .quitNow)
        for stage in [OperationStage.copying, .verifying, .removing] {
            XCTAssertEqual(AppModel.quitChoice(running: true, stage: stage), .keepRunningOnly(.migration), "\(stage)")
        }
        XCTAssertEqual(AppModel.quitChoice(running: true, stage: .exporting), .keepRunningOnly(.export))
        for stage in [OperationStage.deleting, .applying] {
            XCTAssertEqual(AppModel.quitChoice(running: true, stage: stage), .stopThenQuit, "\(stage)")
        }
    }

    func testACopyCannotBeStoppedForQuitAndARuntimeDeletionIsStoppedAndRecorded() async {
        // The copy: only Keep Running, and asking to stop for quit changes nothing.
        let copy = ScriptedOperations()
        copy.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        copy.lines = [LogLine(.command, "/usr/bin/ditto /a /b")]
        copy.result = .success(.copied(Self.outcome()))
        copy.holds = true
        let c = model(copy, survey: sampleSurvey(checks: [vaultCheck()]))
        await c.refresh()
        c.openRun(row("archives", .parkExternally))
        await eventually("the preview") { c.canConfirmOperation }
        let copying = Task { await c.runOperation() }
        await eventually("copying") { c.operationSheet?.phase == .running }
        XCTAssertEqual(c.quitChoice, .keepRunningOnly(.migration))
        let copyStopped = await c.stopOperationForQuit(timeout: .milliseconds(50))
        XCTAssertFalse(copyStopped, "the quit is cancelled")
        XCTAssertTrue(c.isOperationRunning, "a copy is never stopped for quit")
        copy.release()
        await copying.value

        // The deletion: Stop and Quit terminates its command and waits until the operation recorded how it ended.
        let delete = ScriptedOperations()
        delete.preview = { _, _ in OperationPreview(prepared: .deleteRuntime(identifier: "R", Self.xcode(), Self.host())) }
        delete.result = .success(.runtimeDeleted)
        delete.holds = true
        let d = model(delete)
        await d.refresh()
        d.openRun(row("simulatorRuntimeAssets", .deleteAndRegenerate, name: "Simulator runtimes"))
        d.updateOperationInputs { $0.runtimeID = "R" }
        await eventually("the preview") { d.canConfirmOperation }
        let deleting = Task { await d.runOperation() }
        await eventually("deleting") { d.operationSheet?.phase == .running && d.activeChildren != nil }
        XCTAssertEqual(d.quitChoice, .stopThenQuit)
        let deleteStopped = await d.stopOperationForQuit()
        XCTAssertTrue(deleteStopped)
        XCTAssertFalse(d.isOperationRunning, "quitting waits until the operation ended")
        XCTAssertEqual(d.operationSheet?.phase, .failed("terminated: exit 15"))
        XCTAssertEqual(d.quitChoice, .quitNow)
        await deleting.value
    }

    /// Safety L2: a second click on Run, or on Remove Original, never starts a second operation.
    func testConcurrentRunsAndRemovalsStartOnce() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.result = .success(.copied(Self.outcome()))
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        async let first: Void = m.runOperation()
        async let second: Void = m.runOperation()
        _ = await (first, second)
        XCTAssertEqual(ops.runs, 1)
        m.operationSheet?.confirmRemoval = true
        async let r1: Void = m.removeOriginal()
        async let r2: Void = m.removeOriginal()
        _ = await (r1, r2)
        XCTAssertEqual(ops.removals, [true])
    }

    /// Review I2: clearing a choice while a preview is in flight leaves the blocker, not a spinner.
    func testClearingAChoiceDuringAPreviewEndsTheSpinner() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.holdsPreview = true
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("previewing") { m.operationSheet?.isPreviewing == true }
        m.updateOperationInputs { $0.vaultUUID = nil }
        await eventually("the blocker") { m.operationBlockers == [.chooseVault] }
        ops.releasePreview()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(m.operationSheet?.isPreviewing, false)
        XCTAssertEqual(m.operationBlockers, [.chooseVault], "the stale preview was dropped")
    }

    /// Review I3: Check Again, and a scan while reviewing, run the review again; a vault gone from the scan is unchosen.
    func testTheReviewIsCheckedAgainAndAfterAScan() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(blockers: [.core("Xcode.app is running")]) }
        let box = SurveyBox(sampleSurvey(checks: [vaultCheck()]))
        let m = model(ops, box: box)
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the review") { m.operationSheet?.preview != nil && m.operationSheet?.isPreviewing == false }
        XCTAssertEqual(ops.previews.count, 1)
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        m.checkOperationAgain()
        await eventually("checked again") { m.canConfirmOperation }
        XCTAssertEqual(ops.previews.count, 2)
        box.survey = sampleSurvey(checks: [])
        await m.refresh()
        await eventually("the vault is unchosen") { m.operationSheet?.inputs.vaultUUID == nil && m.operationBlockers == [.chooseVault] }
    }

    /// Review I4: a failed copy whose partial copy the journal says may be on the vault shows `migration abort <id>`, and
    /// the banner lists failed migrations with a leftover too.
    func testAFailedCopyNamesTheAbortCommandForItsPartialCopy() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.result = .failure(Refusal(description: "ditto exited 1"))
        var survey = sampleSurvey(checks: [vaultCheck()])
        survey.4 = [
            JournalEntry(
                id: "OP-1", sequence: 1, timestamp: Date(), kind: .migration, state: .started, summary: "COPY", paths: [], bytes: nil,
                detail: ["phase": "COPY"], toolVersion: "t")
        ]
        let box = SurveyBox(sampleSurvey(checks: [vaultCheck()]))
        let m = model(ops, box: box)
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        box.survey = survey
        await m.runOperation()
        XCTAssertEqual(m.failedCopyLeftoverID, "OP-1")

        func e(_ id: String, _ seq: Int, _ state: JournalEntry.State, _ phase: String, paths: [String] = []) -> JournalEntry {
            JournalEntry(
                id: id, sequence: seq, timestamp: Date(), kind: .migration, state: state, summary: "plan \(id)", paths: paths, bytes: nil,
                detail: ["phase": phase], toolVersion: "t")
        }
        let entries = [e("F", 1, .planned, "PLAN", paths: ["/s", "/d"]), e("F", 2, .failed, "FAILED")]
        XCTAssertEqual(
            AppModel.interruptedBanner(entries, running: [], mayBePresent: { _ in true }),
            [InterruptedMigration(id: "F", summary: "plan F", commands: ["xcodevaultctl migration status", "xcodevaultctl migration abort F"])])
        XCTAssertEqual(AppModel.interruptedBanner(entries, running: [], mayBePresent: { _ in false }), [], "no copy left, nothing to say")
    }

    /// Review I5: the full log's file is still named when the operation has ended, and Copy Log names it.
    func testTheFullLogIsStillNamedAfterTheOperation() async {
        let t = TempDir()
        let ops = ScriptedOperations()
        ops.logDirectory = t.path
        ops.preview = { _, _ in OperationPreview(prepared: .deleteRuntime(identifier: "R", Self.xcode(), Self.host())) }
        ops.lines = (1...6_000).map { LogLine(.stdout, "l\($0)") }
        ops.result = .success(.runtimeDeleted)
        let copied = CopiedStrings()
        let m = model(ops, copied: copied)
        await m.refresh()
        m.openRun(row("simulatorRuntimeAssets", .deleteAndRegenerate, name: "Simulator runtimes"))
        m.updateOperationInputs { $0.runtimeID = "R" }
        await eventually("the preview") { m.canConfirmOperation }
        await m.runOperation()
        let url = try? XCTUnwrap(m.operationSheet?.logFileURL)
        XCTAssertNotNil(url)
        let whole = (try? String(contentsOf: url ?? URL(fileURLWithPath: "/"), encoding: .utf8)) ?? ""
        XCTAssertTrue(whole.contains("l1\n") && whole.contains("l6000"), "the file has every line")
        m.copyOperationLog()
        XCTAssertTrue(copied.strings.last?.contains(url?.path ?? "?") == true)
    }

    /// Review M3, safety L5: no scan while an operation runs; it rescans when it ends.
    func testNoScanWhileAnOperationRuns() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .deleteRuntime(identifier: "R", Self.xcode(), Self.host())) }
        ops.result = .success(.runtimeDeleted)
        ops.holds = true
        let scans = ScanCounter()
        let m = model(ops, scans: scans)
        await m.refresh()
        m.openRun(row("simulatorRuntimeAssets", .deleteAndRegenerate, name: "Simulator runtimes"))
        m.updateOperationInputs { $0.runtimeID = "R" }
        await eventually("the preview") { m.canConfirmOperation }
        let running = Task { await m.runOperation() }
        await eventually("running") { m.operationSheet?.phase == .running }
        let before = scans.n
        await m.refresh()
        XCTAssertEqual(scans.n, before, "a rescan waits")
        ops.release()
        await running.value
        XCTAssertGreaterThan(scans.n, before, "and runs once the operation ended")
    }

    /// Review M5: the copy's measuring stops with the copy.
    func testMeasuringStopsWhenTheCopyEnds() async {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(Self.plan())) }
        ops.result = .success(.copied(Self.outcome()))
        ops.holds = true
        ops.measured = 1
        let m = model(ops, survey: sampleSurvey(checks: [vaultCheck()]))
        await m.refresh()
        m.openRun(row("archives", .parkExternally))
        await eventually("the preview") { m.canConfirmOperation }
        let running = Task { await m.runOperation() }
        await eventually("measured") { ops.measures > 2 }
        ops.release()
        await running.value
        let after = ops.measures
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ops.measures, after)
    }

    /// Review M9 and M10: a failed export offload asked for goes back to offload; the confirm title has no placeholders
    /// before the review.
    func testAFailedExportGoesBackToOffloadAndThePendingTitleIsNeutral() async {
        let ops = ScriptedOperations()
        ops.preview = { kind, inputs in
            kind == .offloadRuntime
                ? OperationPreview(blockers: [.core("No installer")], installerMissing: true)
                : OperationPreview(destination: inputs.folder, prepared: .deleteRuntime(identifier: "unused", Self.xcode(), Self.host()))
        }
        ops.result = .failure(Refusal(description: "xcodebuild exited 70"))
        var survey = sampleSurvey()
        survey.0.runtimes = [
            SimulatorRuntime(identifier: "R", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", sizeBytes: 8)
        ]
        let m = model(ops, survey: survey)
        await m.refresh()
        L10n.configure(override: "en", environment: [:], preferred: [])
        m.openRun(row("simulatorRuntimeAssets", .parkExternally, name: "Simulator runtimes"))
        XCTAssertEqual(m.operationConfirmTitle, "Run")
        m.updateOperationInputs {
            $0.runtimeID = "R"
            $0.folder = "/Volumes/PABLO/Runtimes"
        }
        await eventually("the offload preview") { m.operationSheet?.preview?.installerMissing == true }
        m.exportInstallerFirst()
        await eventually("the export preview") { m.canConfirmOperation }
        await m.runOperation()
        XCTAssertTrue(m.offersBackToOffload)
        m.backToOffload()
        XCTAssertEqual(m.operationSheet?.kind, .offloadRuntime)
        XCTAssertEqual(m.operationSheet?.phase, .review)
        XCTAssertEqual(m.operationSheet?.inputs.runtimeID, "R")
    }

    /// L-C: Stop and Quit can reach only a runtime deletion's or a folder change's commands; a copy and an export get a
    /// runner nothing can stop.
    func testOnlyDeletionsAndFolderChangesGetStoppableCommands() {
        let children = ChildProcesses()
        let x = Self.xcode(), h = Self.host()
        XCTAssertNil(LiveOperations.stoppableChildren(for: .migration(Self.plan()), children))
        XCTAssertNil(LiveOperations.stoppableChildren(for: .export(.init(platform: "iOS", destination: "/x"), x, h), children))
        XCTAssertTrue(LiveOperations.stoppableChildren(for: .deleteRuntime(identifier: "R", x, h), children) === children)
        XCTAssertTrue(
            LiveOperations.stoppableChildren(for: .location(.init(key: .derivedData, newValue: "/x"), acknowledgeTests: true), children) === children)
    }

    /// N4: the review and the button agree when Xcode uses its default.
    func testTheReviewAndTheUndoButtonAgreeOnTheDefault() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertTrue(OperationText.undo(.setDerivedData, current: nil).contains("default"))
        XCTAssertTrue(OperationText.undoAction(restoring: nil).contains("Default"))
        XCTAssertTrue(OperationText.undo(.setArchives, current: "/A").contains("/A"))
        XCTAssertTrue(OperationText.undoAction(restoring: "/A").contains("/A"))
    }

    /// Safety L3: offload and delete wait for simulator work, in the preview and again at the moment of use.
    func testSimulatorWorkBlocksOffloadAndDelete() {
        XCTAssertEqual(LiveOperations.simulatorWorkBlockers(true), [.simulatorWorkRunning])
        XCTAssertEqual(LiveOperations.simulatorWorkBlockers(false), [])
        XCTAssertThrowsError(try LiveOperations.refuseIfSimulatorWork(true))
        XCTAssertNoThrow(try LiveOperations.refuseIfSimulatorWork(false))
        XCTAssertFalse(AppModel.blockerText(.simulatorWorkRunning).hasPrefix("app."))
    }

}

/// The Run sheet fits (R1's lesson, R3): in every phase its minimum height stays small, so the sheet never asks the
/// window for a huge height, and the main window's screens still fit while a sheet is up.
@MainActor
final class R3SheetFitTests: XCTestCase {
    static let ceiling: CGFloat = 420

    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func minimumHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 560, height: 1)).height
    }

    func testEveryPhaseOfTheSheetFits() async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let ops = ScriptedOperations()
            ops.preview = { _, _ in
                OperationPreview(
                    source: "/Users/t/Library/Developer/Xcode/Archives", destination: "/Volumes/PABLO/XCodeVault/archives/Archives", bytes: 18_000_000_000,
                    warnings: (1...12).map { "Warning \($0): a sentence long enough to wrap at the sheet's width, as Core's do." },
                    prepared: .migration(R3RunInAppTests.plan()))
            }
            ops.lines = (1...6_000).map { LogLine(.stdout, "line \($0)") }
            ops.result = .success(.copied(R3RunInAppTests.outcome()))
            ops.holds = true
            ops.measured = 1
            let m = makeR3Model(ops, survey: sampleSurvey(checks: [r3VaultCheck()]))
            await m.refresh()
            m.openRun(r3Row())
            await eventually("the review") { m.canConfirmOperation }
            XCTAssertLessThanOrEqual(minimumHeight(OperationSheetView(model: m)), Self.ceiling, "\(language) review")
            let running = Task { await m.runOperation() }
            await eventually("running") { m.operationSheet?.log.total == 6_000 + 1 }
            XCTAssertLessThanOrEqual(m.operationSheet?.log.lines.count ?? .max, OperationLog.defaultLimit * 11 / 10, "the log keeps the newest lines")
            XCTAssertLessThanOrEqual(minimumHeight(OperationSheetView(model: m)), Self.ceiling, "\(language) running")
            // Review M12: the log expanded, its fixed 180 pt included.
            XCTAssertLessThanOrEqual(minimumHeight(OperationSheetView(model: m, showsLog: true)), Self.ceiling, "\(language) running, log open")
            m.section = .park
            let report = try XCTUnwrap(m.report)
            XCTAssertLessThanOrEqual(minimumHeight(MainView(model: m).detail(report)), ScreenFitTests.ceiling, "\(language) Park under the sheet")
            ops.release()
            await running.value
            XCTAssertLessThanOrEqual(minimumHeight(OperationSheetView(model: m)), Self.ceiling, "\(language) finished")
            XCTAssertLessThanOrEqual(minimumHeight(OperationSheetView(model: m, showsLog: true)), Self.ceiling, "\(language) finished, log open")
        }
    }
}

@MainActor
func makeR3Model(_ ops: ScriptedOperations, survey: AppModel.Survey) -> AppModel {
    let helper = SwitchableHelper(.unavailableInThisBuild)
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r3-\(UUID().uuidString).jsonl")
    return AppModel(
        environment: AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: helper, approvalFlow: { HelperApprovalFlow(helper: $0) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in }, operations: ops.services))
}

func r3Row() -> SavingsPlanRow {
    SavingsPlanRow(
        categoryID: "archives", categoryName: "Archives", bytes: 18_000_000_000,
        option: SavingsOption(bucket: .parkExternally, isExperimental: true, appliesToExistingData: true, losesUserData: false),
        command: "xcodevaultctl externalize --category archives --vault <vault>", itemCount: 1, actsImmediately: false, noteIDs: ["archivesPark"])
}

func r3VaultCheck() -> VaultVolumeCheck {
    VaultVolumeCheck(
        volume: VaultVolume(volumeUUID: "U-1", volumeName: "PABLO", lastMountPoint: "/Volumes/PABLO", registeredAt: Date(), sentinelID: "s"),
        state: .verified, currentMountPoint: "/Volumes/PABLO", shadowBytes: nil, detail: "")
}
