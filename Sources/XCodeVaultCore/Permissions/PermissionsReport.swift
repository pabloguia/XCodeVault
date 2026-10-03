/// `xcodevaultctl permissions`: each permission's state, one sentence of why, and one next step. The
/// texts live in the catalog under `perm.*`, so the CLI and the GUI say the same thing (spec §2, one source of
/// truth). The report itself is a record (`--json`): it keeps the English, whatever the process locale.
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
        let en = L10n.baseLocale
        self.fullDiskAccess = FullDiskAccessEntry(state: fullDiskAccess, why: fullDiskAccess.why(in: en), nextStep: fullDiskAccess.nextStep(in: en))
        self.helper = HelperEntry(state: helper, why: helper.why(in: en), nextStep: helper.nextStep(in: en))
    }
}

/// The plain properties are English (records, `--json`, Core prose); a screen passes `L10n.locale` to the
/// `(in:)` forms.
extension FullDiskAccessState {
    public var displayName: String { displayName(in: L10n.baseLocale) }
    public var why: String { why(in: L10n.baseLocale) }
    public var nextStep: String { nextStep(in: L10n.baseLocale) }

    public func displayName(in locale: String) -> String {
        switch self {
        case .granted: return L10n.tr("perm.fda.state.granted", locale: locale)
        case .notGranted: return L10n.tr("perm.fda.state.notGranted", locale: locale)
        case .unknown: return L10n.tr("perm.fda.state.unknown", locale: locale)
        }
    }

    public func why(in locale: String) -> String {
        switch self {
        case .granted: return L10n.tr("perm.fda.why.granted", locale: locale)
        case .notGranted: return L10n.tr("perm.fda.why.notGranted", locale: locale)
        case .unknown: return L10n.tr("perm.fda.why.unknown", locale: locale)
        }
    }

    /// Conditional on `scan`'s own mark for a size it could not complete, because the grant matters only
    /// where something went unread; ADR-0007 asks at the moment of need, not before.
    public func nextStep(in locale: String) -> String {
        switch self {
        case .granted: return L10n.tr("perm.fda.next.granted", locale: locale)
        case .notGranted: return L10n.tr("perm.fda.next.notGranted", locale: locale, FullDiskAccessProbe.settingsURL)
        case .unknown: return L10n.tr("perm.fda.next.unknown", locale: locale)
        }
    }
}

extension HelperState {
    public var displayName: String { displayName(in: L10n.baseLocale) }
    public var why: String { why(in: L10n.baseLocale) }
    public var nextStep: String { nextStep(in: L10n.baseLocale) }

    public func displayName(in locale: String) -> String {
        switch self {
        case .unavailableInThisBuild: return L10n.tr("perm.helper.state.unavailableInThisBuild", locale: locale)
        case .notInstalled: return L10n.tr("perm.helper.state.notInstalled", locale: locale)
        case .awaitingApproval: return L10n.tr("perm.helper.state.awaitingApproval", locale: locale)
        case .enabled: return L10n.tr("perm.helper.state.enabled", locale: locale)
        }
    }

    public func why(in locale: String) -> String {
        switch self {
        case .unavailableInThisBuild: return L10n.tr("perm.helper.why.unavailableInThisBuild", locale: locale)
        case .notInstalled: return L10n.tr("perm.helper.why.notInstalled", locale: locale)
        case .awaitingApproval: return L10n.tr("perm.helper.why.awaitingApproval", locale: locale)
        case .enabled: return L10n.tr("perm.helper.why.enabled", locale: locale)
        }
    }

    public func nextStep(in locale: String) -> String {
        switch self {
        case .unavailableInThisBuild: return L10n.tr("perm.helper.next.unavailableInThisBuild", locale: locale)
        case .notInstalled: return L10n.tr("perm.helper.next.notInstalled", locale: locale)
        case .awaitingApproval: return L10n.tr("perm.helper.next.awaitingApproval", locale: locale)
        case .enabled: return L10n.tr("perm.helper.next.enabled", locale: locale)
        }
    }
}
