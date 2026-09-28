import Foundation
import ServiceManagement

@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperProtocol

// Fakes for the client half of the XPC boundary, shared by `HelperClientTests` and the app's `LiveHelperTests`.
// Moved here unchanged from `HelperClientTests`.

/// The daemon's side of a fake connection: answers each verb with a canned result and records the call.
final class FakeDaemon: NSObject, XCodeVaultHelperXPC, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    let result: HelperResult
    init(result: HelperResult) { self.result = result }
    private func record(_ s: String) { lock.withLock { calls.append(s) } }
    func version(reply: @escaping @Sendable (String) -> Void) { reply("fake") }
    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        record("clean:\(target)")
        reply(result)
    }
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        record("vault:\(volumeUUID)")
        reply(result)
    }
    func forgetMountObservation(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        record("forget:\(target)")
        reply(result)
    }
}

/// A connection that hands out a chosen proxy, or fails through the error handler, and records the order
/// of the calls that matter. `invalidate()` also fires the stored error handler, after a reply too. That
/// second call is synthetic: a real connection calls exactly one handler (NSXPCConnection.h, measured by the
/// helper-security review of deliverable 4). It stands in for a violated contract, which is what
/// `ResumeOnce` exists to survive.
final class ProxyConnection: NSXPCConnection, @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    let proxy: Any
    let failure: (any Error)?
    var handler: ((any Error) -> Void)?
    init(proxy: Any, failure: (any Error)? = nil) {
        self.proxy = proxy
        self.failure = failure
        super.init()
    }
    private func record(_ s: String) { lock.withLock { events.append(s) } }
    override func setCodeSigningRequirement(_ requirement: String) { record("requirement") }
    override func resume() { record("resume") }
    override func invalidate() {
        record("invalidate")
        handler?(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid))
    }
    // The SDK's handler is not `@Sendable`; the override must match it exactly.
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any {
        record("proxy")
        self.handler = handler
        if let failure { handler(failure) }
        return proxy
    }
}

/// launchd's side, recorded: a `HelperClient.Daemon` whose calls reach nothing outside the test — no Background
/// Task Management entry, no System Settings window.
final class RecordingLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _status: SMAppService.Status
    let registerError: (any Error)?
    let unregisterError: (any Error)?

    init(status: SMAppService.Status, registerError: (any Error)? = nil, unregisterError: (any Error)? = nil) {
        self._status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var calls: [String] { lock.withLock { _calls } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    var daemon: HelperClient.Daemon {
        HelperClient.Daemon(
            status: { [self] in lock.withLock { _status } },
            register: { [self] in
                record("register")
                if let registerError { throw registerError }
            },
            unregister: { [self] in
                record("unregister")
                if let unregisterError { throw unregisterError }
            },
            openSettings: { [self] in record("settings") })
    }
}
