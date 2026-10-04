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

/// What the model put on the pasteboard (`AppEnvironment.copy`), in order.
@MainActor final class CopiedStrings {
    var strings: [String] = []
}

struct Refusal: Error, CustomStringConvertible {
    let description: String
}

/// A small, fixed survey: a report whose summary can count privacy refusals, an optional finding and clean plan.
func sampleSurvey(
    refusals: Int = 0, findings: [Finding] = [], actions: [CleanAction] = [], savings: SavingsSummary = SavingsSummary(), runtimeImageBytes: UInt64 = 0,
    sizesMeasured: Bool = true, free: UInt64 = 100_000_000_000, items: [StorageItem] = [], devices: [SimulatorDevice] = [], checks: [VaultVolumeCheck] = []
) -> AppModel.Survey {
    let host = HostEnvironment(
        macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: "/Users/tester",
        dataVolumeFreeBytes: free, dataVolumeTotalBytes: 500_000_000_000, userName: "tester", isRoot: false)
    var summary = ScanSummary()
    summary.privacyRefusalCount = refusals
    summary.runtimeImageBytes = runtimeImageBytes
    var report = ScanReport(
        generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: [], devices: devices, volumes: [],
        items: items, summary: summary, warnings: [])
    report.savings = savings
    report.sizesMeasured = sizesMeasured
    return (report, findings, checks, CleanPlan(actions: actions, skipped: [], warnings: []), [])
}

/// Savings shaped like a working developer Mac: every bucket non-empty, part of each experimental, simulator devices in
/// the delete card. The Overview's sample (render tests and snapshots).
func sampleSavings(lowerBound: Bool = false) -> SavingsSummary {
    let gb: UInt64 = 1_000_000_000
    var s = SavingsSummary()
    s.deleteAndRegenerate.optionBytes = 64 * gb
    s.deleteAndRegenerate.verifiedOptionBytes = 52 * gb
    s.deleteAndRegenerate.primaryBytes = 31 * gb
    s.parkExternally.optionBytes = 27 * gb
    s.parkExternally.verifiedOptionBytes = 9 * gb
    s.parkExternally.primaryBytes = 18 * gb
    s.runFromExternal.optionBytes = 33 * gb
    s.runFromExternal.verifiedOptionBytes = 33 * gb
    s.runFromExternal.primaryBytes = 33 * gb
    s.keepLocal.optionBytes = 14 * gb
    s.keepLocal.verifiedOptionBytes = 14 * gb
    s.keepLocal.primaryBytes = 14 * gb
    s.temporaryBytes = 49 * gb
    s.verifiedTemporaryBytes = 40 * gb
    s.permanentBytes = 33 * gb
    s.verifiedPermanentBytes = 33 * gb
    s.reclaimableBytes = 82 * gb
    s.verifiedReclaimableBytes = 73 * gb
    s.deleteLosesUserDataBytes = 6 * gb
    s.isLowerBound = lowerBound
    return s
}

/// A Full Disk Access state a test changes as it goes: what the probe answers next (R4).
final class AccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: FullDiskAccessState
    init(_ state: FullDiskAccessState) { _state = state }
    var state: FullDiskAccessState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
}

/// `AppModel` over fakes. The runner journals into `journal` and sees nothing running; the approval flow polls
/// every millisecond.
@MainActor
func makeModel(
    _ helper: any PrivilegedHelper, journal: TempDir, fullDiskAccess: FullDiskAccessState = .granted,
    survey: AppModel.Survey = sampleSurvey(), maxPolls: Int = 10_000, opened: OpenedURLs = OpenedURLs(), copied: CopiedStrings = CopiedStrings(),
    fullDiskAccessBox: AccessBox? = nil, registered: (@Sendable () -> Void)? = nil,
    clean: @escaping @Sendable (CleanPlan, Bool) throws -> CleanResult = { _, _ in CleanResult(deleted: [], failedPairs: []) }
) -> AppModel {
    let journalURL = URL(fileURLWithPath: journal.path + "/j.jsonl")
    let access = fullDiskAccessBox ?? AccessBox(fullDiskAccess)
    return AppModel(
        environment: AppEnvironment(
            survey: { survey }, fullDiskAccess: { access.state }, helper: helper,
            approvalFlow: { HelperApprovalFlow(helper: $0, pollInterval: .milliseconds(1), maxPolls: maxPolls) },
            runner: {
                PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL), isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            },
            clean: clean, open: { url in opened.urls.append(url) }, copy: { copied.strings.append($0) },
            registerForFullDiskAccess: registered ?? {}))
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

    /// Some assertions read the model's English (docs/process/LOCALIZATION.md): the process locale follows the machine.
    nonisolated override func setUp() {
        super.setUp()
        L10n.configure(override: "en", environment: [:], preferred: [])
    }

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

    /// R4: coming back from the pane with Full Disk Access granted rescans, once; coming back without it scans nothing.
    func testReturningFromSettingsRescansOnceAndOnlyWhenAccessWasGranted() async {
        let t = TempDir()
        let opened = OpenedURLs()
        let access = AccessBox(.notGranted)
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, opened: opened, fullDiskAccessBox: access)
        await model.appDidBecomeActive()
        XCTAssertNil(model.report, "an ordinary activation does not scan")
        model.openFullDiskAccessSettings()
        XCTAssertEqual(opened.urls, [URL(string: FullDiskAccessProbe.settingsURL)!])
        await model.appDidBecomeActive()
        XCTAssertNil(model.report, "back without granting it: nothing to rescan")
        model.openFullDiskAccessSettings()
        access.state = .granted
        await model.appDidBecomeActive()
        XCTAssertNotNil(model.report, "back with it granted: rescans")
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
        XCTAssertEqual(unavailable.lastError?.message, HelperState.unavailableInThisBuild.why)

        let slow = SwitchableHelper(.awaitingApproval)
        let timedOut = makeModel(slow, journal: t, maxPolls: 3)
        timedOut.installHelper(then: vault)
        await eventually("the wait times out") { timedOut.lastError != nil }
        XCTAssertTrue(timedOut.lastError?.message.contains("has not approved the helper") == true, timedOut.lastError?.message ?? "")

        let refused = SwitchableHelper(.notInstalled, registerError: Refusal(description: "no plist"))
        let failed = makeModel(refused, journal: t)
        failed.installHelper(then: vault)
        await eventually("the failed registration is reported") { failed.lastError != nil }
        XCTAssertEqual(failed.lastError?.message, "no plist")
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
        XCTAssertEqual(waiting.lastError?.message, "The privileged helper is not enabled.")

        let failing = makeModel(SwitchableHelper(.enabled, reply: PrivilegedActionReply(ok: false, message: "nope")), journal: t)
        await failing.perform(vault)
        XCTAssertEqual(failing.lastError?.message, "nope")

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
        XCTAssertEqual(refused.lastError?.message, "busy")
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
        XCTAssertEqual(failing.lastError?.message, "Xcode.app is running")
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

// MARK: - Navigation and the Overview's banner (S4 Task 3)

extension AppModelTests {
    func testTheSidebarHasTheTwoGroupsOfTheSpec() {
        XCTAssertEqual(SidebarSection.saveSpace, [.overview, .delete, .park, .runExternally])
        XCTAssertEqual(SidebarSection.details, [.storage, .simulators, .drives, .health, .history, .access])
        XCTAssertEqual(SidebarSection.allCases, SidebarSection.saveSpace + SidebarSection.details)
        // The bucket views carry the bucket's own S5 symbol; the others have one each.
        // R5 (HIG review N6): the sidebar's Delete is `trash`; the bucket's symbol stays with the bucket's title (BRAND.md).
        XCTAssertEqual(SidebarSection.delete.symbol, "trash")
        XCTAssertEqual(SidebarSection.park.symbol, SavingsBucket.parkExternally.symbolName)
        XCTAssertEqual(SidebarSection.runExternally.symbol, SavingsBucket.runFromExternal.symbolName)
        XCTAssertEqual(Set(SidebarSection.allCases.map(\.symbol)).count, SidebarSection.allCases.count)
        for section in SidebarSection.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil), section.symbol)
        }
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let titles = SidebarSection.allCases.map(\.title) + [SidebarSection.saveSpaceTitle, SidebarSection.detailsTitle]
            XCTAssertEqual(Set(titles).count, titles.count, locale)
            XCTAssertTrue(titles.allSatisfy { !$0.hasPrefix("app.") && !$0.isEmpty }, locale)
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
    }

    func testReviewSelectsTheBucketsView() {
        let model = makeModel(SwitchableHelper(.enabled), journal: TempDir())
        XCTAssertEqual(model.section, .overview, "the app opens on the Overview")
        model.review(.parkExternally)
        XCTAssertEqual(model.section, .park)
        model.review(.runFromExternal)
        XCTAssertEqual(model.section, .runExternally)
        model.review(.deleteAndRegenerate)
        XCTAssertEqual(model.section, .delete)
        model.review(.keepLocal)
        XCTAssertEqual(model.section, .delete, "keeping has no view: nothing changes")
        for section in SidebarSection.allCases {
            if let bucket = section.bucket { XCTAssertEqual(SidebarSection(reviewing: bucket), section) }
        }
        XCTAssertNil(SidebarSection(reviewing: .keepLocal))
    }

    func testTheBannerIsTheFirstChecklistRowThatHoldsSomethingBack() async {
        let t = TempDir()
        let blocked = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted, survey: sampleSurvey(refusals: 2))
        XCTAssertNil(blocked.accessBanner, "no scan, no banner")
        await blocked.refresh()
        XCTAssertEqual(blocked.accessBanner?.need, .fullDiskAccess)
        XCTAssertEqual(blocked.accessBanner?.blocksFolders, 2)
        let fine = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .granted, survey: sampleSurvey())
        await fine.refresh()
        XCTAssertNil(fine.accessBanner, "a missing helper with nothing root-only waiting is not a banner")
    }

    func testEachBannerActionUsesTheExistingFlow() async {
        let t = TempDir()
        let opened = OpenedURLs()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted, opened: opened)
        model.handle(.openFullDiskAccessSettings)
        XCTAssertEqual(opened.urls.map(\.absoluteString), [FullDiskAccessProbe.settingsURL])
        XCTAssertTrue(model.returningFromSettings)
        model.fullDiskAccess = .unknown
        model.handle(.recheckFullDiskAccess)
        XCTAssertEqual(model.fullDiskAccess, .notGranted, "re-checked through the environment")
        model.handle(.guidanceOnly)
        XCTAssertNil(model.helperProgress, "guidance is text, it starts nothing")
        model.handle(.installHelper)
        XCTAssertNotNil(model.helperProgress, "the SMAppService approval flow, as Install… in Access")
        model.stopWaitingForApproval()
    }
}

// MARK: - Access, asked for where it matters (S4 Task 5)

extension AppModelTests {
    func testTheAccessRowsAreTheChecklistsAndTheBannerIsTheFirstBlockingOne() async {
        let t = TempDir()
        let survey = sampleSurvey(refusals: 2, savings: sampleSavings(lowerBound: true))
        let helper = SwitchableHelper(.notInstalled)
        let model = makeModel(helper, journal: t, fullDiskAccess: .notGranted, survey: survey)
        XCTAssertEqual(model.accessRows.map(\.need), [.fullDiskAccess, .privilegedHelper], "the Access view has its rows before any scan")
        XCTAssertNil(model.accessBanner)
        await model.refresh()
        let expected = AccessChecklist.rows(
            fullDiskAccess: .notGranted, helper: .notInstalled, savings: survey.0.savings,
            plan: SavingsPlanner.rows(report: survey.0, bucket: .deleteAndRegenerate), privacyRefusalCount: 2)
        XCTAssertEqual(model.accessRows, expected)
        XCTAssertEqual(model.accessBanner, expected[0], "the first blocking row, and only that one")
        // The checklist follows the permissions without a rescan.
        helper.current = .enabled
        model.refreshPermissions()
        XCTAssertEqual(model.accessRows.last?.state, .granted, "re-read through the environment")
    }

    func testTheDeleteViewAsksForTheHelperOnlyWhenARootRowWaitsOnIt() async {
        let t = TempDir()
        let rootBytes = bucketSampleActions().filter(\.requiresRoot).reduce(UInt64(0)) { $0 + $1.bytes }
        for state in [HelperState.notInstalled, .awaitingApproval, .unavailableInThisBuild] {
            let model = makeModel(SwitchableHelper(state), journal: t, survey: bucketSampleSurvey())
            XCTAssertNil(model.deleteAccessRow, "no scan, no row")
            await model.refresh()
            XCTAssertEqual(model.deleteAccessRow?.need, .privilegedHelper, "\(state)")
            XCTAssertEqual(model.deleteAccessRow?.blocksBytes, rootBytes, "\(state)")
            XCTAssertEqual(model.deleteAccessRow, model.deleteList.flatMap { AccessChecklist.deleteRow(helper: state, list: $0) })
            // Final review M1: the Access row says the Delete view's number.
            XCTAssertEqual(model.accessRows.last?.blocksBytes, model.deleteAccessRow?.blocksBytes, "\(state)")
            if model.accessBanner?.need == .privilegedHelper { XCTAssertEqual(model.accessBanner?.blocksBytes, rootBytes, "\(state)") }
            // Final review M6: no Overview nag in a build that cannot reach the helper; the rows above keep it.
            if state == .unavailableInThisBuild { XCTAssertNotEqual(model.accessBanner?.need, .privilegedHelper) }
        }
        // Hidden once the helper is enabled: the row follows the permissions, without a rescan.
        let helper = SwitchableHelper(.notInstalled)
        let model = makeModel(helper, journal: t, survey: bucketSampleSurvey())
        await model.refresh()
        XCTAssertNotNil(model.deleteAccessRow)
        helper.current = .enabled
        model.refreshPermissions()
        XCTAssertNil(model.deleteAccessRow, "enabled: nothing to ask for")
        let enabled = makeModel(SwitchableHelper(.enabled), journal: t, survey: bucketSampleSurvey())
        await enabled.refresh()
        XCTAssertNil(enabled.deleteAccessRow)
        // Hidden when nothing listed needs root.
        let derived = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/Users/tester/Library/Developer/Xcode/DerivedData", bytes: 500,
            isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let noRoot = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: sampleSurvey(actions: [derived]))
        await noRoot.refresh()
        XCTAssertNil(noRoot.deleteAccessRow)
    }

    /// Every button an access row can show, in the Access view, the banner and above Delete, goes to the flows that were
    /// there before (`handle(_:)`); none of them is new.
    func testEveryAccessRowButtonRoutesToTheExistingFlows() async throws {
        let t = TempDir()
        let opened = OpenedURLs()
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted, survey: bucketSampleSurvey(), opened: opened)
        await model.refresh()
        let actions = (model.accessRows + [model.deleteAccessRow, model.accessBanner].compactMap { $0 }).compactMap(\.action)
        XCTAssertEqual(Set(actions), [.openFullDiskAccessSettings, .installHelper])
        model.handle(.openFullDiskAccessSettings)
        XCTAssertEqual(opened.urls.map(\.absoluteString), [FullDiskAccessProbe.settingsURL])
        XCTAssertNil(model.helperProgress)
        model.handle(try XCTUnwrap(model.deleteAccessRow?.action))
        XCTAssertNotNil(model.helperProgress, "Delete's row starts the same SMAppService approval as Access")
        model.stopWaitingForApproval()
        XCTAssertNil(model.helperProgress)
        // Unavailable in this build: guidance, which starts nothing.
        let unavailable = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: bucketSampleSurvey())
        await unavailable.refresh()
        XCTAssertEqual(unavailable.deleteAccessRow?.action, .guidanceOnly)
        unavailable.handle(.guidanceOnly)
        XCTAssertNil(unavailable.helperProgress)
        XCTAssertNil(unavailable.lastError)
    }
}
