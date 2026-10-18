import Foundation
import XCTest
import XCodeVaultHelperProtocol

@testable import XCodeVaultHelperClient

/// Advisory A2: every message to the helper has a deadline. A daemon that takes a message and never replies used to leave
/// the call — and the app waiting on it — pending until the daemon or its connection died. Over the fake connection of
/// `HelperTestFakes`, with deadlines of a fraction of a second.
final class HelperClientTimeoutTests: XCTestCase {
    private let short = HelperClient.Timeouts(opening: 0.2, verb: 0.2, cleanup: 0.2)

    private func client(_ daemon: StallingDaemon, _ connection: ProxyConnection, authorizer: HelperClient.Authorizer = .live) -> HelperClient {
        HelperClient(team: "ABCDE12345", makeConnection: { _ in connection }, authorizer: authorizer, timeouts: short)
    }

    private func assertTimedOut(_ what: String, _ body: () async throws -> HelperResult, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await body()
            XCTFail("expected a timeout, got \(result)", file: file, line: line)
        } catch let failure as HelperClient.Failure {
            XCTAssertEqual(failure, .timedOut(what), file: file, line: line)
        } catch {
            XCTFail("expected a timeout, got \(error)", file: file, line: line)
        }
    }

    func testAHelperThatNeverAnswersVersionTimesOutAndNothingIsSent() async {
        let daemon = StallingDaemon(stall: .version)
        let connection = ProxyConnection(proxy: daemon)
        await assertTimedOut("version") { try await self.client(daemon, connection).createVaultDirectory(volumeUUID: "U-1") }
        XCTAssertEqual(daemon.calls, ["version"], "neither begin nor the verb goes out after the opening stalls")
        XCTAssertTrue(connection.events.contains("invalidate"))
    }

    func testAHelperThatNeverAnswersBeginTimesOut() async {
        let daemon = StallingDaemon(stall: .begin)
        let connection = ProxyConnection(proxy: daemon)
        await assertTimedOut("begin") { try await self.client(daemon, connection).createVaultDirectory(volumeUUID: "U-1") }
        XCTAssertEqual(daemon.calls, ["version", "begin"])
    }

    func testAVerbThatIsNeverAnsweredTimesOut() async {
        let daemon = StallingDaemon(stall: .verb)
        let connection = ProxyConnection(proxy: daemon)
        await assertTimedOut("createVaultDirectory") { try await self.client(daemon, connection).createVaultDirectory(volumeUUID: "U-1") }
        XCTAssertEqual(daemon.calls, ["version", "begin", "vault"])
    }

    func testTheCleanupVerbHasItsOwnDeadline() async {
        let daemon = StallingDaemon(stall: .verb)
        let connection = ProxyConnection(proxy: daemon)
        await assertTimedOut("removeRegenerableSystemDirectoryContents") {
            try await self.client(daemon, connection).removeRegenerableSystemDirectoryContents(target: .coreSimulatorDyldCache)
        }
    }

    /// The authorization is destroyed whatever happened (R8), a timeout included, so the next call asks again.
    func testAStalledOwnershipVerbTimesOutAndStillReleasesTheAuthorization() async {
        let daemon = StallingDaemon(stall: .verb)
        let connection = ProxyConnection(proxy: daemon)
        let released = LockedFlag()
        let authorizer = HelperClient.Authorizer(acquire: { _ in
            HelperClient.AcquiredAuthorization(externalForm: Data([1, 2, 3]), release: { released.set() })
        })
        await assertTimedOut("enableOwnership") {
            try await self.client(daemon, connection, authorizer: authorizer).enableOwnership(volumeUUID: UUID().uuidString)
        }
        XCTAssertEqual(daemon.calls, ["version", "begin", "ownership"])
        XCTAssertTrue(released.value, "the authorization reference is destroyed on a timeout too")
    }

    /// The reply that comes after the deadline goes nowhere: no second resume (which would crash the process), and the
    /// timeout stands.
    func testAReplyAfterTheDeadlineIsDropped() async throws {
        let daemon = StallingDaemon(stall: .verb, lateReplyAfter: 0.5)
        let connection = ProxyConnection(proxy: daemon)
        await assertTimedOut("createVaultDirectory") { try await self.client(daemon, connection).createVaultDirectory(volumeUUID: "U-1") }
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(daemon.lateReplySent, "the late reply was made, and dropped")
    }

    /// A reply in time is the outcome, and the timer that fires afterwards does nothing: the connection is invalidated
    /// once, by the call's own `defer`, not a second time by the losing timer.
    func testAReplyInTimeWinsAndTheLosingTimerDoesNothing() async throws {
        let daemon = StallingDaemon(stall: nil)
        let connection = ProxyConnection(proxy: daemon)
        let result = try await client(daemon, connection).createVaultDirectory(volumeUUID: "U-1")
        XCTAssertTrue(result.ok, result.message)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(connection.events.filter { $0 == "invalidate" }.count, 1, "\(connection.events)")
    }

    func testTheLiveDeadlinesAreOrderedAndNoneIsZero() {
        let live = HelperClient.Timeouts.live
        XCTAssertGreaterThan(live.opening, 0)
        XCTAssertLessThan(live.opening, live.verb, "the opening is answered from memory")
        XCTAssertLessThanOrEqual(live.verb, live.cleanup, "the cleanup verb deletes a large cache")
    }

    func testATimeoutSaysThatWhetherItActedIsUnknown() {
        let text = HelperClient.Failure.timedOut("createVaultDirectory").description
        XCTAssertTrue(text.contains("createVaultDirectory"), text)
        XCTAssertTrue(text.contains("Whether it acted is unknown"), "a timeout is not a refusal: \(text)")
    }
}

/// A daemon that answers normally except for one message, which it never answers or answers late.
final class StallingDaemon: NSObject, XCodeVaultHelperXPC, @unchecked Sendable {
    enum Stall { case version, begin, verb }
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _lateReplySent = false
    let stall: Stall?
    let lateReplyAfter: TimeInterval?

    init(stall: Stall?, lateReplyAfter: TimeInterval? = nil) {
        self.stall = stall
        self.lateReplyAfter = lateReplyAfter
    }

    var calls: [String] { lock.withLock { _calls } }
    var lateReplySent: Bool { lock.withLock { _lateReplySent } }

    private func answer<T: Sendable>(_ name: String, _ kind: Stall, _ value: T, _ reply: @escaping @Sendable (T) -> Void) {
        lock.withLock { _calls.append(name) }
        guard stall == kind else { return reply(value) }
        guard let delay = lateReplyAfter else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.withLock { _lateReplySent = true }
            reply(value)
        }
    }

    private let ok = HelperResult(ok: true, message: "ok")
    func version(reply: @escaping @Sendable (String) -> Void) { answer("version", .version, HelperIdentity.version, reply) }
    func begin(clientVersion: String, reply: @escaping @Sendable (HelperResult) -> Void) { answer("begin", .begin, ok, reply) }
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) { answer("vault", .verb, ok, reply) }
    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        answer("clean", .verb, ok, reply)
    }
    func forgetMountObservation(target: String, reply: @escaping @Sendable (HelperResult) -> Void) { answer("forget", .verb, ok, reply) }
    func enableOwnership(volumeUUID: String, authorization: Data, reply: @escaping @Sendable (HelperResult) -> Void) {
        answer("ownership", .verb, ok, reply)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
