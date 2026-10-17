/// R8 (ADR-0014): how the app offers to turn ownership on for a volume — one click through the privileged helper, or the
/// R7-D guided route (Finder's Get Info, or the copied `sudo diskutil enableOwnership`) with the reason the click is not
/// offered. Decided here so it is tested; the views only render it.
public enum OwnershipRoute: Sendable, Equatable {
    /// **Turn On Ownership**: the helper's `enableOwnership`, behind the system password dialog. EXPERIMENTAL (rule 10).
    case oneClick
    /// The helper is being installed, approved or asked; the button is replaced by progress.
    case working
    /// The guided route, and why the click is not offered (or did not work).
    case guided(OwnershipFallback)

    /// - Parameters:
    ///   - helper: the helper's state for this build (`HelperState`).
    ///   - working: an `enableOwnership` request is in flight for this volume.
    ///   - fallback: why the last request for this volume fell back, if it did.
    public static func decide(helper: HelperState, working: Bool, fallback: OwnershipFallback?) -> OwnershipRoute {
        if working { return .working }
        if helper == .unavailableInThisBuild { return .guided(.unavailableInThisBuild) }
        if let fallback { return .guided(fallback) }
        return .oneClick
    }

    /// What the guided route shows after the click: nothing after success or a cancelled password dialog (the click is
    /// offered again), the reason otherwise.
    public static func fallback(after outcome: PrivilegedActionOutcome) -> OwnershipFallback? {
        switch outcome {
        case .done, .cancelled: return nil
        case .refused(let why), .failed(let why), .helperOutdated(let why): return .didNotWork(why)
        }
    }

    /// The same, after waiting for the helper's approval.
    public static func fallback(after approval: HelperApprovalOutcome) -> OwnershipFallback? {
        switch approval {
        case .enabled, .cancelled: return nil
        case .notAvailableInThisBuild: return .unavailableInThisBuild
        case .timedOut: return .approvalNotGiven(L10n.tr("app.helper.error.timedOut"))
        case .failed(let why): return .approvalNotGiven(why)
        }
    }
}

/// Why the guided route is shown instead of the click.
public enum OwnershipFallback: Sendable, Equatable {
    /// This build cannot reach the helper: not signed by a usable team, or the daemon is not in the bundle.
    case unavailableInThisBuild
    /// The helper was not approved in System Settings, or its registration failed.
    case approvalNotGiven(String)
    /// The helper refused, failed, or could not be reached; its message.
    case didNotWork(String)

    public var reason: String { reason(in: L10n.locale) }

    public func reason(in locale: String) -> String {
        switch self {
        case .unavailableInThisBuild: return L10n.tr("app.ownership.fallback.unavailable", locale: locale)
        case .approvalNotGiven(let why): return L10n.tr("app.ownership.fallback.approval", locale: locale, why)
        case .didNotWork(let why): return L10n.tr("app.ownership.fallback.failed", locale: locale, why)
        }
    }
}
