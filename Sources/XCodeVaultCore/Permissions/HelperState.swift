import ServiceManagement

/// Where the privileged helper stands for this build, as the app and the CLI present it (spec §2).
///
/// **An installation hint, never an authentication signal.** It comes from `SMAppService`'s view of a
/// plist relative to this bundle; `HelperClient.serviceStatus()` explains why that says nothing about
/// who holds the Mach name. Every connection is still checked against the helper's code signature in
/// `HelperClient.connect()`, and nothing may skip that because this reads `.enabled`.
public enum HelperState: String, Sendable, Codable, CaseIterable {
    /// The helper is unavailable to this build: no usable Apple team ID, or the daemon is not in the bundle.
    case unavailableInThisBuild
    case notInstalled
    case awaitingApproval
    case enabled

    /// - Parameters:
    ///   - status: `SMAppService`'s answer for the daemon's plist.
    ///   - teamIDIsUsable: `HelperIdentity.isUsableTeamID` of the team substituted at bundle time.
    ///   - daemonIsBundled: whether the daemon's launchd plist ships inside this bundle.
    public init(status: SMAppService.Status, teamIDIsUsable: Bool, daemonIsBundled: Bool) {
        // The build first: without a usable team ID `connect()` refuses every connection, and without the
        // plist there is nothing to register. Either alone makes the helper unavailable to this build, whatever
        // launchd reports (ADR-0007: a button that cannot work is never shown).
        guard teamIDIsUsable, daemonIsBundled else {
            self = .unavailableInThisBuild
            return
        }
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .awaitingApproval
        // `.notFound` is what an unregistered daemon has been measured to answer from this repository;
        // `.notRegistered` is what a signed install is expected to answer, unverified until M5.
        case .notRegistered, .notFound: self = .notInstalled
        // Never `.enabled` for a status nobody has seen: a root action must not run on it.
        @unknown default: self = .notInstalled
        }
    }
}
