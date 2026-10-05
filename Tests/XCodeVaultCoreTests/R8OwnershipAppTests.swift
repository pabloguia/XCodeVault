import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore
@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperProtocol

/// R8 (ADR-0014): **Turn On Ownership** in the client, Core and the app. Fakes only: no connection reaches a daemon, no
/// authorization dialog appears, no drive is read, and launchd is never asked anything.
@MainActor
final class R8OwnershipAppTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private let team = "ABCDE12345"

    /// A journal file nobody else uses, under the test run's temporary directory.
    static func scratch() -> URL { URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r8-\(UUID().uuidString).jsonl") }

    // MARK: - The client: handshake, then the password, then the verb

    final class Acquisitions: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        func add(_ e: String) { lock.withLock { events.append(e) } }
        var all: [String] { lock.withLock { events } }
    }

    private func authorizer(_ log: Acquisitions, fail: (any Error)? = nil) -> HelperClient.Authorizer {
        HelperClient.Authorizer(acquire: { right in
            log.add("acquire:\(right)")
            if let fail { throw fail }
            return HelperClient.AcquiredAuthorization(externalForm: Data(repeating: 9, count: 32), release: { log.add("release") })
        })
    }

    func testTheClientChecksTheHelpersVersionBeforeAskingForThePasswordAndSendsTheForm() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "ownership is on", code: .enabled), versionReply: HelperIdentity.version)
        let log = Acquisitions()
        let client = HelperClient(team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) }, authorizer: authorizer(log))
        let result = try await client.enableOwnership(volumeUUID: "U-1")
        XCTAssertEqual(result.code, .enabled)
        XCTAssertEqual(daemon.calls, ["version", "ownership:U-1"])
        XCTAssertEqual(daemon.forms, [Data(repeating: 9, count: 32)])
        XCTAssertEqual(log.all, ["acquire:com.xcodevault.helper.enable-ownership", "release"], "one fresh reference per call, destroyed after")
    }

    func testAHelperOfAnotherVersionNeverReceivesTheAuthorization() async {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "x"), versionReply: "0.0.9")
        let log = Acquisitions()
        let client = HelperClient(team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) }, authorizer: authorizer(log))
        let result = try? await client.enableOwnership(volumeUUID: "U-1")
        XCTAssertEqual(result?.code, .helperOutdated, "a result the app reads to reinstall the helper (round 4)")
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(daemon.calls, ["version"])
        XCTAssertEqual(log.all, [], "no password is asked for a helper that is not this build's")
    }

    func testCancellingThePasswordIsAQuietResultAndSendsNothing() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "x"), versionReply: HelperIdentity.version)
        let log = Acquisitions()
        let client = HelperClient(
            team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) }, authorizer: authorizer(log, fail: HelperClient.Failure.authorizationCanceled))
        let result = try await client.enableOwnership(volumeUUID: "U-1")
        XCTAssertEqual(result.code, .authorizationCanceled)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(daemon.calls, ["version"], "the verb is never sent")
        // LiveHelper turns that into the runner's quiet cancel.
        let live = LiveHelper(client: client)
        do {
            _ = try await live.perform(.enableOwnership(volumeUUID: "U-1"))
            XCTFail("expected a cancel")
        } catch { XCTAssertTrue(error is PrivilegedActionCancelled) }
    }

    func testADeniedPasswordThrows() async {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "x"), versionReply: HelperIdentity.version)
        let client = HelperClient(
            team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) },
            authorizer: authorizer(Acquisitions(), fail: HelperClient.Failure.authorizationDenied(-60005)))
        do {
            _ = try await client.enableOwnership(volumeUUID: "U-1")
            XCTFail("expected a denial")
        } catch { XCTAssertEqual(error as? HelperClient.Failure, .authorizationDenied(-60005)) }
        XCTAssertEqual(daemon.calls, ["version"])
    }

    // MARK: - Core: the runner, the route, the vault folder

    final class OwnershipHelper: PrivilegedHelper, @unchecked Sendable {
        let lock = NSLock()
        var current: HelperState
        var result: Result<PrivilegedActionReply, any Error>
        var onPerform: @Sendable () -> Void = {}
        var beforeAuthorized: @Sendable () -> Void = {}
        private(set) var sent = 0
        private(set) var performed: [PrivilegedAction] = []
        init(_ state: HelperState, result: Result<PrivilegedActionReply, any Error>) {
            self.current = state
            self.result = result
        }
        func state() -> HelperState { lock.withLock { current } }
        func register() throws {}
        func openApprovalSettings() {}
        func unregister() async throws {}
        func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply { try await perform(action, authorized: { true }) }
        /// Like the client: a cancelled password dialog throws before `authorized`; anything else is authorized first.
        func perform(_ action: PrivilegedAction, authorized: @escaping @Sendable () -> Bool) async throws -> PrivilegedActionReply {
            lock.withLock { performed.append(action) }
            if case .failure(let e) = result, e is PrivilegedActionCancelled { throw e }
            beforeAuthorized()
            guard authorized() else { throw PrivilegedActionNotStarted() }
            lock.withLock { sent += 1 }
            onPerform()
            return try result.get()
        }
    }

    func testTheRunnerJournalsOwnershipAsADiskPreparationAndACancelAsSkipped() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ok = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: true, message: "ownership is on")))
        let done = await PrivilegedActionRunner(helper: ok, journal: journal, isXcodeRunning: { true }, isSimulatorWorkRunning: { true })
            .run(.enableOwnership(volumeUUID: "U-1"))
        XCTAssertEqual(done, .done(PrivilegedActionReply(ok: true, message: "ownership is on")), "Xcode running does not matter to ownership")
        let cancelled = await PrivilegedActionRunner(
            helper: OwnershipHelper(.enabled, result: .failure(PrivilegedActionCancelled())), journal: journal, isXcodeRunning: { false },
            isSimulatorWorkRunning: { false }
        ).run(.enableOwnership(volumeUUID: "U-2"))
        XCTAssertEqual(cancelled, .cancelled)
        let entries = try journal.entries()
        XCTAssertTrue(entries.allSatisfy { $0.kind == .diskPreparation && $0.detail["action"] == "enableOwnership" })
        XCTAssertEqual(entries.map(\.state), [.planned, .started, .completed, .planned, .skipped], "started once authorized (F2); a cancel never starts")
        XCTAssertEqual(PrivilegedAction.enableOwnership(volumeUUID: "U").requirement, .helper)
        XCTAssertEqual(PrivilegedAction.enableOwnership(volumeUUID: "U").title, "Turn on ownership")
    }

    func testTheRouteIsDecidedInCore() {
        XCTAssertEqual(OwnershipRoute.decide(helper: .enabled, working: false, fallback: nil), .oneClick)
        XCTAssertEqual(OwnershipRoute.decide(helper: .notInstalled, working: false, fallback: nil), .oneClick, "the click installs the helper first")
        XCTAssertEqual(OwnershipRoute.decide(helper: .unavailableInThisBuild, working: false, fallback: nil), .guided(.unavailableInThisBuild))
        XCTAssertEqual(OwnershipRoute.decide(helper: .enabled, working: true, fallback: nil), .working)
        XCTAssertEqual(OwnershipRoute.decide(helper: .enabled, working: false, fallback: .didNotWork("x")), .guided(.didNotWork("x")))
        XCTAssertNil(OwnershipRoute.fallback(after: PrivilegedActionOutcome.cancelled), "a cancelled password is quiet")
        XCTAssertNil(OwnershipRoute.fallback(after: PrivilegedActionOutcome.done(PrivilegedActionReply(ok: true, message: ""))))
        XCTAssertEqual(OwnershipRoute.fallback(after: PrivilegedActionOutcome.failed("refused")), .didNotWork("refused"))
        XCTAssertEqual(OwnershipRoute.fallback(after: HelperApprovalOutcome.notAvailableInThisBuild), .unavailableInThisBuild)
        XCTAssertEqual(OwnershipRoute.fallback(after: HelperApprovalOutcome.failed("denied")), .approvalNotGiven("denied"))
        XCTAssertNil(OwnershipRoute.fallback(after: HelperApprovalOutcome.cancelled))
        XCTAssertEqual(
            OwnershipFallback.didNotWork("the volume is read-only").reason(in: "en"),
            "Turning ownership on through the helper did not work: the volume is read-only. Turn it on in Finder instead, or copy the command.")
    }

    func testThePlansStepTwoFollowsTheRoute() throws {
        let snapshot = try R7ACoreTests.snapshotWithMadeVolume(owners: false)
        let drives = snapshot.disks.map { DriveEvaluation.assess($0, in: snapshot, vaults: [PlanBuilderTests.mediaVault()]) }
        func step(_ route: OwnershipRoute?) -> PlanStep? {
            PlanBuilder.plan(
                report: PlanBuilderTests.report(), drives: drives, vaults: [PlanBuilderTests.mediaVault()], locations: nil, parked: [], findings: [],
                ownership: route
            ).step(.prepareDrive)
        }
        let one = try XCTUnwrap(step(.oneClick))
        XCTAssertEqual(one.action, .turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault"))
        XCTAssertNil(one.secondaryAction)
        XCTAssertTrue(one.isExperimental, "rule 10: the helper route is experimental")
        let working = try XCTUnwrap(step(.working))
        XCTAssertNil(working.action)
        XCTAssertTrue(working.ownershipWorking)
        let guided = try XCTUnwrap(step(.guided(.didNotWork("no"))))
        XCTAssertEqual(guided.action, .showInFinder(path: "/Volumes/XCodeVault"))
        XCTAssertEqual(guided.secondaryAction, .copyOwnershipCommand(mountPoint: "/Volumes/XCodeVault"))
        XCTAssertEqual(guided.ownershipFallback, .didNotWork("no"))
        let r7d = try XCTUnwrap(step(nil))
        XCTAssertEqual(r7d.action, .showInFinder(path: "/Volumes/XCodeVault"), "a caller that knows nothing of the helper: R7-D")
        XCTAssertNil(r7d.ownershipFallback)
    }

    func testUseThisDriveOffersTheHelpersVaultFolderOnlyForARootTheUserCannotWrite() throws {
        let volume = try XCTUnwrap(try R7ACoreTests.snapshotWithMadeVolume(owners: true).volumes.first { $0.volumeUUID == R6DriveTests.u(302) })
        XCTAssertEqual(
            DriveRegistration.vaultFolderHelperStep(volume, rootIsWritable: { _ in false }, folderIsAbsent: { _ in true }),
            .createVaultDirectory(volumeUUID: R6DriveTests.u(302)))
        XCTAssertNil(DriveRegistration.vaultFolderHelperStep(volume, rootIsWritable: { _ in true }, folderIsAbsent: { _ in true }), "the user's own root")
        XCTAssertNil(DriveRegistration.vaultFolderHelperStep(volume, rootIsWritable: { _ in false }, folderIsAbsent: { _ in false }), "already there")
        var nested = volume
        nested.mountPoint = "/Volumes/A/B"
        XCTAssertNil(DriveRegistration.vaultFolderHelperStep(nested, rootIsWritable: { _ in false }, folderIsAbsent: { _ in true }), "the helper refuses it")
    }

    // MARK: - The app

    private func model(_ helper: any PrivilegedHelper, drives: ScriptedDrives, journal url: URL) -> AppModel {
        let survey = bucketSampleSurvey(checks: [PlanBuilderTests.mediaVault()])
        var env = AppEnvironment(
            survey: { survey }, fullDiskAccess: { .granted }, helper: helper,
            approvalFlow: { HelperApprovalFlow(helper: $0, pollInterval: .milliseconds(1), maxPolls: 2) },
            runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: url), isXcodeRunning: { false }, isSimulatorWorkRunning: { false }) },
            clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in })
        env.drives = drives.services
        env.reveal = { _ in }
        return AppModel(environment: env)
    }

    func testTurnOnOwnershipRunsTheVerbRereadsTheDrivesAndThePlanMovesOn() async throws {
        let drives = ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false))
        let helper = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: true, message: "ownership is on")))
        let after = try R7ACoreTests.snapshotWithMadeVolume(owners: true)
        helper.onPerform = { drives.snapshot = after }
        let m = model(helper, drives: drives, journal: Self.scratch())
        await m.refresh()
        let action = try XCTUnwrap(m.plan?.step(.prepareDrive)?.action)
        XCTAssertEqual(m.planTarget(action, vault: nil), .turnOnOwnership(R6DriveTests.u(302), "/Volumes/XCodeVault"))
        XCTAssertEqual(GuideText.actionTitle(action), "Turn On Ownership")
        m.performPlanAction(action)
        XCTAssertEqual(m.ownershipRoute, .working)
        XCTAssertEqual(m.quitChoice, .keepRunningOnly(.diskPreparation), "not stoppable: Keep Running only")
        for _ in 0..<3000 where m.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(m.ownershipInFlight)
        XCTAssertEqual(helper.performed, [.enableOwnership(volumeUUID: R6DriveTests.u(302))])
        XCTAssertEqual(m.plan?.step(.prepareDrive)?.state, .done, "the drives were read again and step 2 is done")
        XCTAssertEqual(m.plan?.step(.registerVault)?.state, .next)
        XCTAssertNil(m.ownershipFallback)
        XCTAssertEqual(m.quitChoice, .quitNow)
    }

    func testAFailureFallsBackToTheGuidedRouteWithTheReasonAndACancelDoesNot() async throws {
        let drives = ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false))
        let refused = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: false, message: "a disk image is not eligible")))
        let m = model(refused, drives: drives, journal: Self.scratch())
        await m.refresh()
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        for _ in 0..<3000 where m.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.ownershipRoute, .guided(.didNotWork("a disk image is not eligible")))
        XCTAssertNil(m.lastError, "the reason is inline, beside the guided route, not an alert")
        let step = try XCTUnwrap(m.plan?.step(.prepareDrive))
        XCTAssertEqual(step.action, .showInFinder(path: "/Volumes/XCodeVault"))
        XCTAssertEqual(step.ownershipFallback, .didNotWork("a disk image is not eligible"))

        let cancel = OwnershipHelper(.enabled, result: .failure(PrivilegedActionCancelled()))
        let c = model(cancel, drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), journal: Self.scratch())
        await c.refresh()
        c.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        for _ in 0..<3000 where c.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.ownershipRoute, .oneClick, "a cancelled password offers the click again, quietly")
        XCTAssertNil(c.lastError)
    }

    func testAnUnsignedBuildShowsTheGuidedRouteAndRunsNothing() async throws {
        let helper = OwnershipHelper(.unavailableInThisBuild, result: .success(PrivilegedActionReply(ok: true, message: "")))
        let m = model(helper, drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), journal: Self.scratch())
        await m.refresh()
        XCTAssertEqual(m.ownershipRoute, .guided(.unavailableInThisBuild))
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        XCTAssertTrue(helper.performed.isEmpty)
        XCTAssertEqual(m.plan?.step(.prepareDrive)?.ownershipFallback, .unavailableInThisBuild)
    }

    func testAnApprovalThatIsNotGivenFallsBack() async throws {
        let helper = OwnershipHelper(.awaitingApproval, result: .success(PrivilegedActionReply(ok: true, message: "")))
        let m = model(helper, drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), journal: Self.scratch())
        await m.refresh()
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        XCTAssertTrue(m.showsHelperSheet, "the helper is requested first")
        XCTAssertEqual(m.ownershipRoute, .working)
        m.installHelper(then: m.pendingPrivilegedAction)
        for _ in 0..<3000 where m.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.ownershipRoute, .guided(.approvalNotGiven(L10n.tr("app.helper.error.timedOut"))))
        XCTAssertTrue(helper.performed.isEmpty)
        // Closing the sheet instead is a quiet cancel.
        m.ownershipFallback = nil
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        m.dismissHelperSheet()
        XCTAssertEqual(m.ownershipRoute, .oneClick)
    }

    func testTheQuitRuleForOwnership() {
        XCTAssertEqual(AppModel.quitChoice(operation: .quitNow, enablingOwnership: true), .keepRunningOnly(.diskPreparation))
        XCTAssertEqual(AppModel.quitChoice(operation: .stopThenQuit, enablingOwnership: true), .keepRunningOnly(.diskPreparation))
        XCTAssertEqual(AppModel.quitChoice(operation: .keepRunningOnly(.export), enablingOwnership: true), .keepRunningOnly(.export))
        XCTAssertEqual(AppModel.quitChoice(operation: .quitNow, enablingOwnership: false), .quitNow)
    }

    // MARK: - Fix round 2

    /// F2, round 3: through the real runner — once the password is given the record is `.started`, so an app killed
    /// while the helper works reads as interrupted.
    func testAnOwnershipRequestThatNeverEndedReadsAsInterrupted() async throws {
        let journal = Journal(url: Self.scratch())
        final class Suspends: PrivilegedHelper, @unchecked Sendable {
            func state() -> HelperState { .enabled }
            func register() throws {}
            func openApprovalSettings() {}
            func unregister() async throws {}
            func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply { try await perform(action, authorized: { true }) }
            func perform(_ action: PrivilegedAction, authorized: @escaping @Sendable () -> Bool) async throws -> PrivilegedActionReply {
                guard authorized() else { throw PrivilegedActionNotStarted() }
                try await Task.sleep(for: .seconds(3600))  // the helper is working; the app is killed meanwhile
                return PrivilegedActionReply(ok: true, message: "")
            }
        }
        let runner = PrivilegedActionRunner(helper: Suspends(), journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
        let task = Task { await runner.run(.enableOwnership(volumeUUID: "U")) }
        var interrupted: [JournalEntry] = []
        for _ in 0..<3000 {
            interrupted = (try? journal.interrupted()) ?? []
            if !interrupted.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(interrupted.count, 1)
        XCTAssertEqual(interrupted.first?.kind, .diskPreparation)
        XCTAssertEqual(interrupted.first?.detail["action"], "enableOwnership")
        task.cancel()
        _ = await task.value
    }

    /// Round 3: only enableOwnership gains `.started`; the cache clean and the vault folder journal as before.
    func testOnlyOwnershipGainsAStartedRecord() async throws {
        for (action, expected) in [
            (PrivilegedAction.emptyCoreSimulatorDyldCache, [JournalEntry.State.started, .completed]),
            (.createVaultDirectory(volumeUUID: "U"), [.planned, .completed]),
            (.enableOwnership(volumeUUID: "U"), [.planned, .started, .completed]),
        ] {
            let journal = Journal(url: Self.scratch())
            let helper = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: true, message: "")))
            _ = await PrivilegedActionRunner(helper: helper, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false }).run(action)
            XCTAssertEqual(try journal.entries().map(\.state), expected, "\(action)")
        }
    }

    /// Round 3: when `.started` cannot be written, the request does not leave.
    func testAStartThatCannotBeRecordedSendsNothing() async throws {
        let url = Self.scratch()
        let journal = Journal(url: url)
        let helper = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: true, message: "")))
        helper.beforeAuthorized = {
            // The journal becomes unwritable between the opening record and the start.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let outcome = await PrivilegedActionRunner(helper: helper, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            .run(.enableOwnership(volumeUUID: "U"))
        guard case .failed(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.contains("nothing was sent"), why)
        XCTAssertEqual(helper.sent, 0, "the request never left")
        try? FileManager.default.removeItem(at: url)
    }

    func testTheClientSendsNothingWithoutTheGoAhead() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "x"), versionReply: HelperIdentity.version)
        let log = Acquisitions()
        let client = HelperClient(team: team, makeConnection: { _ in ProxyConnection(proxy: daemon) }, authorizer: authorizer(log))
        do {
            _ = try await client.enableOwnership(volumeUUID: "U-1", authorized: { false })
            XCTFail("expected notStarted")
        } catch { XCTAssertEqual(error as? HelperClient.Failure, .notStarted) }
        XCTAssertEqual(daemon.calls, ["version"], "the verb is never sent")
        XCTAssertEqual(log.all.last, "release", "the reference is still destroyed")
    }

    /// F4: the Drives row and the Plan run one check — same volume, same UUID, same mount point, against the drives now.
    func testTurnOnOwnershipRefusesAVolumeTheDrivesDoNotShow() async throws {
        let helper = OwnershipHelper(.enabled, result: .success(PrivilegedActionReply(ok: true, message: "")))
        let m = model(helper, drives: ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false)), journal: Self.scratch())
        await m.refresh()
        XCTAssertTrue(m.isOwnershipTarget(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault"))
        XCTAssertFalse(m.isOwnershipTarget(volumeUUID: R6DriveTests.u(301), mountPoint: "/Volumes/XCodeVault"), "another UUID")
        XCTAssertFalse(m.isOwnershipTarget(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/Media"), "another mount point")
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(301), mountPoint: "/Volumes/XCodeVault")
        XCTAssertNil(m.ownershipInFlight)
        XCTAssertEqual(m.planTarget(.turnOnOwnership(volumeUUID: R6DriveTests.u(301), mountPoint: "/Volumes/XCodeVault"), vault: nil), .section(.drives))
        XCTAssertTrue(helper.performed.isEmpty)
    }

    /// F5: nothing starts while an operation or a clean runs, or while one ownership request is in flight.
    func testTurnOnOwnershipWaitsForOtherWork() {
        XCTAssertTrue(AppModel.mayTurnOnOwnership(inFlight: false, operationRunning: false, cleaning: false, isTarget: true))
        XCTAssertFalse(AppModel.mayTurnOnOwnership(inFlight: false, operationRunning: true, cleaning: false, isTarget: true))
        XCTAssertFalse(AppModel.mayTurnOnOwnership(inFlight: false, operationRunning: false, cleaning: true, isTarget: true))
        XCTAssertFalse(AppModel.mayTurnOnOwnership(inFlight: true, operationRunning: false, cleaning: false, isTarget: true))
        XCTAssertFalse(AppModel.mayTurnOnOwnership(inFlight: false, operationRunning: false, cleaning: false, isTarget: false))
    }

    // MARK: - Fix round 4: an out-of-date helper is reinstalled through the approval flow, once

    final class UpdatingHelper: PrivilegedHelper, @unchecked Sendable {
        let lock = NSLock()
        private var current: HelperState = .enabled
        private var outdatedLeft: Int
        private(set) var events: [String] = []
        init(outdatedTimes: Int) { outdatedLeft = outdatedTimes }
        func state() -> HelperState { lock.withLock { current } }
        func register() throws {
            lock.withLock {
                events.append("register"); current = .enabled
            }
        }
        func openApprovalSettings() {}
        func unregister() async throws {
            lock.withLock {
                events.append("unregister"); current = .notInstalled
            }
        }
        func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply { try await perform(action, authorized: { true }) }
        func perform(_ action: PrivilegedAction, authorized: @escaping @Sendable () -> Bool) async throws -> PrivilegedActionReply {
            let outdated: Bool = lock.withLock {
                events.append("perform")
                if outdatedLeft > 0 {
                    outdatedLeft -= 1
                    return true
                }
                return false
            }
            if outdated { throw PrivilegedHelperOutdated(detail: "The privileged helper that answered is version 0.2.0-dev.") }
            guard authorized() else { throw PrivilegedActionNotStarted() }
            return PrivilegedActionReply(ok: true, message: "ownership is on")
        }
    }

    func testAnOutOfDateHelperIsReinstalledAndTheClickTriedOnceMore() async throws {
        let drives = ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false))
        let helper = UpdatingHelper(outdatedTimes: 1)
        let m = model(helper, drives: drives, journal: Self.scratch())
        await m.refresh()
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        for _ in 0..<3000 where m.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(helper.events, ["perform", "unregister", "register", "perform"], "the old daemon removed, this build's installed, tried again")
        XCTAssertNil(m.ownershipFallback)
    }

    func testASecondMismatchFallsBackInsteadOfLooping() async throws {
        let drives = ScriptedDrives(try R7ACoreTests.snapshotWithMadeVolume(owners: false))
        let helper = UpdatingHelper(outdatedTimes: 5)
        let m = model(helper, drives: drives, journal: Self.scratch())
        await m.refresh()
        m.turnOnOwnership(volumeUUID: R6DriveTests.u(302), mountPoint: "/Volumes/XCodeVault")
        for _ in 0..<3000 where m.ownershipInFlight != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(helper.events.filter { $0 == "unregister" }.count, 1, "reinstalled once per click")
        guard case .guided(.didNotWork(let why)) = m.ownershipRoute else { return XCTFail("\(m.ownershipRoute)") }
        XCTAssertTrue(why.contains("0.2.0-dev"), why)
    }
}
