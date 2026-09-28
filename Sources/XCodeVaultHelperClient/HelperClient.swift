import Foundation
import ServiceManagement
import XCodeVaultHelperProtocol

/// The only file in the tree permitted to open a connection to the privileged helper.
///
/// `scripts/helper-invariants.sh` enforces that as a prohibition: no file under `Sources/` outside
/// its allowlist may textually name `NSXPCConnection(machServiceName:` or the libxpc primitive it
/// wraps. This path is that allowlist's single entry, which is what guarantees the peer validation
/// below is read by a reviewer rather than assumed.
///
/// **What exists here and what does not (issue #30).** The connection's configuration, registration and
/// the two verb calls are here and unit-tested, the calls with a fake connection. None of it has run
/// against a real daemon: no code called `register()` before deliverable 4 of the 2026-09-27 permissions
/// plan, and no build has had a real Developer ID team ID, which both ends of the connection require. That
/// is M5, and the compatibility matrix records it as pending, not as working.
public struct HelperClient: Sendable {

    /// Substituted by `scripts/bundle-app.sh` at bundle time, exactly as the daemon's own team ID
    /// is, and asserted there to have landed. A build that skips it ships the placeholder, which
    /// `isUsableTeamID` rejects — so this client refuses to connect rather than connecting without
    /// peer validation. That refusal is the point; see `connect()`.
    static let teamID = "TEAMID_PLACEHOLDER"

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unusableTeamID(String)
        case requirementDoesNotParse(String)
        case notRegistered(String)
        /// The helper did not reply: not running, not approved, the peer refused, or the connection broke.
        case connectionFailed(String)
        /// What came back was not the helper's interface. Unreachable with a connection `connect()`
        /// configured; stated so a future change turns it into an error rather than a crash.
        case unexpectedProxy

        public var description: String {
            switch self {
            case .unusableTeamID:
                // Deliberately does not quote the value. It is either the placeholder — in which
                // case naming it invites "just compare against the placeholder", the bug that
                // produced a detector unable to detect its own placeholder — or a malformed real
                // team ID, which is not something to print.
                return
                    "This build has no usable Apple team ID, so the helper's code-signing requirement cannot be built. "
                    + "Refusing to connect: an unvalidated connection to \(HelperIdentity.machServiceName) would act on "
                    + "the replies of whatever holds that name. Rebuild with scripts/bundle-app.sh --sign."
            case .requirementDoesNotParse(let r):
                return "The helper's code-signing requirement is not valid requirement-language: \(r). Refusing to connect."
            case .notRegistered(let s):
                // Not "run the app once": nothing is installed at launch (ADR-0007).
                return "The helper is not registered with launchd (\(s)). The app installs it when you choose an action that needs root, "
                    + "or from Install… in its Permissions section; see SECURITY_MODEL.md."
            case .connectionFailed(let why):
                return "The privileged helper did not reply (\(why)). Whether it acted is unknown; rescan to see."
            case .unexpectedProxy:
                return "The connection did not return the privileged helper's interface. Refusing to use it."
            }
        }
    }

    /// The team ID this instance validates against. `let`, set through `init` — the seam discipline
    /// issues #27, #31 and #33 established, applied here from the start rather than retrofitted.
    let team: String

    /// How a connection is obtained. Internal and without a default, so the two initialisers are
    /// told apart by intent: the public one cannot install it.
    ///
    /// **Held by review, not by a gate.** An earlier version of this comment said
    /// `scripts/public-surface.sh` would fail if this became public. It would not — that gate pins
    /// `MODULE="XCodeVaultCore"` and four type names, and never examines this module, so making
    /// this seam public would pass every check in the repository. It is the seam that decides
    /// *which object gets resumed*, so the claim mattered; stating a gate that does not exist is
    /// worse than stating none.
    let makeConnection: @Sendable (String) -> NSXPCConnection

    /// This build's bundle, where `SMAppService.daemon` looks for the plist. `Bundle.main.bundleURL` in
    /// production; a temporary directory in tests. Internal, like `makeConnection`.
    ///
    /// **For `xcodevaultctl` this is the `.app` only when it is started from `Contents/MacOS`.** Started
    /// through a symlink — which is what the cask's `binary` stanza installs — it is the link's directory,
    /// so `bundlesDaemon` answers `false` and `permissions` reports "not available in this build" even for a
    /// build that has the helper (measured 2026-09-28 on an unsigned binary: real path → the `.app`, plist
    /// found; symlink, by path or `PATH` → the link's directory, not found). That fails closed. The
    /// helper-security review also measured the invoker's environment (`CFProcessPath`) redirecting it:
    /// what this points at is chosen by whoever runs the CLI — a hint, never a gate.
    let bundleURL: URL

    /// The team in the running code's own signature: `teamOfRunningCode` in production. Internal, like
    /// `makeConnection`, so tests can say what a signed build would answer.
    let runningTeam: @Sendable () -> String?

    public init() {
        self.team = HelperClient.teamID
        self.makeConnection = { name in
            // `.privileged` is what makes this reach a *root* LaunchDaemon in the global bootstrap
            // namespace rather than a per-user agent of the same name.
            NSXPCConnection(machServiceName: name, options: .privileged)
        }
        self.bundleURL = Bundle.main.bundleURL
        self.runningTeam = HelperClient.teamOfRunningCode
    }

    init(
        team: String, makeConnection: @escaping @Sendable (String) -> NSXPCConnection, bundleURL: URL = Bundle.main.bundleURL,
        runningTeam: @escaping @Sendable () -> String? = HelperClient.teamOfRunningCode
    ) {
        self.team = team
        self.makeConnection = makeConnection
        self.bundleURL = bundleURL
        self.runningTeam = runningTeam
    }

    /// The requirement this client will demand of the daemon, or a failure explaining why it cannot
    /// build one. Separated from `connect()` so the decision is testable without a connection.
    public func peerRequirement() throws -> String {
        guard HelperIdentity.isUsableTeamID(team) else { throw Failure.unusableTeamID(team) }
        let requirement = HelperIdentity.helperRequirement(teamID: team)

        // Parse before use, for the same reason `main.swift` does on its side: NSXPCConnection's
        // `setCodeSigningRequirement` raises an Objective-C exception on a malformed string, and
        // Swift cannot catch that — the process dies. Validating first turns an unhandleable crash
        // into a `Failure` the caller can report.
        //
        // **This branch is unreachable today, and stays.** The guard above admits only ten characters
        // of `[A-Z0-9]`, and every such team ID interpolates into a requirement that parses — so
        // SonarQube reports this one line uncovered and no test can reach it without weakening
        // `isUsableTeamID`. It is the last uncovered line in this file, and deleting it to make a
        // coverage number go up would remove the only thing standing between a malformed requirement
        // and an uncatchable Objective-C exception, should either function's rules ever change.
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw Failure.requirementDoesNotParse(requirement)
        }
        return requirement
    }

    /// A configured, resumed connection to the helper.
    ///
    /// The requirement is set **before** `resume()`, so from the first message on a reply from a peer that
    /// fails it is refused: the call fails with `NSXPCConnectionCodeSigningRequirementFailure` (4102) instead
    /// of returning what that peer said. Setting it afterwards would leave a window of unchecked replies.
    ///
    /// **It does not stop the request.** The requirement checks the messages this connection *receives*
    /// (xpc/connection.h:790-793), and an in-process probe measured it on 2026-09-28 (helper-security review of
    /// deliverable 4): the failing peer ran the method, and the caller got 4102. Whoever holds the Mach name
    /// gets the message. What drops a request from a wrong client is the daemon's own listener requirement,
    /// measured the same day; what keeps an old daemon from acting on a verb is the M5 TODO in
    /// `HelperProtocol.swift`, which is not written yet.
    ///
    /// Internal (the same review): `send` is its only caller, and the compiler rather than review keeps it so.
    func connect() throws -> NSXPCConnection {
        let requirement = try peerRequirement()
        let connection = makeConnection(HelperIdentity.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        return connection
    }

    /// launchd's view of the daemon, as `SMAppService` reports it.
    ///
    /// Read-only and safe to call unsigned: it answers a not-installed status rather than failing,
    /// which is what lets the app tell a user why nothing works instead of appearing broken.
    ///
    /// **Which** not-installed status comes back is measured, and the causal story is not. This
    /// comment first said `.notRegistered`; a test written against that claim measured `.notFound`
    /// (rawValue 3) from a `swift test` bundle. The obvious explanation — the daemon plist ships in
    /// the app bundle and a test bundle has none — was then falsified by a reviewer, who built an
    /// ad-hoc-signed `.app` that *did* carry `Contents/Library/LaunchDaemons/` and still measured
    /// `.notFound`. So: `.notFound` here, for a reason nobody has established. A properly signed,
    /// `SMAppService`-registered install is *expected* to answer `.notRegistered`, and that is
    /// unverified — nothing in this repository can produce a signed daemon (issue #30, M5).
    /// Callers must treat both as "not installed" and neither as an error.
    ///
    /// **This is an installation hint, never an authentication signal.** It reports the registration
    /// state of a plist relative to `Bundle.main`, and says nothing about who holds
    /// `HelperIdentity.machServiceName` in the bootstrap namespace: a helper installed by any other
    /// route is reachable while this still answers `.notFound`. The only thing that checks the peer is the
    /// code-signing requirement set before `resume()` in `connect()` — on its replies; see there. A caller
    /// that reads `.enabled` as a reason to skip that has removed the peer validation entirely.
    public func serviceStatus() -> SMAppService.Status {
        SMAppService.daemon(plistName: HelperIdentity.plistName).status
    }

    /// Whether this build carries a team ID the peer requirement can be built from. An availability hint for
    /// the UI (spec §2); `connect()` enforces the same condition itself and does not rely on this.
    public var hasUsableTeamID: Bool { HelperIdentity.isUsableTeamID(team) }

    /// Whether the daemon's launchd plist ships in this bundle, where `SMAppService.daemon` looks for it —
    /// `bundleURL` says what "this bundle" is for a CLI started through a symlink.
    /// `scripts/bundle-app.sh` puts it there only with `--with-helper`, and a build without it gives
    /// `register()` nothing to register — so the UI must not offer to (ADR-0007; operator decision
    /// 2026-09-27). A hint, like `serviceStatus()`: it says nothing about who holds the Mach name.
    public var bundlesDaemon: Bool {
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperIdentity.plistName)").path)
    }

    /// Whether the running code is signed by the team this client validates the daemon against (carried note
    /// 5 of the 2026-09-27 permissions plan). An unsigned or ad hoc `bundle-app.sh --team … --with-helper`
    /// build carries a usable `team` and the daemon's plist, yet nothing it registered could be reached: both
    /// requirements demand a Developer ID chain with that team. Whether `register()` itself fails for such a
    /// build is unmeasured (helper-security review of deliverable 4). A button-visibility hint only:
    /// `connect()`'s requirement checks the peer and never reads this.
    public var isSignedByItsTeam: Bool { hasUsableTeamID && runningTeam() == team }

    /// The team identifier in the running code's own signature, or nil when it carries none — ad hoc,
    /// unsigned, or unreadable. Read from the signature, never from `team`: the constant is what the build
    /// script substituted, not what the code is signed with.
    static func teamOfRunningCode() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Registration (deliverable 4 of the 2026-09-27 permissions plan)
    //
    // **Never called live.** No build has had a real Developer ID team ID (M5, issue #30), and both ends
    // of the connection require one. The decisions around these calls — when to register, how long to
    // wait, what counts as approved — live in Core's `HelperApprovalFlow`, tested with a fake.

    /// Registers the daemon. For a daemon this lands in "requires approval": the user approves it in System
    /// Settings ▸ General ▸ Login Items & Extensions, with administrator authentication.
    public func register() throws {
        try SMAppService.daemon(plistName: HelperIdentity.plistName).register()
    }

    /// Removes the registration, so no stale Background Task Management entry outlives the user's intent
    /// (SECURITY_MODEL.md, Registration).
    public func unregister() async throws {
        try await SMAppService.daemon(plistName: HelperIdentity.plistName).unregister()
    }

    /// Opens System Settings at Login Items & Extensions, where the user approves the helper.
    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Verbs (never run live, #30)

    public func createVaultDirectory(volumeUUID: String) async throws -> HelperResult {
        try await send { helper, reply in helper.createVaultDirectory(volumeUUID: volumeUUID, reply: reply) }
    }

    public func removeRegenerableSystemDirectoryContents(target: HelperCleanupTarget) async throws -> HelperResult {
        try await send { helper, reply in helper.removeRegenerableSystemDirectoryContents(target: target.rawValue, reply: reply) }
    }

    /// One message over one connection, then the connection is invalidated.
    ///
    /// **The peer check is `connect()`'s and only `connect()`'s**, whatever `serviceStatus()` reports: a reply
    /// from a peer that fails the requirement is never returned. The request is still delivered to whoever
    /// holds the Mach name (see `connect()`).
    ///
    /// **Exactly one outcome.** XPC calls the reply or the error handler, exactly once (NSXPCConnection.h, and
    /// measured with `invalidate()` after the reply and inside it; helper-security review of deliverable 4).
    /// `ResumeOnce` does not rely on that: a second call — a violated contract, or a later change here — is
    /// dropped instead of crashing the process.
    ///
    /// **No timeout** (helper-security review of deliverable 4, advisory A2): a daemon that takes the message and
    /// never replies leaves this call pending, and the connection open, until the daemon or its connection dies.
    /// Declared, not fixed.
    func send(_ message: (any XCodeVaultHelperXPC, @escaping @Sendable (HelperResult) -> Void) -> Void) async throws -> HelperResult {
        let connection = try connect()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: Failure.connectionFailed(error.localizedDescription))
            }
            guard let helper = proxy as? any XCodeVaultHelperXPC else {
                once.resume(throwing: Failure.unexpectedProxy)
                return
            }
            message(helper) { result in once.resume(returning: result) }
        }
    }
}

/// Resumes a continuation at most once. `@unchecked Sendable` because every access is under the lock.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
