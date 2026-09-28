import Foundation
import ServiceManagement
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore
@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperProtocol

// The app target, linked into the test bundle since 2026-09-28 (ADR-0008). The tests of `AppModel` build it with an
// `AppEnvironment` of fakes, except the first, which checks the live one: it runs the Full Disk Access probe (a read)
// and builds the live runner without running it. No test in this file scans this Mac, writes to its journal, launchd
// or System Settings, or opens a window.

/// A helper whose state a test sets as it goes, and which records what it was asked to do.
final class SwitchableHelper: PrivilegedHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: HelperState
    private var _performed: [PrivilegedAction] = []
    private var _registers = 0
    let reply: PrivilegedActionReply
    let registerError: (any Error)?
    let unregisterError: (any Error)?

    init(
        _ state: HelperState, reply: PrivilegedActionReply = PrivilegedActionReply(ok: true, message: "done"),
        registerError: (any Error)? = nil, unregisterError: (any Error)? = nil
    ) {
        self._state = state
        self.reply = reply
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var current: HelperState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var performed: [PrivilegedAction] { lock.withLock { _performed } }
    var registers: Int { lock.withLock { _registers } }

    func state() -> HelperState { current }
    func register() throws {
        lock.withLock { _registers += 1 }
        if let registerError { throw registerError }
    }
    func openApprovalSettings() {}
    func unregister() async throws {
        if let unregisterError { throw unregisterError }
    }
    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply {
        lock.withLock { _performed.append(action) }
        return reply
    }
}

/// What the model asked the system to open.
@MainActor final class OpenedURLs {
    var urls: [URL] = []
}

struct Refusal: Error, CustomStringConvertible {
    let description: String
}

/// A small, fixed survey: a report whose summary can count privacy refusals, an optional finding and clean plan.
func sampleSurvey(refusals: Int = 0, findings: [Finding] = [], actions: [CleanAction] = []) -> AppModel.Survey {
    let host = HostEnvironment(
        macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: "/Users/tester",
        dataVolumeFreeBytes: 100_000_000_000, dataVolumeTotalBytes: 500_000_000_000, userName: "tester", isRoot: false)
    var summary = ScanSummary()
    summary.privacyRefusalCount = refusals
    let report = ScanReport(
        generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: [], devices: [], volumes: [],
        items: [], summary: summary, warnings: [])
    return (report, findings, [], CleanPlan(actions: actions, skipped: [], warnings: []), [])
}

/// `AppModel` over fakes. The runner journals into `journal` and sees nothing running; the approval flow polls
/// every millisecond.
@MainActor
func makeModel(
    _ helper: any PrivilegedHelper, journal: TempDir, fullDiskAccess: FullDiskAccessState = .granted,
    survey: AppModel.Survey = sampleSurvey(), maxPolls: Int = 10_000, opened: OpenedURLs = OpenedURLs(),
    clean: @escaping @Sendable (CleanPlan, Bool) throws -> CleanResult = { _, _ in CleanResult(deleted: [], failedPairs: []) }
) -> AppModel {
    let journalURL = URL(fileURLWithPath: journal.path + "/j.jsonl")
    return AppModel(
        environment: AppEnvironment(
            survey: { survey }, fullDiskAccess: { fullDiskAccess }, helper: helper,
            approvalFlow: { HelperApprovalFlow(helper: $0, pollInterval: .milliseconds(1), maxPolls: maxPolls) },
            runner: {
                PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL), isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            },
            clean: clean, open: { url in opened.urls.append(url) }))
}

/// Waits for `condition`, failing after `timeout`. The model starts unstructured tasks; this is how a test sees
/// them finish without reaching into the model.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline {
            XCTFail("timed out waiting for \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

final class LiveHelperTests: XCTestCase {
    private let team = "ABCDE12345"
    private let noConnection: @Sendable (String) -> NSXPCConnection = { _ in ProxyConnection(proxy: NSObject()) }

    func testStateReadsLaunchdAndTheBuild() {
        let bundle = TempDir()
        _ = bundle.file("Contents/Library/LaunchDaemons/" + HelperIdentity.plistName, bytes: 1)
        let enabled = RecordingLaunchd(status: .enabled)
        let team = self.team
        let signed = HelperClient(
            team: team, makeConnection: noConnection, bundleURL: URL(fileURLWithPath: bundle.path), runningTeam: { team }, daemon: enabled.daemon)
        XCTAssertEqual(LiveHelper(client: signed).state(), .enabled)
        // The same launchd answer from a build whose signature carries no team: unavailable, whatever launchd says.
        let adHoc = HelperClient(
            team: team, makeConnection: noConnection, bundleURL: URL(fileURLWithPath: bundle.path), runningTeam: { nil }, daemon: enabled.daemon)
        XCTAssertEqual(LiveHelper(client: adHoc).state(), .unavailableInThisBuild)
    }

    func testRegistrationRemovalAndSettingsGoToTheClient() async throws {
        let launchd = RecordingLaunchd(status: .notRegistered)
        let helper = LiveHelper(client: HelperClient(team: team, makeConnection: noConnection, daemon: launchd.daemon))
        try helper.register()
        helper.openApprovalSettings()
        try await helper.unregister()
        XCTAssertEqual(launchd.calls, ["register", "settings", "unregister"])
    }

    func testEachActionSendsItsOwnVerbAndTheReplyComesBackWhole() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "done", bytesFreed: 4096))
        let helper = LiveHelper(
            client: HelperClient(team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) }, daemon: RecordingLaunchd(status: .enabled).daemon))
        let vault = try await helper.perform(.createVaultDirectory(volumeUUID: "U-1"))
        let cache = try await helper.perform(.emptyCoreSimulatorDyldCache)
        XCTAssertEqual(daemon.calls, ["vault:U-1", "clean:coreSimulatorDyldCache"], "the enum's raw value and a UUID cross the wire, never a path")
        XCTAssertEqual(vault, PrivilegedActionReply(ok: true, message: "done", bytesFreed: 4096))
        XCTAssertEqual(cache, PrivilegedActionReply(ok: true, message: "done", bytesFreed: 4096))
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private let vault = PrivilegedAction.createVaultDirectory(volumeUUID: "U")

    func testTheAppStartsFromTheLiveEnvironment() async throws {
        let live = AppModel().environment
        XCTAssertNil(live.survey, "the app runs the real scan")
        XCTAssertTrue(live.helper is LiveHelper)
        XCTAssertEqual(live.fullDiskAccess(), FullDiskAccessProbe().state(), "the live probe is the real one")
        // The live flow, on a helper this build cannot reach: it stops before registering anything.
        let unreachable = SwitchableHelper(.unavailableInThisBuild)
        let outcome = await live.approvalFlow(unreachable).run()
        XCTAssertEqual(outcome, .notAvailableInThisBuild)
        XCTAssertEqual(unreachable.registers, 0)
        // The live runner is built, not run: a run falls back to the real journal if its first check ever regressed
        // (migration-safety review of the coverage change). The runner's own tests cover what it does.
        XCTAssertEqual(live.runner(unreachable).journal.url, Journal.defaultURL, "the app journals where the CLI does")
        // Its in-use checks are closures and cannot be compared, so the source says the live runner overrides none of
        // its defaults, which `scripts/public-surface.sh` rule 3 holds to the real checks (helper-security review).
        let environment = try packageSource("Sources/XCodeVault/AppEnvironment.swift")
        XCTAssertTrue(environment.contains("runner: { PrivilegedActionRunner(helper: $0) }"), "the live runner takes every default")
    }

    func testRefreshStoresTheSurveyAndThePermissions() async {
        let t = TempDir()
        let helper = SwitchableHelper(.notInstalled)
        let model = makeModel(helper, journal: t, fullDiskAccess: .notGranted, survey: sampleSurvey(refusals: 2))
        XCTAssertNil(model.report)
        await model.refresh()
        XCTAssertEqual(model.report?.summary.privacyRefusalCount, 2)
        XCTAssertNotNil(model.cleanPlan)
        XCTAssertEqual(model.fullDiskAccess, .notGranted)
        XCTAssertEqual(model.helperState, .notInstalled)
        XCTAssertFalse(model.isScanning)
    }

    func testReturningFromSettingsRescansOnceAndOnlyThen() async {
        let t = TempDir()
        let opened = OpenedURLs()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, opened: opened)
        await model.appDidBecomeActive()
        XCTAssertNil(model.report, "an ordinary activation does not scan")
        model.openFullDiskAccessSettings()
        XCTAssertEqual(opened.urls, [URL(string: FullDiskAccessProbe.settingsURL)!])
        await model.appDidBecomeActive()
        XCTAssertNotNil(model.report, "coming back from Settings rescans")
        model.report = nil
        await model.appDidBecomeActive()
        XCTAssertNil(model.report, "once, not on every activation")
    }

    func testARequestFollowsTheHelperState() async {
        let t = TempDir()
        let enabled = SwitchableHelper(.enabled)
        let running = makeModel(enabled, journal: t)
        running.refreshPermissions()
        running.request(vault)
        await eventually("the action ran") { running.lastPrivilegedResult != nil }
        XCTAssertEqual(enabled.performed, [vault])
        XCTAssertEqual(running.lastPrivilegedResult, "done\n\n" + vault.afterSuccess!)

        let missing = makeModel(SwitchableHelper(.notInstalled), journal: t)
        missing.refreshPermissions()
        missing.request(.emptyCoreSimulatorDyldCache)
        XCTAssertTrue(missing.showsHelperSheet)
        XCTAssertEqual(missing.pendingPrivilegedAction, .emptyCoreSimulatorDyldCache)

        let unreachable = SwitchableHelper(.unavailableInThisBuild)
        let none = makeModel(unreachable, journal: t)
        none.refreshPermissions()
        none.request(.emptyCoreSimulatorDyldCache)
        XCTAssertFalse(none.showsHelperSheet)
        XCTAssertNil(none.pendingPrivilegedAction)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(unreachable.performed, [])
    }

    func testApprovalThenTheChosenAction() async {
        let t = TempDir()
        let helper = SwitchableHelper(.awaitingApproval)
        let model = makeModel(helper, journal: t)
        model.pendingPrivilegedAction = vault
        model.showsHelperSheet = true
        model.installHelper(then: model.pendingPrivilegedAction)
        XCTAssertFalse(model.showsHelperSheet)
        XCTAssertNil(model.pendingPrivilegedAction)
        XCTAssertNotNil(model.helperProgress)
        helper.current = .enabled
        await eventually("the approved action ran") { model.lastPrivilegedResult != nil }
        XCTAssertNil(model.helperProgress)
        XCTAssertEqual(helper.performed, [vault])
        XCTAssertEqual(model.helperState, .enabled)
    }

    func testAnApprovalThatEndsWithoutTheHelperSaysWhy() async {
        let t = TempDir()
        let unavailable = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t)
        unavailable.installHelper(then: vault)
        await eventually("the unavailable build is reported") { unavailable.lastError != nil }
        XCTAssertEqual(unavailable.lastError, HelperState.unavailableInThisBuild.why)

        let slow = SwitchableHelper(.awaitingApproval)
        let timedOut = makeModel(slow, journal: t, maxPolls: 3)
        timedOut.installHelper(then: vault)
        await eventually("the wait times out") { timedOut.lastError != nil }
        XCTAssertTrue(timedOut.lastError?.contains("has not approved the helper") == true, timedOut.lastError ?? "")

        let refused = SwitchableHelper(.notInstalled, registerError: Refusal(description: "no plist"))
        let failed = makeModel(refused, journal: t)
        failed.installHelper(then: vault)
        await eventually("the failed registration is reported") { failed.lastError != nil }
        XCTAssertEqual(failed.lastError, "no plist")
        XCTAssertEqual(slow.performed + refused.performed, [], "no action runs without the helper")
    }

    /// A second request replaces the running wait: only its action runs, and the replaced wait leaves the
    /// newer one's progress text and handle alone (migration-safety and helper-security reviews of deliverable 4).
    /// Timing, not proof: a regression of the replaced wait's cleanup shows only if that wait resumes within the
    /// 50 ms below. A passing run cannot tell whether it did; a mutant run can, and M6-1 and M6-2 (rerun as M8-11
    /// and M8-12, STATUS.md 2026-09-28) were killed. A machine too loaded for that would let such a regression pass.
    func testANewWaitReplacesTheRunningOne() async throws {
        let t = TempDir()
        let helper = SwitchableHelper(.awaitingApproval)
        let model = makeModel(helper, journal: t)
        let first = PrivilegedAction.createVaultDirectory(volumeUUID: "A")
        let second = PrivilegedAction.createVaultDirectory(volumeUUID: "B")
        model.installHelper(then: first)
        model.installHelper(then: second)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.helperProgress, "the replaced wait must not clear the newer wait's progress")
        helper.current = .enabled
        await eventually("the newer action ran") { model.lastPrivilegedResult != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.performed, [second])
    }

    /// Stop stops the wait that is running, including one that replaced another. The same timing caveat as above
    /// holds for the replaced wait. The control is a model that is not stopped, approved at the same moment: the
    /// stopped one is checked only after the control has acted, and 100 ms later.
    func testStoppingAfterAReplacementStopsTheNewWait() async throws {
        let t = TempDir()
        let c = TempDir()
        let helper = SwitchableHelper(.awaitingApproval)
        let control = SwitchableHelper(.awaitingApproval)
        let model = makeModel(helper, journal: t)
        let unstopped = makeModel(control, journal: c)
        for m in [model, unstopped] {
            m.installHelper(then: .createVaultDirectory(volumeUUID: "A"))
            m.installHelper(then: .createVaultDirectory(volumeUUID: "B"))
        }
        try await Task.sleep(for: .milliseconds(50))
        model.stopWaitingForApproval()
        XCTAssertNil(model.helperProgress)
        helper.current = .enabled
        control.current = .enabled
        await eventually("the unstopped wait acted") { unstopped.lastPrivilegedResult != nil }
        XCTAssertEqual(control.performed, [.createVaultDirectory(volumeUUID: "B")])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.performed, [])
        XCTAssertNil(model.lastPrivilegedResult)
    }

    /// The control is a model that is not stopped, approved at the same moment, as above.
    func testStoppingClearsTheProgressAndRunsNothing() async throws {
        let t = TempDir()
        let c = TempDir()
        let helper = SwitchableHelper(.awaitingApproval)
        let control = SwitchableHelper(.awaitingApproval)
        let model = makeModel(helper, journal: t)
        let unstopped = makeModel(control, journal: c)
        model.installHelper(then: vault)
        unstopped.installHelper(then: vault)
        XCTAssertNotNil(model.helperProgress)
        model.stopWaitingForApproval()
        XCTAssertNil(model.helperProgress)
        helper.current = .enabled
        control.current = .enabled
        await eventually("the unstopped wait acted") { unstopped.lastPrivilegedResult != nil }
        XCTAssertEqual(control.performed, [vault])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.performed, [])
    }

    func testPerformReportsWhatTheRunnerSaid() async {
        let t = TempDir()
        let waiting = makeModel(SwitchableHelper(.awaitingApproval), journal: t)
        await waiting.perform(vault)
        XCTAssertEqual(waiting.lastError, "The privileged helper is not enabled.")

        let failing = makeModel(SwitchableHelper(.enabled, reply: PrivilegedActionReply(ok: false, message: "nope")), journal: t)
        await failing.perform(vault)
        XCTAssertEqual(failing.lastError, "nope")

        let cache = makeModel(SwitchableHelper(.enabled), journal: t)
        await cache.perform(.emptyCoreSimulatorDyldCache)
        XCTAssertEqual(cache.lastPrivilegedResult, "done", "nothing is left to do after the cache")
        XCTAssertNil(cache.lastError)
        XCTAssertNotNil(cache.report, "an action is followed by a rescan")
    }

    func testUninstallReportsAFailure() async {
        let t = TempDir()
        let fine = makeModel(SwitchableHelper(.enabled), journal: t)
        await fine.uninstallHelper()
        XCTAssertNil(fine.lastError)
        let refused = makeModel(SwitchableHelper(.enabled, unregisterError: Refusal(description: "busy")), journal: t)
        await refused.uninstallHelper()
        XCTAssertEqual(refused.lastError, "busy")
    }

    func testApplyCleanStoresTheResultOrTheError() async {
        let t = TempDir()
        let deleted = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/tmp/dd", bytes: 10, isExperimental: true, risk: .low,
            requiresRoot: false, notes: [])
        let seen = Box<Bool?>(nil)
        let model = makeModel(
            SwitchableHelper(.enabled), journal: t, survey: sampleSurvey(actions: [deleted]),
            clean: { plan, useTrash in
                seen.set(useTrash)
                return CleanResult(deleted: plan.actions, failedPairs: [])
            })
        await model.applyClean(actions: [deleted], useTrash: true)
        XCTAssertNil(model.lastCleanResult, "no plan yet, so nothing to clean")
        await model.refresh()
        await model.applyClean(actions: [deleted], useTrash: true)
        XCTAssertEqual(model.lastCleanResult?.deleted, [deleted])
        XCTAssertEqual(seen.get(), true)

        let failing = makeModel(SwitchableHelper(.enabled), journal: t, clean: { _, _ in throw Refusal(description: "Xcode.app is running") })
        await failing.refresh()
        await failing.applyClean(actions: [], useTrash: false)
        XCTAssertEqual(failing.lastError, "Xcode.app is running")
    }
}

/// A value a `@Sendable` closure can set and a test can read.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}
