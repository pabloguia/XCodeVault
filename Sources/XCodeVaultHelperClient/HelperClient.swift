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
        /// R8: the helper that answered reports another version than this build's. The authorization is not sent.
        case versionMismatch(String)
        /// R8 round 5: the helper that answered is newer than this build, or of a version it cannot order. Not reinstalled.
        case helperNewer(String)
        /// R8: the user cancelled the system password dialog. Not an error: nothing was asked of the helper.
        case authorizationCanceled
        /// R8: the right was not obtained (wrong password three times, or the authorization service refused).
        case authorizationDenied(Int32)
        /// R8 round 3: the caller could not record the start, so the request was not sent.
        case notStarted
        /// Advisory A2: the helper took the message and did not reply in time. The connection is invalidated, and a
        /// reply that comes later is dropped. Like `connectionFailed`, whether it acted is unknown.
        case timedOut(String)

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
                    + "or from Install… on its Access screen; see SECURITY_MODEL.md."
            case .connectionFailed(let why):
                return "The privileged helper did not reply (\(why)). Whether it acted is unknown; rescan to see."
            case .unexpectedProxy:
                return "The connection did not return the privileged helper's interface. Refusing to use it."
            case .versionMismatch(let v):
                return "The privileged helper that answered is version \(v), not \(HelperIdentity.version). Nothing was sent to it; reinstall the helper."
            case .helperNewer(let v):
                return "A newer XCodeVault installed this helper (version \(v); this copy is \(HelperIdentity.version)); update this copy. "
                    + "Nothing was sent to the helper."
            case .authorizationCanceled:
                return "The administrator password was not given."
            case .authorizationDenied(let status):
                return "Administrator authorization was not granted (\(status))."
            case .notStarted:
                return "The start could not be recorded, so nothing was sent to the helper."
            case .timedOut(let what):
                return "The privileged helper did not reply to \(what) in time. Whether it acted is unknown; rescan to see."
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

    /// launchd's side of the helper as one value, so a test sees every call and none reaches Background Task
    /// Management or opens System Settings: registration, approval and removal never run live before M5 (#30).
    /// Internal, like `makeConnection`: the public initialiser installs `.live` and nothing else can.
    struct Daemon: Sendable {
        let status: @Sendable () -> SMAppService.Status
        let register: @Sendable () throws -> Void
        let unregister: @Sendable () async throws -> Void
        let openSettings: @Sendable () -> Void

        static let live = Daemon(
            status: { SMAppService.daemon(plistName: HelperIdentity.plistName).status },
            register: { try SMAppService.daemon(plistName: HelperIdentity.plistName).register() },
            unregister: { try await SMAppService.daemon(plistName: HelperIdentity.plistName).unregister() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
    let daemon: Daemon

    /// The user's side of the authorization (R8): a fresh `AuthorizationRef`, the right obtained on it with the system
    /// password dialog, and its externalized form. One value so a test fakes all of it and none of it reaches the
    /// authorization service. Internal, like `makeConnection`: the public initialiser installs `.live` only.
    struct Authorizer: Sendable {
        /// Obtains `right` — the dialog appears — and returns the externalized form and a release that destroys the
        /// reference. Throws `Failure.authorizationCanceled` or `.authorizationDenied`.
        let acquire: @Sendable (String) throws -> AcquiredAuthorization

        static let live = Authorizer(acquire: HelperClient.acquireLive)
    }

    struct AcquiredAuthorization: Sendable {
        let externalForm: Data
        let release: @Sendable () -> Void
    }
    let authorizer: Authorizer

    /// How long each kind of message may go unanswered (advisory A2). None of them waits on the user: the password
    /// dialog of `enableOwnership` is answered before the verb is sent (`Authorizer`), not inside a call. Internal, like
    /// `makeConnection`, so a test can wait a fraction of a second; the public initialiser installs `.live`.
    struct Timeouts: Sendable {
        /// `version()` and `begin`: the daemon answers them from memory.
        let opening: TimeInterval
        /// `createVaultDirectory` and `enableOwnership`. Above the daemon's own worst case, so a deadline here never cuts
        /// off an operation the daemon is still legitimately running (helper-security review of A2, M1): `enableOwnership`
        /// runs `diskutil` about ten times (pin, lookup, the identity re-check, the command, the read-back), each under the
        /// daemon's own 120 s kill (`SpawnedDiskutil.timeoutSeconds`), so up to some 1200 s; `HelperClientTimeoutTests`
        /// holds this above that. What it ends is a daemon that never answers, not a slow disk.
        let verb: TimeInterval
        /// The cleanup verb deletes a cache of many gigabytes. Refused by this helper release (ADR-0016), and given at
        /// least a verb's time should it be offered again.
        let cleanup: TimeInterval

        static let live = Timeouts(opening: 15, verb: 1500, cleanup: 1500)
    }
    let timeouts: Timeouts

    public init() {
        self.team = HelperClient.teamID
        self.makeConnection = { name in
            // `.privileged` is what makes this reach a *root* LaunchDaemon in the global bootstrap
            // namespace rather than a per-user agent of the same name.
            NSXPCConnection(machServiceName: name, options: .privileged)
        }
        self.bundleURL = Bundle.main.bundleURL
        self.runningTeam = HelperClient.teamOfRunningCode
        self.daemon = .live
        self.authorizer = .live
        self.timeouts = .live
    }

    init(
        team: String, makeConnection: @escaping @Sendable (String) -> NSXPCConnection, bundleURL: URL = Bundle.main.bundleURL,
        runningTeam: @escaping @Sendable () -> String? = HelperClient.teamOfRunningCode, daemon: Daemon = .live,
        authorizer: Authorizer = .live, timeouts: Timeouts = .live
    ) {
        self.team = team
        self.makeConnection = makeConnection
        self.bundleURL = bundleURL
        self.runningTeam = runningTeam
        self.daemon = daemon
        self.authorizer = authorizer
        self.timeouts = timeouts
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
    /// measured the same day; what keeps an old daemon from acting on a verb is `opening(_:)` (M5, ADR-0016): the
    /// verb is sent only after a validated `version()` and `begin` on the same connection.
    ///
    /// Internal (the same review): `send` and `enableOwnership` are its only callers, and the compiler rather than review keeps it so.
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
        daemon.status()
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
        try daemon.register()
    }

    /// Removes the registration, so no stale Background Task Management entry outlives the user's intent
    /// (SECURITY_MODEL.md, Registration).
    public func unregister() async throws {
        try await daemon.unregister()
    }

    /// Opens System Settings at Login Items & Extensions, where the user approves the helper.
    public func openApprovalSettings() {
        daemon.openSettings()
    }

    // MARK: - Verbs (createVaultDirectory never run live, #30; the cleanup verb is refused by this helper release, ADR-0016)

    public func createVaultDirectory(volumeUUID: String) async throws -> HelperResult {
        try await send("createVaultDirectory", within: timeouts.verb) { helper, reply in helper.createVaultDirectory(volumeUUID: volumeUUID, reply: reply) }
    }

    public func removeRegenerableSystemDirectoryContents(target: HelperCleanupTarget) async throws -> HelperResult {
        try await send("removeRegenerableSystemDirectoryContents", within: timeouts.cleanup) { helper, reply in
            helper.removeRegenerableSystemDirectoryContents(target: target.rawValue, reply: reply)
        }
    }

    /// R8 (ADR-0014): turns ownership on for the volume `volumeUUID`. EXPERIMENTAL (rule 10). One connection, in order:
    ///
    ///   1. `opening(_:)`: `version()` checked, then `begin`. A reply from a peer that fails the code-signing requirement
    ///      never comes back (`connect()`), and neither request carries anything. Without it the externalized
    ///      authorization would go to whoever holds the Mach name, since the requirement checks replies, not requests;
    ///   2. the right, on a fresh reference, with the system password dialog (`Authorizer`). Cancel returns a result
    ///      with code `authorizationCanceled` and nothing is sent;
    ///   3. the verb, with the reference's externalized form;
    ///   4. the reference destroyed whatever happened, so the next call asks for the password again.
    public func enableOwnership(volumeUUID: String, authorized: @escaping @Sendable () -> Bool = { true }) async throws -> HelperResult {
        let connection = try connect()
        defer { connection.invalidate() }
        if let refusal = try await opening(connection) { return refusal }
        let right = HelperIdentity.enableOwnershipRight
        let authorizer = self.authorizer
        let acquired: AcquiredAuthorization
        do {
            acquired = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AcquiredAuthorization, any Error>) in
                // Off the caller's thread: the dialog blocks until the user answers.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try authorizer.acquire(right)) } catch { continuation.resume(throwing: error) }
                }
            }
        } catch Failure.authorizationCanceled {
            // A result, not a throw, so the app can tell a cancel without naming this type (helper-invariants).
            return HelperResult(ok: false, message: Failure.authorizationCanceled.description, code: .authorizationCanceled)
        }
        defer { acquired.release() }
        // The caller's go-ahead (the journal's `.started`); without it nothing is sent and the reference is destroyed.
        guard authorized() else { throw Failure.notStarted }
        return try await call(connection, "enableOwnership", within: timeouts.verb) { helper, reply in
            helper.enableOwnership(volumeUUID: volumeUUID, authorization: acquired.externalForm, reply: reply)
        }
    }

    /// Semantic-version precedence of two `MAJOR.MINOR.PATCH[-PRERELEASE]` strings (R8 fix round 5, F2), or nil when
    /// either does not parse. A pre-release orders before its release (`0.2.1-dev` < `0.2.1`); two pre-releases of the
    /// same version order by their identifiers, numerically where both are numbers. Build metadata (`+…`) is ignored.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = SemanticVersion(a), let y = SemanticVersion(b) else { return nil }
        return x.compare(y)
    }

    struct SemanticVersion {
        let core: [Int]
        let prerelease: [String]

        init?(_ raw: String) {
            let noBuild = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard numbers.count == 3 else { return nil }
            var core: [Int] = []
            for n in numbers {
                guard !n.isEmpty, n.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(n) else { return nil }
                core.append(v)
            }
            self.core = core
            if parts.count == 2 {
                let ids = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { return nil }
                prerelease = ids
            } else {
                prerelease = []
            }
        }

        func compare(_ other: SemanticVersion) -> ComparisonResult {
            for (l, r) in zip(core, other.core) where l != r { return l < r ? .orderedAscending : .orderedDescending }
            switch (prerelease.isEmpty, other.prerelease.isEmpty) {
            case (true, true): return .orderedSame
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            case (false, false): break
            }
            for (l, r) in zip(prerelease, other.prerelease) where l != r {
                switch (Int(l), Int(r)) {
                case (let a?, let b?): return a < b ? .orderedAscending : .orderedDescending
                case (.some, nil): return .orderedAscending
                case (nil, .some): return .orderedDescending
                case (nil, nil): return l < r ? .orderedAscending : .orderedDescending
                }
            }
            if prerelease.count == other.prerelease.count { return .orderedSame }
            return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
        }
    }

    /// The live `Authorizer`: never called by a test.
    static func acquireLive(_ right: String) throws -> AcquiredAuthorization {
        var created: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let ref = created else { throw Failure.authorizationDenied(status) }
        let granted = right.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights], nil)
            }
        }
        guard granted == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            if granted == errAuthorizationCanceled { throw Failure.authorizationCanceled }
            throw Failure.authorizationDenied(granted)
        }
        var form = AuthorizationExternalForm()
        let made = AuthorizationMakeExternalForm(ref, &form)
        guard made == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            throw Failure.authorizationDenied(made)
        }
        let data = withUnsafeBytes(of: &form.bytes) { Data($0) }
        // `AuthorizationRef` is an opaque pointer; freeing it once, on this path, is the whole of its lifetime.
        nonisolated(unsafe) let owned = ref
        return AcquiredAuthorization(externalForm: data, release: { AuthorizationFree(owned, [.destroyRights]) })
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
    /// **Every message has a deadline** (advisory A2, helper-security review of deliverable 4): `call`'s `within`. A daemon
    /// that takes a message and never replies used to leave the call pending, and the connection open, until the daemon
    /// or its connection died — the app waiting with it.
    func send(
        _ what: String, within timeout: TimeInterval, _ message: (any XCodeVaultHelperXPC, @escaping @Sendable (HelperResult) -> Void) -> Void
    ) async throws -> HelperResult {
        let connection = try connect()
        defer { connection.invalidate() }
        if let refusal = try await opening(connection) { return refusal }
        return try await call(connection, what, within: timeout, message)
    }

    /// The M5 round trip every verb waits for (ADR-0016), on the connection the verb will use; nil when the verb may go.
    ///
    ///   1. `version()`, which every helper since 0.1 answers. A different version is a result, not a throw, so the app
    ///      can tell an outdated helper without naming this type (helper-invariants) and reinstall it (R8 fix round 4) —
    ///      but only an OLDER one (round 5, F2). A newer helper, or one whose version cannot be ordered, is left alone:
    ///      reinstalling would downgrade it.
    ///   2. `begin(clientVersion:)`, which a helper of this version answers. Its refusal is returned as it came.
    ///
    /// A deadline met here is a result too, `helperDidNotAnswer`: the verb was certainly not sent, which a timeout during
    /// the verb cannot say (helper-security review of A2, M2).
    func opening(_ connection: NSXPCConnection) async throws -> HelperResult? {
        do {
            return try await openingCalls(connection)
        } catch Failure.timedOut(let what) {
            return HelperResult(
                ok: false, message: "The privileged helper did not answer \(what) in time, so nothing was sent to it. Try again in a moment.",
                code: .helperDidNotAnswer)
        }
    }

    private func openingCalls(_ connection: NSXPCConnection) async throws -> HelperResult? {
        let version: String = try await call(connection, "version", within: timeouts.opening) { helper, reply in helper.version(reply: reply) }
        guard version == HelperIdentity.version else {
            if Self.compareVersions(version, HelperIdentity.version) == .orderedAscending {
                return HelperResult(ok: false, message: Failure.versionMismatch(version).description, code: .helperOutdated)
            }
            return HelperResult(ok: false, message: Failure.helperNewer(version).description, code: .helperNewer)
        }
        let begun: HelperResult = try await call(connection, "begin", within: timeouts.opening) { helper, reply in
            helper.begin(clientVersion: HelperIdentity.version, reply: reply)
        }
        return begun.ok ? nil : begun
    }

    /// One message on an open connection, with its own error handler and a deadline. `ResumeOnce`, for the reasons `send`
    /// gives, and because the deadline is a third way to finish: whichever of the reply, the error handler and the timer
    /// comes first is the outcome, and the others are dropped.
    ///
    /// The timer touches only the continuation. The connection is invalidated by the caller's `defer` (`send`,
    /// `enableOwnership`), which runs as soon as the timeout is thrown, so the daemon's reply, if it ever comes, goes
    /// nowhere. A reply or an error that comes first cancels the timer, so it does not hold the call for its full length
    /// (review of A2, L1 and L2).
    func call<T: Sendable>(
        _ connection: NSXPCConnection, _ what: String, within timeout: TimeInterval,
        _ message: (any XCodeVaultHelperXPC, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let deadline = DispatchWorkItem { once.resume(throwing: Failure.timedOut(what)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if once.resume(throwing: Failure.connectionFailed(error.localizedDescription)) { deadline.cancel() }
            }
            guard let helper = proxy as? any XCodeVaultHelperXPC else {
                if once.resume(throwing: Failure.unexpectedProxy) { deadline.cancel() }
                return
            }
            message(helper) { result in if once.resume(returning: result) { deadline.cancel() } }
        }
    }
}

/// Resumes a continuation at most once. `@unchecked Sendable` because every access is under the lock.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    /// True when this call resumed the continuation, false when an earlier one had.
    @discardableResult func resume(returning value: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: value)
        return true
    }
    @discardableResult func resume(throwing error: any Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: error)
        return true
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
