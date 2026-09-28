import XCTest

@testable import XCodeVaultCore

/// A scripted helper: `state()` answers from `states` in order and repeats the last one.
final class FakeHelper: PrivilegedHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [HelperState]
    private var _registerCalls = 0
    private var _settingsOpened = 0
    private var _performed: [PrivilegedAction] = []
    let registerError: (any Error)?
    let reply: PrivilegedActionReply
    let performError: (any Error)?

    init(
        _ states: [HelperState], registerError: (any Error)? = nil, reply: PrivilegedActionReply = PrivilegedActionReply(ok: true, message: "done"),
        performError: (any Error)? = nil
    ) {
        self.states = states
        self.registerError = registerError
        self.reply = reply
        self.performError = performError
    }

    var registerCalls: Int { lock.withLock { _registerCalls } }
    var settingsOpened: Int { lock.withLock { _settingsOpened } }
    var performed: [PrivilegedAction] { lock.withLock { _performed } }

    func state() -> HelperState { lock.withLock { states.count > 1 ? states.removeFirst() : states[0] } }
    func register() throws {
        lock.withLock { _registerCalls += 1 }
        if let registerError { throw registerError }
    }
    func openApprovalSettings() { lock.withLock { _settingsOpened += 1 } }
    func unregister() async throws {}
    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply {
        lock.withLock { _performed.append(action) }
        if let performError { throw performError }
        return reply
    }
}

private struct Refused: Error {}

/// Spec §3's register → open Settings → poll → enabled, driven with a fake: `register()` and approval cannot
/// run live before M5 (#30).
final class HelperApprovalFlowTests: XCTestCase {
    private func flow(_ helper: FakeHelper, polls: Int = 5) -> HelperApprovalFlow {
        HelperApprovalFlow(helper: helper, pollInterval: .zero, maxPolls: polls)
    }

    func testAnUnavailableBuildNeverRegistersOrOpensSettings() async {
        let unavailable = FakeHelper([.unavailableInThisBuild])
        let outcome = await flow(unavailable).run()
        XCTAssertEqual(outcome, .notAvailableInThisBuild)
        XCTAssertEqual(unavailable.registerCalls, 0)
        XCTAssertEqual(unavailable.settingsOpened, 0)
        // Positive control: an installable build does register.
        let installable = FakeHelper([.notInstalled, .awaitingApproval, .enabled])
        _ = await flow(installable).run()
        XCTAssertEqual(installable.registerCalls, 1)
    }

    func testAnEnabledHelperNeedsNoApproval() async {
        let helper = FakeHelper([.enabled])
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(helper.registerCalls, 0)
        XCTAssertEqual(helper.settingsOpened, 0)
    }

    func testNotInstalledRegistersOpensSettingsAndWaitsForApproval() async {
        let helper = FakeHelper([.notInstalled, .awaitingApproval, .awaitingApproval, .enabled])
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(helper.settingsOpened, 1)
    }

    func testARegisterThatThrowsIntoApprovalIsNotAFailure() async {
        // For a daemon, `register()` is reported to throw while the service lands in approval — unmeasured here
        // (#30). The outcome is read from the status, not from the throw.
        let helper = FakeHelper([.notInstalled, .awaitingApproval, .awaitingApproval, .enabled], registerError: Refused())
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
    }

    func testARegisterThatThrowsAndLeavesItNotInstalledFails() async {
        let helper = FakeHelper([.notInstalled], registerError: Refused())
        let outcome = await flow(helper).run()
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(helper.settingsOpened, 0, "nothing to approve")
    }

    func testWaitingIsBounded() async {
        let helper = FakeHelper([.awaitingApproval])
        let outcome = await flow(helper, polls: 3).run()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(helper.settingsOpened, 1)
    }

    func testARegistrationThatVanishesStopsTheWait() async {
        let helper = FakeHelper([.awaitingApproval, .awaitingApproval, .notInstalled])
        let outcome = await flow(helper).run()
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
    }

    func testCancellationStopsTheWait() async {
        let helper = FakeHelper([.awaitingApproval])
        let task = Task { await HelperApprovalFlow(helper: helper, pollInterval: .seconds(60), maxPolls: 10).run() }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }
}

/// The runner that performs a root action through the helper, journaled, refusing while the cache is in use.
final class PrivilegedActionRunnerTests: XCTestCase {
    private func runner(_ helper: FakeHelper, _ t: TempDir, xcode: Bool = false, simulators: Bool = false) -> PrivilegedActionRunner {
        PrivilegedActionRunner(
            helper: helper, journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), isXcodeRunning: { xcode },
            isSimulatorWorkRunning: { simulators })
    }

    func testNothingRunsUnlessTheHelperIsEnabled() async {
        let t = TempDir()
        let waiting = FakeHelper([.awaitingApproval])
        guard case .refused = await runner(waiting, t).run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must refuse") }
        XCTAssertEqual(waiting.performed, [])
        // Positive control: enabled runs it.
        let enabled = FakeHelper([.enabled])
        guard case .done = await runner(enabled, t).run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must run") }
        XCTAssertEqual(enabled.performed, [.createVaultDirectory(volumeUUID: "U")])
    }

    func testTheDyldCacheIsRefusedWhileXcodeOrSimulatorWorkRuns() async {
        let t = TempDir()
        for (xcode, simulators) in [(true, false), (false, true)] {
            let helper = FakeHelper([.enabled])
            guard case .refused = await runner(helper, t, xcode: xcode, simulators: simulators).run(.emptyCoreSimulatorDyldCache) else {
                return XCTFail("must refuse with xcode=\(xcode) simulators=\(simulators)")
            }
            XCTAssertEqual(helper.performed, [])
        }
        let idle = FakeHelper([.enabled])
        guard case .done = await runner(idle, t).run(.emptyCoreSimulatorDyldCache) else { return XCTFail("idle must run") }
        XCTAssertEqual(idle.performed, [.emptyCoreSimulatorDyldCache])
    }

    func testTheVaultFolderIsNotBlockedBySimulatorWork() async {
        let t = TempDir()
        let helper = FakeHelper([.enabled])
        guard case .done = await runner(helper, t, simulators: true).run(.createVaultDirectory(volumeUUID: "U")) else {
            return XCTFail("the in-use refusal is scoped to the cache")
        }
    }

    func testOnlyTheCacheRunOpensAsStartedSoOnlyItCanShowAsInterrupted() {
        // A crash mid-call leaves only the opening record. `.started` is what `interrupted()` lists; the vault
        // folder opens `.planned`, so it is never shown as an interrupted migration with `migration abort`.
        XCTAssertEqual(PrivilegedAction.emptyCoreSimulatorDyldCache.openingState, .started)
        XCTAssertEqual(PrivilegedAction.createVaultDirectory(volumeUUID: "U").openingState, .planned)
    }

    func testEachRunIsJournalledOpenedThenClosed() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let r = PrivilegedActionRunner(helper: FakeHelper([.enabled]), journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
        _ = await r.run(.emptyCoreSimulatorDyldCache)
        _ = await r.run(.createVaultDirectory(volumeUUID: "U"))
        let e = try journal.entries()
        XCTAssertEqual(e.map(\.state), [.started, .completed, .planned, .completed])
        XCTAssertEqual(e.map(\.kind), [.clean, .clean, .migration, .migration])
        XCTAssertEqual(e[0].id, e[1].id)
        XCTAssertEqual(e[2].id, e[3].id)
        // The vault-folder run opens with `.planned`, so a crash mid-call is never listed as an interrupted
        // migration with `migration abort` suggested for it.
        XCTAssertEqual(try journal.interrupted().count, 0)
        // Not a `vault init` refusal: the doctor's vault-folder finding must not read the helper's own record.
        XCTAssertEqual(e.filter(VaultDirectoryRefusal.matches).count, 0)
    }

    func testAFailedReplyAndAThrownCallAreJournalledFailed() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let failing = FakeHelper([.enabled], reply: PrivilegedActionReply(ok: false, message: "refused by helper"))
        let failed = await PrivilegedActionRunner(helper: failing, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            .run(.emptyCoreSimulatorDyldCache)
        XCTAssertEqual(failed, .failed("refused by helper"))
        let throwing = FakeHelper([.enabled], performError: Refused())
        guard
            case .failed = await PrivilegedActionRunner(helper: throwing, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
                .run(.emptyCoreSimulatorDyldCache)
        else { return XCTFail("a thrown call is a failure") }
        XCTAssertEqual(try journal.entries().map(\.state), [.started, .failed, .started, .failed])
    }

    /// The cleanup verb removes what it can and counts only what it removed, so a failed reply can come back
    /// having deleted bytes; the journal records them (migration-safety review of deliverable 4).
    func testAFailedReplyThatFreedBytesIsJournalledWithThem() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        func run(_ reply: PrivilegedActionReply) async {
            _ = await PrivilegedActionRunner(
                helper: FakeHelper([.enabled], reply: reply), journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false }
            )
            .run(.emptyCoreSimulatorDyldCache)
        }
        await run(PrivilegedActionReply(ok: false, message: "2 item(s) could not be removed", bytesFreed: 4096))
        await run(PrivilegedActionReply(ok: false, message: "nothing removed"))
        await run(PrivilegedActionReply(ok: true, message: "cleaned", bytesFreed: 8192))
        let closing = try journal.entries().filter { $0.state != .started }
        XCTAssertEqual(closing.map(\.state), [.failed, .failed, .completed])
        XCTAssertEqual(closing.map(\.bytes), [4096, nil, 8192])
    }

    /// Not a `vault init` refusal when it fails either: the doctor's vault-folder finding reads only the record
    /// `vault init` itself leaves (migration-safety review of deliverable 4).
    func testAFailedVaultFolderRunIsNotReadAsAVaultInitRefusal() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let failing = FakeHelper([.enabled], reply: PrivilegedActionReply(ok: false, message: "refused by helper"))
        let outcome = await PrivilegedActionRunner(helper: failing, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            .run(.createVaultDirectory(volumeUUID: "U"))
        XCTAssertEqual(outcome, .failed("refused by helper"))
        let e = try journal.entries()
        // Positive control: the failure is recorded, in the shape the reader looks at — a failed migration record
        // naming the volume.
        XCTAssertEqual(e.map(\.state), [.planned, .failed])
        XCTAssertEqual(e.last?.kind, .migration)
        XCTAssertEqual(e.last?.detail[VaultDirectoryRefusal.volumeUUIDKey], "U")
        XCTAssertEqual(e.filter(VaultDirectoryRefusal.matches).count, 0)
        XCTAssertEqual(try journal.interrupted().count, 0)
        // And the reader does recognise the record `vault init` leaves.
        try journal.record(
            kind: .migration, state: .failed, summary: "vault folder could not be created (permission)",
            detail: [VaultDirectoryRefusal.reasonKey: VaultDirectoryRefusal.reason, VaultDirectoryRefusal.volumeUUIDKey: "U"])
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 1)
    }

    func testOnlyTheVaultFolderSaysWhatIsLeftToDo() {
        XCTAssertEqual(
            PrivilegedAction.createVaultDirectory(volumeUUID: "U").afterSuccess,
            "Now run `xcodevaultctl vault init` for that drive again to finish setting it up.")
        XCTAssertNil(PrivilegedAction.emptyCoreSimulatorDyldCache.afterSuccess)
        // Rule 10: the experimental action says so where the sheet and the confirmation lead with it.
        XCTAssertTrue(PrivilegedAction.emptyCoreSimulatorDyldCache.title.contains("(experimental)"))
    }

    func testAnUnwritableJournalRefusesBeforeActing() async {
        let t = TempDir()
        let notADirectory = t.file("f", bytes: 1)
        let helper = FakeHelper([.enabled])
        let r = PrivilegedActionRunner(
            helper: helper, journal: Journal(url: URL(fileURLWithPath: notADirectory + "/j.jsonl")), isXcodeRunning: { false },
            isSimulatorWorkRunning: { false })
        guard case .refused = await r.run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must refuse") }
        XCTAssertEqual(helper.performed, [], "nothing is done that the journal cannot record")
    }
}

/// A Swift source of this package with its comment lines dropped: a comment naming a call must not satisfy a pin.
func packageSource(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// The app's approval wait, pinned by its source text. The app target has no tests of its own, so these are wiring
/// pins, not behaviour tests. Two waits at once would each run their action when the helper came up
/// (migration-safety and helper-security reviews of deliverable 4).
final class AppApprovalWaitWiringTests: XCTestCase {
    private func body(of signature: String) throws -> Substring {
        let code = try packageSource("Sources/XCodeVault/XCodeVaultApp.swift")
        let start = try XCTUnwrap(code.range(of: signature), "\(signature) is gone; this pin is stale")
        let end = code.range(of: "\n    func ", range: start.upperBound..<code.endIndex)?.lowerBound ?? code.endIndex
        return code[start.upperBound..<end]
    }

    func testANewWaitCancelsTheRunningOneFirst() throws {
        let install = try body(of: "func installHelper(then action: PrivilegedAction?) {")
        let cancel = try XCTUnwrap(install.range(of: "approvalTask?.cancel()"), String(install))
        let start = try XCTUnwrap(install.range(of: "approvalTask = Task {"), String(install))
        XCTAssertLessThan(cancel.lowerBound, start.lowerBound)
    }

    func testACancelledWaitRunsNoAction() throws {
        let install = try body(of: "func installHelper(then action: PrivilegedAction?) {")
        let flow = try XCTUnwrap(install.range(of: "HelperApprovalFlow("), String(install))
        let bail = try XCTUnwrap(install.range(of: "guard !Task.isCancelled else { return }"), String(install))
        let act = try XCTUnwrap(install.range(of: "await perform(action)"), String(install))
        XCTAssertLessThan(flow.lowerBound, bail.lowerBound)
        XCTAssertLessThan(bail.lowerBound, act.lowerBound)
        // Nor does it clear what the newer wait owns: above the check, a replaced wait would nil its replacement's
        // handle and Stop would stop nothing (migration-safety review of deliverable 4, round 2).
        for clear in ["approvalTask = nil", "helperProgress = nil"] {
            let first = try XCTUnwrap(install.range(of: clear), "\(clear) is gone from installHelper: \(install)")
            XCTAssertLessThan(bail.lowerBound, first.lowerBound, clear)
        }
    }

    func testStoppingClearsWhatTheCancelledWaitNoLongerClears() throws {
        let stop = try body(of: "func stopWaitingForApproval() {")
        for line in ["approvalTask?.cancel()", "approvalTask = nil", "helperProgress = nil"] {
            XCTAssertTrue(stop.contains(line), "\(line) is missing from stopWaitingForApproval: \(stop)")
        }
    }
}

/// `DoctorView` runs a finding's action with no confirmation of its own, so only the vault folder, which deletes
/// nothing, may be one. The dyld cache is offered in Clean alone, behind a destructive confirmation
/// (migration-safety review of deliverable 4). Findings are built only in Core, the one domain layer; every
/// file there that builds one is read.
final class PrivilegedActionPlacementTests: XCTestCase {
    func testNoFindingCarriesTheCacheAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let core = root.appendingPathComponent("Sources/XCodeVaultCore").path
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: core)).compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        let building = try files.sorted().map { ($0, try packageSource("Sources/XCodeVaultCore/" + $0)) }.filter { $0.1.contains("Finding(") }
        // Positive controls: findings are found, and one of them does attach an action, so the absence below is
        // about which action.
        XCTAssertFalse(building.isEmpty, "no file builds a Finding any more; this pin is stale")
        XCTAssertTrue(building.contains { $0.1.contains(".createVaultDirectory(") }, "no finding attaches an action any more; this pin is stale")
        for (file, code) in building {
            XCTAssertFalse(code.contains("emptyCoreSimulatorDyldCache"), file)
            // A finding taking a clean row's action would carry the cache without naming it.
            XCTAssertFalse(code.contains("privilegedAction"), file)
        }
    }
}
