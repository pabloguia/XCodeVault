/// `xcodevaultctl permissions`: each permission's state, one sentence of why, and one next step. The
/// texts live here so the CLI and the GUI say the same thing (spec §2, one source of truth).
public struct PermissionsReport: Sendable, Codable, Equatable {
    public struct FullDiskAccessEntry: Sendable, Codable, Equatable {
        public var state: FullDiskAccessState
        public var why: String
        public var nextStep: String
    }

    public struct HelperEntry: Sendable, Codable, Equatable {
        public var state: HelperState
        public var why: String
        public var nextStep: String
    }

    public var fullDiskAccess: FullDiskAccessEntry
    public var helper: HelperEntry

    public init(fullDiskAccess: FullDiskAccessState, helper: HelperState) {
        self.fullDiskAccess = FullDiskAccessEntry(state: fullDiskAccess, why: fullDiskAccess.why, nextStep: fullDiskAccess.nextStep)
        self.helper = HelperEntry(state: helper, why: helper.why, nextStep: helper.nextStep)
    }
}

extension FullDiskAccessState {
    public var displayName: String {
        switch self {
        case .granted: return "granted"
        case .notGranted: return "not granted"
        case .unknown: return "unknown"
        }
    }

    public var why: String {
        switch self {
        case .granted:
            return "This process can open the one file only Full Disk Access opens (H15's indicator; nothing is read from it)."
        case .notGranted:
            return "macOS refused this process the one file only Full Disk Access opens, so folders macOS protects cannot be measured."
        case .unknown:
            return "The check could not tell: the indicator file failed to open for a reason other than macOS privacy protection."
        }
    }

    /// Conditional on `scan`'s own mark for a size it could not complete, because the grant matters only
    /// where something went unread; ADR-0007 asks at the moment of need, not before.
    public var nextStep: String {
        switch self {
        case .granted:
            return "Nothing to do."
        case .notGranted:
            return "Only if `scan` marks a size [partial: unreadable entries]: System Settings ▸ Privacy & Security ▸ Full Disk Access, "
                + "switch on the app you run XCodeVault from (XCodeVault.app, or your terminal for xcodevaultctl), then scan again. "
                + FullDiskAccessProbe.settingsURL
        case .unknown:
            return "Nothing to do unless `scan` marks a size [partial: unreadable entries]; then grant Full Disk Access as for \"not granted\"."
        }
    }
}

extension HelperState {
    public var displayName: String {
        switch self {
        case .unavailableInThisBuild: return "not available in this build"
        case .notInstalled: return "not installed"
        case .awaitingApproval: return "waiting for approval"
        case .enabled: return "enabled"
        }
    }

    public var why: String {
        switch self {
        case .unavailableInThisBuild:
            return "This build cannot reach the privileged helper: it is not signed by a usable Apple team, or the helper is not in it. "
                + "That takes a signed build that includes the helper (issue #30)."
        case .notInstalled:
            return "The helper is not installed. Only actions that need root use it."
        case .awaitingApproval:
            return "The helper is registered, and macOS is waiting for an administrator to approve it."
        case .enabled:
            return "macOS reports the helper as enabled. That is an installation hint: every connection is still checked "
                + "against the helper's code signature."
        }
    }

    public var nextStep: String {
        switch self {
        case .unavailableInThisBuild:
            return "Actions that need root stay manual. Where there is a manual route, `doctor` or `vault init` prints it."
        case .notInstalled:
            return "Nothing to do until you choose an action that needs root; the app's Permissions section can also install it ahead of time."
        case .awaitingApproval:
            return "System Settings ▸ General ▸ Login Items & Extensions: switch XCodeVault on (administrator password)."
        case .enabled:
            return "Nothing to do. The app's Permissions section can uninstall it."
        }
    }
}
