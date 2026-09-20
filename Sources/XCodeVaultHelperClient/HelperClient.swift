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
    /// Read-only and safe to call unsigned — it answers `.notRegistered` rather than failing, which
    /// is what lets the app tell a user why nothing works instead of appearing broken.
    public func serviceStatus() -> SMAppService.Status {
        SMAppService.daemon(plistName: HelperIdentity.plistName).status
    }
}
