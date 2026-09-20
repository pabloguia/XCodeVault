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
/// **What exists here and what does not (issue #30).** Everything up to and including the moment
/// the connection is configured is here and unit-tested. Actually *talking* to a helper is not:
/// `SMAppService` will not register an unsigned daemon, so no verb has been driven end to end. That
/// is M5 and the compatibility matrix records it as pending, not as working.
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
                return "The helper is not registered with launchd (\(s)). Run the app once to install it, or see SECURITY_MODEL.md."
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

    public init() {
        self.team = HelperClient.teamID
        self.makeConnection = { name in
            // `.privileged` is what makes this reach a *root* LaunchDaemon in the global bootstrap
            // namespace rather than a per-user agent of the same name.
            NSXPCConnection(machServiceName: name, options: .privileged)
        }
    }

    init(team: String, makeConnection: @escaping @Sendable (String) -> NSXPCConnection) {
        self.team = team
        self.makeConnection = makeConnection
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
    /// The ordering matters and is the whole of the peer validation: the requirement is set
    /// **before** `resume()`, so no message can be exchanged with an unvalidated peer. Setting it
    /// afterwards would leave a window in which the connection is live and unconstrained.
    public func connect() throws -> NSXPCConnection {
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
    /// route is reachable while this still answers `.notFound`. The only thing that authenticates the
    /// peer is the code-signing requirement set before `resume()` in `connect()`. A caller that reads
    /// `.enabled` as a reason to skip that has removed the peer validation entirely.
    public func serviceStatus() -> SMAppService.Status {
        SMAppService.daemon(plistName: HelperIdentity.plistName).status
    }
}
