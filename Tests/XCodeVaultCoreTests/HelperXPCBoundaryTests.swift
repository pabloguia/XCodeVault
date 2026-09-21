import Foundation
import XCTest

@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// The XPC boundary itself, driven over a real connection (issue #30).
///
/// **What was missing.** Every existing helper test calls the `do…` functions directly through
/// seams, so nothing had ever crossed XPC: not one of the four `@objc` protocol methods, not the
/// `NSXPCInterface`, not `HelperResult`'s `NSSecureCoding` trip over the wire, not the listener's
/// accept path. Issue #30 names exactly this — "the XPC boundary itself … has never been exercised
/// end to end" — and the part of it that needs a signed build is the *mach service*, not XPC. An
/// anonymous listener needs no launchd, no `SMAppService`, and no signature.
///
/// The gap matters because these are runtime failures, not compile-time ones. A protocol method the
/// interface cannot vend, or a reply class missing from the allowed set, builds cleanly and fails
/// only when a real connection carries it.
///
/// **Verbs are chosen so that nothing privileged happens.** `version` is synchronous and touches no
/// filesystem. `createVaultDirectory` is given a string that is not a UUID, which `doCreateVaultDirectory`
/// refuses on its second line — before any volume is examined. `HelperAudit` writes through `os_log`,
/// not to a file, so the audit these calls emit costs a log line and nothing else.
final class HelperXPCBoundaryTests: XCTestCase {

    /// Reply closures are `@Sendable`, so results come back through this rather than a captured `var`.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func record(_ key: String, _ value: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
        func value(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }
    }

    /// Wires the same interface and the same exported object as production, and deliberately does
    /// NOT set a code-signing requirement.
    ///
    /// That omission is the point of the split: an unsigned test binary cannot satisfy the real
    /// requirement, so a delegate carrying it could never deliver a message — which would make this
    /// a test of the refusal and not of the interface. The refusal is tested separately below, with
    /// the production `ListenerDelegate`. Neither test can stand in for the other.
    private final class InterfaceOnlyDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
            connection.exportedObject = HelperService(callerUID: getuid(), callerGID: getgid())
            connection.resume()
            return true
        }
    }

    private func connected(to delegate: NSXPCListenerDelegate) -> (NSXPCListener, NSXPCConnection) {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
        connection.resume()
        return (listener, connection)
    }

    // MARK: - The interface is real and a verb dispatches across it

    func testTheVersionVerbCrossesARealXPCConnection() {
        let delegate = InterfaceOnlyDelegate()
        let (listener, connection) = connected(to: delegate)
        defer {
            connection.invalidate()
            listener.invalidate()
        }

        let recorder = Recorder()
        let answered = expectation(description: "version replied or failed")
        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                recorder.record("error", "\(error)")
                answered.fulfill()
            }) as? XCodeVaultHelperXPC
        else {
            return XCTFail("the connection did not vend a proxy conforming to the protocol")
        }
        proxy.version { version in
            recorder.record("version", version)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 15)

        XCTAssertNil(recorder.value("error"), "the connection failed instead of replying")
        // The helper's own constant, so this fails if the two sides ever disagree about it.
        XCTAssertEqual(recorder.value("version"), HelperIdentity.version)
    }

    func testHelperResultSurvivesTheWire() {
        let delegate = InterfaceOnlyDelegate()
        let (listener, connection) = connected(to: delegate)
        defer {
            connection.invalidate()
            listener.invalidate()
        }

        let recorder = Recorder()
        let answered = expectation(description: "createVaultDirectory replied or failed")
        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                recorder.record("error", "\(error)")
                answered.fulfill()
            }) as? XCodeVaultHelperXPC
        else {
            return XCTFail("the connection did not vend a proxy conforming to the protocol")
        }
        // Not a UUID, so this is refused before a single volume is examined.
        proxy.createVaultDirectory(volumeUUID: "definitely-not-a-uuid") { result in
            recorder.record("ok", result.ok ? "true" : "false")
            recorder.record("message", result.message)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 15)

        XCTAssertNil(recorder.value("error"), "the connection failed instead of replying")
        XCTAssertEqual(recorder.value("ok"), "false")
        // Which refusal depends on whether the user running the tests is an administrator, and both
        // are correct. Asserting the pair rather than one of them keeps this honest on a CI runner
        // whose account may differ from a developer's, without degrading to "some message arrived".
        let message = recorder.value("message")
        XCTAssertTrue(
            message == "invalid UUID" || message == HelperService.unauthorizedMessage,
            "unexpected refusal: \(message ?? "<none>")")
    }

    // MARK: - The production listener's peer validation

    func testPeerValidationIsWhatRefusesAnUnsignedPeer() {
        // A CONTROLLED PAIR, in one test, in one process, moments apart. The two halves differ in
        // exactly one thing: whether the listener's delegate sets the code-signing requirement.
        //
        // Split across two tests this would be weaker than it looks. "The call did not come back"
        // has many causes, and the error XPC reports is the generic
        // `NSCocoaErrorDomain 4097 "connection to service created from an endpoint"` — which says
        // the connection was torn down, not why. Running the control in the same breath is what
        // licenses the causal claim: the requirement is the only variable, so it is the reason.
        let control = Recorder()
        let guarded = Recorder()

        drive(delegate: InterfaceOnlyDelegate(), into: control)
        drive(delegate: ListenerDelegate(teamID: "ABCDE12345"), into: guarded)

        // Control: no requirement, so an unsigned peer is served.
        XCTAssertEqual(control.value("version"), HelperIdentity.version, "the control half must succeed, or this test proves nothing")
        XCTAssertNil(control.value("error"))

        // Guarded: the production delegate, and this process carries no Developer ID.
        XCTAssertNil(guarded.value("version"), "an unsigned peer got a reply from a listener that set a Developer-ID requirement")
        // The CODE, not merely "an error arrived" — an unrelated failure would otherwise satisfy this
        // and read as peer validation working. The observed value is `NSXPCConnectionInterrupted`
        // (4097), not `NSXPCConnectionInvalid` (4099) which this first asserted and which the run
        // corrected. Both are accepted: which one XPC reports depends on when it tears the connection
        // down relative to the message, and pinning that timing would buy a flaky test rather than a
        // stronger claim. What must not pass is any other error, or none.
        let code = guarded.value("errorCode")
        XCTAssertTrue(
            code == "\(NSXPCConnectionInterrupted)" || code == "\(NSXPCConnectionInvalid)",
            "expected an XPC connection failure, got error code \(code ?? "<none>")")
    }

    /// Opens an anonymous listener with `delegate`, asks for `version`, and records what came back.
    private func drive(delegate: NSXPCListenerDelegate, into recorder: Recorder) {
        let (listener, connection) = connected(to: delegate)
        defer {
            connection.invalidate()
            listener.invalidate()
        }
        let answered = expectation(description: "replied or failed")
        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                recorder.record("error", "\(error)")
                recorder.record("errorCode", "\((error as NSError).code)")
                answered.fulfill()
            }) as? XCodeVaultHelperXPC
        else {
            XCTFail("the connection did not vend a proxy conforming to the protocol")
            return
        }
        proxy.version { version in
            recorder.record("version", version)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 15)
    }
}
