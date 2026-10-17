import XCTest
import XCodeVaultHelperProtocol

@testable import XCodeVaultCore
@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperCore

/// M5 (ADR-0016): what has to hold before the helper ships in a release. The opening round trip on both sides, the
/// cleanup verb refused by the daemon, and the audit trail's rate limit. Nothing here runs a privileged operation: uid 0
/// passes the administrator gate in-process only, and every verb reached is refused before it touches anything.
final class M5HelperReleaseTests: XCTestCase {
    // MARK: - The daemon's side of `begin`

    /// Calls one verb on the service through its XPC dispatch (so the queue, the refusal and the audit run as live).
    private func dispatch(_ service: HelperService, _ verb: (HelperService, @escaping @Sendable (HelperResult) -> Void) -> Void) -> HelperResult {
        let done = expectation(description: "replied")
        let box = ReplyBox()
        verb(service) { result in
            box.set(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return box.value ?? HelperResult(ok: false, message: "no reply")
    }

    func testEveryVerbIsRefusedOnAConnectionThatHasNotBegun() {
        let service = HelperService(callerUID: 0, callerGID: 0)
        let vault = dispatch(service) { $0.createVaultDirectory(volumeUUID: "definitely-not-a-uuid", reply: $1) }
        XCTAssertEqual(vault.code, .clientVersionMismatch, "refused before the UUID is even parsed: \(vault.message)")
        XCTAssertEqual(vault.message, HelperService.notBegunMessage)
        let ownership = dispatch(service) { $0.enableOwnership(volumeUUID: UUID().uuidString, authorization: Data(), reply: $1) }
        XCTAssertEqual(ownership.code, .clientVersionMismatch)
    }

    func testBeginWithThisVersionOpensTheConnectionAndAnotherVersionDoesNot() {
        let other = HelperService(callerUID: 0, callerGID: 0)
        let refused = dispatch(other) { $0.begin(clientVersion: "0.2.2", reply: $1) }
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.code, .clientVersionMismatch)
        XCTAssertFalse(refused.message.contains("0.2.2"), "the client's string never reaches the message: \(refused.message)")
        let stillShut = dispatch(other) { $0.createVaultDirectory(volumeUUID: "definitely-not-a-uuid", reply: $1) }
        XCTAssertEqual(stillShut.message, HelperService.notBegunMessage, "a refused begin opens nothing")

        // The positive control: the same verb, after a begin with this build's version, reaches its own validation.
        let service = HelperService(callerUID: 0, callerGID: 0)
        let begun = dispatch(service) { $0.begin(clientVersion: HelperIdentity.version, reply: $1) }
        XCTAssertTrue(begun.ok, begun.message)
        let vault = dispatch(service) { $0.createVaultDirectory(volumeUUID: "definitely-not-a-uuid", reply: $1) }
        XCTAssertEqual(vault.message, "invalid UUID")
    }

    func testBeginIsBehindTheAdministratorGate() throws {
        guard let nobody = getpwnam("nobody")?.pointee.pw_uid else { throw XCTSkip("no `nobody` user here") }
        let refused = HelperService(callerUID: nobody, callerGID: 0).doBegin(clientVersion: HelperIdentity.version)
        XCTAssertEqual(refused.message, HelperService.unauthorizedMessage)
    }

    func testTheCleanupVerbAndItsCompanionAreNotOfferedWhoeverAsks() {
        XCTAssertFalse(HelperService.cleanupOffered)
        let service = HelperService(callerUID: 0, callerGID: 0)
        _ = dispatch(service) { $0.begin(clientVersion: HelperIdentity.version, reply: $1) }
        for target in HelperCleanupTarget.allCases {
            let clean = dispatch(service) { $0.removeRegenerableSystemDirectoryContents(target: target.rawValue, reply: $1) }
            XCTAssertEqual(clean.code, .verbNotOffered, target.rawValue)
            XCTAssertEqual(clean.bytesFreed, 0)
            let forget = dispatch(service) { $0.forgetMountObservation(target: target.rawValue, reply: $1) }
            XCTAssertEqual(forget.code, .verbNotOffered, target.rawValue)
        }
    }

    /// Core cannot see the daemon's flag, so this is where the two are compared: the app offers the verb exactly when
    /// the helper does.
    func testTheAppOffersTheCleanupVerbExactlyWhenTheHelperDoes() {
        XCTAssertEqual(CleanAction.helperCleanupOffered, HelperService.cleanupOffered)
    }

    // MARK: - The client's side

    func testTheClientSendsNoVerbWhenBeginIsRefused() async throws {
        let refusal = HelperResult(ok: false, message: "refused: not this version", code: .clientVersionMismatch)
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "created"), beginResult: refusal)
        let result = try await HelperClient(team: "ABCDE12345", makeConnection: { _ in ProxyConnection(proxy: daemon) })
            .createVaultDirectory(volumeUUID: "U-1")
        XCTAssertEqual(result.code, .clientVersionMismatch)
        XCTAssertEqual(daemon.calls, ["version", "begin:\(HelperIdentity.version)"], "the verb is never sent")
    }

    func testTheClientSendsNoVerbToAnOlderHelperAndSaysSo() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "created"), versionReply: "0.2.2")
        let result = try await HelperClient(team: "ABCDE12345", makeConnection: { _ in ProxyConnection(proxy: daemon) })
            .createVaultDirectory(volumeUUID: "U-1")
        XCTAssertEqual(result.code, .helperOutdated)
        XCTAssertEqual(daemon.calls, ["version"], "neither begin nor the verb goes to an older helper")
    }

    // MARK: - The audit trail's rate limit

    func testOneCallerIsLimitedPerWindowAndTheFloodIsCounted() {
        var throttle = AuditThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<AuditThrottle.limit {
            XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(Double(i) * 0.1)), .emit(suppressedBefore: 0), "record \(i)")
        }
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(7)), .startSuppressing, "one line marks the start")
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(8)), .suppress)
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(9)), .suppress)
        // Another caller is not affected.
        XCTAssertEqual(throttle.admit(uid: 502, now: t0.addingTimeInterval(9)), .emit(suppressedBefore: 0))
        // The next window opens with the count of what was suppressed in the last one: 3.
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(AuditThrottle.window)), .emit(suppressedBefore: 3))
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(AuditThrottle.window + 1)), .emit(suppressedBefore: 0))
    }

    func testAClockThatGoesBackOpensANewWindowRatherThanSuppressingForever() {
        var throttle = AuditThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0...AuditThrottle.limit { _ = throttle.admit(uid: 501, now: t0) }
        XCTAssertEqual(throttle.admit(uid: 501, now: t0.addingTimeInterval(-3600)), .emit(suppressedBefore: 1))
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HelperResult?
    var value: HelperResult? { lock.withLock { _value } }
    func set(_ v: HelperResult) { lock.withLock { _value = v } }
}

/// R1 of the M5 helper-security review: the throttle drops only the cheap records, never a verb that reached its
/// implementation, so a flood of `version` calls cannot hide a privileged act.
final class M5AuditThrottleScopeTests: XCTestCase {
    private func record(_ verb: String, ok: Bool = false, code: HelperResultCode = .none, unauthorized: Bool = false) -> HelperAudit.AuditRecord {
        .from(verb: verb, callerUID: 501, validatedArguments: [:], result: HelperResult(ok: ok, message: "m", code: code), wasUnauthorized: unauthorized)
    }

    func testOnlyTheCheapRecordsAreThrottleable() {
        XCTAssertTrue(record("version", ok: true).isThrottleable)
        XCTAssertTrue(record("begin", ok: true).isThrottleable)
        XCTAssertTrue(record("createVaultDirectory", code: .clientVersionMismatch).isThrottleable, "not begun: nothing ran")
        XCTAssertTrue(record("removeRegenerableSystemDirectoryContents", code: .verbNotOffered).isThrottleable)
        XCTAssertTrue(record("enableOwnership", unauthorized: true).isThrottleable)
        // A verb that reached its implementation, whatever it answered.
        XCTAssertFalse(record("createVaultDirectory", ok: true).isThrottleable)
        XCTAssertFalse(record("createVaultDirectory", ok: false).isThrottleable, "a decline inside the verb is recorded too")
        XCTAssertFalse(record("enableOwnership", ok: false, code: .commandFailed).isThrottleable)
        XCTAssertFalse(record("enableOwnership", ok: true, code: .enabled).isThrottleable)
    }

    func testAVerbThatRanIsRecordedEvenInsideAFlood() {
        var throttle = AuditThrottle()
        let now = Date(timeIntervalSince1970: 2_000_000)
        for _ in 0..<AuditThrottle.limit { _ = HelperAudit.decide(record("version", ok: true), with: &throttle, now: now) }
        XCTAssertEqual(HelperAudit.decide(record("version", ok: true), with: &throttle, now: now), .startSuppressing)
        XCTAssertEqual(HelperAudit.decide(record("createVaultDirectory", ok: true), with: &throttle, now: now), .emit(suppressedBefore: 0))
        XCTAssertEqual(HelperAudit.decide(record("version", ok: true), with: &throttle, now: now), .suppress, "and the flood stays throttled")
    }
}
