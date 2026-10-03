/// What the GUI shows about permissions, decided here so it is testable (spec §4): the app target has
/// no tests, and a decision nobody can test is the one the next refactor gets wrong.
public enum PermissionPrompts {
    /// Ask for Full Disk Access only at the moment of need (ADR-0007): a scan counted a refusal with `EPERM`,
    /// the errno macOS privacy protection returns, and the grant is not known to be there. A scan that counts
    /// no refusal asks for nothing.
    public static func shouldAskForFullDiskAccess(privacyRefusalCount: Int, state: FullDiskAccessState) -> Bool {
        privacyRefusalCount > 0 && state != .granted
    }
}

extension FullDiskAccessState {
    /// Whether the Access screen's row offers to open the Full Disk Access settings: whenever the grant is not known to be there.
    public var offersOpenSettings: Bool { self != .granted }
}

/// What stands next to an action that needs the privileged helper.
public enum PrivilegedActionControl: Sendable, Equatable {
    /// The helper is enabled: the button runs the action.
    case run
    /// A build that can reach the helper, not yet approved: the button opens the sheet with **Allow**.
    case requestHelper
    /// This build can never reach the helper: no button; "Not in this build" and what to do instead.
    case notAvailableInThisBuild
}

/// The helper row's one button.
public enum HelperRowButton: Sendable, Equatable {
    case install, uninstall, none
}

extension HelperState {
    /// Spec §4's key decision: a control that runs a root action appears only when the helper is enabled, and a
    /// build that cannot reach the helper shows no button at all (ADR-0007).
    public var actionControl: PrivilegedActionControl {
        switch self {
        case .enabled: return .run
        case .notInstalled, .awaitingApproval: return .requestHelper
        case .unavailableInThisBuild: return .notAvailableInThisBuild
        }
    }

    /// **Install…** continues from "waiting for approval" too: it opens Login Items & Extensions and waits.
    public var rowButton: HelperRowButton {
        switch self {
        case .unavailableInThisBuild: return .none
        case .notInstalled, .awaitingApproval: return .install
        case .enabled: return .uninstall
        }
    }
}
