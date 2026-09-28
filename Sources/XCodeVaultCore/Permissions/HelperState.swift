import ServiceManagement

/// Where the privileged helper stands for this build, as the app and the CLI present it (spec §2).
///
/// **An installation hint, never an authentication signal.** It comes from `SMAppService`'s view of a
/// plist relative to this bundle; `HelperClient.serviceStatus()` explains why that says nothing about
/// who holds the Mach name. Every connection still checks the helper's replies against its code signature in
/// `HelperClient.connect()`, and nothing may skip that because this reads `.enabled`.
public enum HelperState: String, Sendable, Codable, CaseIterable {
    /// The helper is unavailable to this build: not signed by a usable Apple team, or the daemon is not in the
    /// bundle.
    case unavailableInThisBuild
    case notInstalled
    case awaitingApproval
    case enabled

    /// - Parameters:
    ///   - status: `SMAppService`'s answer for the daemon's plist.
    ///   - teamIDIsUsable: `HelperIdentity.isUsableTeamID` of the team substituted at bundle time.
    ///   - signedByThatTeam: whether the running code's own signature carries that team
    ///     (`HelperClient.isSignedByItsTeam`).
    ///   - daemonIsBundled: whether the daemon's launchd plist ships inside this bundle.
    public init(status: SMAppService.Status, teamIDIsUsable: Bool, signedByThatTeam: Bool, daemonIsBundled: Bool) {
        // The build first: without a usable team ID `connect()` refuses every connection; without that team in
        // the running code's signature nothing it registered could be reached, because both requirements demand
        // a Developer ID chain with that team — an unsigned `--team … --with-helper` build has the first and not
        // this (carried note 5 of the 2026-09-27 permissions plan; whether its `register()` fails outright is
        // unmeasured); and without the plist there is nothing to register. Any one makes the helper unavailable to this build, whatever launchd
        // reports (ADR-0007: a button that cannot work is never shown).
        guard teamIDIsUsable, signedByThatTeam, daemonIsBundled else {
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
