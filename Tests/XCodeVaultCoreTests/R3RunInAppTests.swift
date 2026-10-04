import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Scripted operations for the Run sheet: previews answer what the test set, runs emit the test's lines and return its
/// result, and nothing outside the process is touched — no ditto, simctl, xcodebuild or defaults, no panel.
final class ScriptedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var _previews: [(OperationKind, OperationInputs)] = []
    private var _removals: [Bool] = []
    private var _resets: [XcodeLocations.Key] = []
    private var _runs = 0
    var preview: @Sendable (OperationKind, OperationInputs) -> OperationPreview = { _, _ in OperationPreview() }
    var lines: [LogLine] = []
    var result: Result<OperationResult, Refusal> = .success(.exported)
    var removeResult: (MigrationOutcome) -> Result<MigrationOutcome, Refusal> = { o in
        var r = o
        r.sourceRemoved = true
        return .success(r)
    }
    var measured: UInt64?
    var folder: String?
    /// While set, a run waits for `release()` before it returns: the test sees the operation running.
    var holds = false
    private let gate = DispatchSemaphore(value: 0)

    var previews: [(OperationKind, OperationInputs)] { lock.withLock { _previews } }
    var removals: [Bool] { lock.withLock { _removals } }
    var resets: [XcodeLocations.Key] { lock.withLock { _resets } }
    var runs: Int { lock.withLock { _runs } }
    func release() { gate.signal() }

    var services: OperationServices {
        OperationServices(
            preview: { kind, inputs in
                self.lock.withLock { self._previews.append((kind, inputs)) }
                return self.preview(kind, inputs)
            },
            run: { _, observer in
                self.lock.withLock { self._runs += 1 }
                for l in self.lines { observer(l) }
                if self.holds { self.gate.wait() }
                return try self.result.get()
            },
            removeSource: { outcome, confirmed, observer in
                self.lock.withLock { self._removals.append(confirmed) }
                observer(LogLine(.command, "rename aside"))
                return try self.removeResult(outcome).get()
            },
            resetLocation: { key, observer in
                self.lock.withLock { self._resets.append(key) }
                observer(LogLine(.command, "/usr/bin/defaults delete com.apple.dt.Xcode \(key.defaultsKey)"))
            },
            measure: { _ in self.measured },
            chooseFolder: { _ in self.folder },
            pollInterval: .milliseconds(1),
            logFile: nil)
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
        _ ops: ScriptedOperations, survey: AppModel.Survey = sampleSurvey(), scans: ScanCounter = ScanCounter(), copied: CopiedStrings = CopiedStrings()
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
                    return survey
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
        XCTAssertEqual(AppModel.secondStep(after: .locationApplied(.derivedData)), .undo)
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
        XCTAssertEqual(s?.phase, .succeeded)
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

    func testALocationChangeOffersUndoThroughCoresResetPath() async {
        let ops = ScriptedOperations()
        ops.folder = "/Volumes/PABLO/DD"
        ops.preview = { _, inputs in
            OperationPreview(
                destination: inputs.folder, prepared: .location(XcodeLocations.Change(key: .derivedData, newValue: inputs.folder), acknowledgeTests: true))
        }
        ops.result = .success(.locationApplied(.derivedData))
        let m = model(ops)
        await m.refresh()
        m.openRun(row("derivedData", .runFromExternal))
        await eventually("the review") { m.operationSheet?.preview != nil }
        XCTAssertEqual(m.operationBlockers, [.chooseFolder])
        m.chooseOperationFolder()
        await eventually("the preview") { m.canConfirmOperation }
        XCTAssertEqual(ops.previews.last?.1.folder, "/Volumes/PABLO/DD", "the panel's folder reaches the preview")
        await m.runOperation()
        XCTAssertEqual(m.operationSheet?.secondStep, .undo)
        await m.undoLocation()
        XCTAssertEqual(ops.resets, [.derivedData])
        XCTAssertEqual(m.operationSheet?.secondStep, .undone)
        XCTAssertTrue(m.operationSheet?.log.text.contains("defaults delete") == true)
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
}
