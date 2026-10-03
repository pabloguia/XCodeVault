/// The Access checklist (spec 2026-10-03 §6.3): one row per need, its state, one sentence of why in terms of what it
/// blocks, and at most one action. Decided here so the view only renders it.
///
/// **No text is made here.** A row carries catalog keys (`app.access.*`) and the facts their sentences take
/// (`blocksBytes`, `blocksFolders`); the app renders them with `L10n.tr`. `allKeys` lists every key a row can return,
/// so a test can hold the catalog to it.
///
/// No new mechanism (ADR-0007): the actions are the existing ones — the Full Disk Access pane, a re-check of the probe,
/// and the `SMAppService` install/approval flow. XCodeVault never asks for the user's password.
public enum AccessChecklist {
    public enum Need: String, Sendable, CaseIterable {
        case fullDiskAccess, privilegedHelper
    }

    public enum State: String, Sendable {
        case granted
        /// Not there and obtainable: Full Disk Access not granted, or the helper not installed.
        case missing
        /// Registered, waiting for the user's switch in Login Items & Extensions.
        case awaitingApproval
        /// The probe could not tell (`FullDiskAccessState.unknown`). Never treated as `missing`.
        case unknown
        /// This build can never reach the helper (`HelperState.unavailableInThisBuild`).
        case unavailableInThisBuild
    }

    /// What the row's action does. `guidanceOnly` is text that says what to do instead, never a button.
    public enum Action: String, Sendable {
        case openFullDiskAccessSettings
        case recheckFullDiskAccess
        /// `HelperState.rowButton == .install`: registers, or continues to the approval it waits for.
        case installHelper
        case guidanceOnly
    }

    public struct Row: Sendable, Equatable {
        public let need: Need
        public let state: State
        public let whyKey: String
        /// Nil exactly when `action` is nil: the need is met and there is nothing to do.
        public let actionKey: String?
        public let action: Action?
        /// Bytes the missing access holds back, when they are measurable: the helper's root-only delete rows. Never for
        /// Full Disk Access — what it cannot read it cannot measure.
        public let blocksBytes: UInt64?
        /// Folders the scan could not read because privacy protection refused them (`ScanSummary.privacyRefusalCount`).
        public let blocksFolders: Int?
    }

    public enum Key {
        public static let fdaWhyGranted = "app.access.fda.why.granted"
        /// Takes `blocksFolders`.
        public static let fdaWhyUnreadableFolders = "app.access.fda.why.unreadableFolders"
        public static let fdaWhyUnreadable = "app.access.fda.why.unreadable"
        public static let fdaWhyProtected = "app.access.fda.why.protected"
        public static let fdaWhyUnknown = "app.access.fda.why.unknown"
        public static let fdaActionOpenSettings = "app.access.fda.action.openSettings"
        public static let fdaActionRecheck = "app.access.fda.action.recheck"
        public static let helperWhyEnabled = "app.access.helper.why.enabled"
        /// Takes `blocksBytes`.
        public static let helperWhyRootOnlyBytes = "app.access.helper.why.rootOnlyBytes"
        public static let helperWhyRootActions = "app.access.helper.why.rootActions"
        public static let helperActionInstall = "app.access.helper.action.install"
        public static let helperActionApprove = "app.access.helper.action.approve"
        /// What to do instead in a build without the helper: the signed release, or the manual route `doctor` prints.
        public static let helperActionSignedReleaseOrCLI = "app.access.helper.action.signedReleaseOrCLI"
    }

    /// Every key a row can return.
    public static let allKeys: [String] = [
        Key.fdaWhyGranted, Key.fdaWhyUnreadableFolders, Key.fdaWhyUnreadable, Key.fdaWhyProtected, Key.fdaWhyUnknown,
        Key.fdaActionOpenSettings, Key.fdaActionRecheck, Key.helperWhyEnabled, Key.helperWhyRootOnlyBytes, Key.helperWhyRootActions,
        Key.helperActionInstall, Key.helperActionApprove, Key.helperActionSignedReleaseOrCLI,
    ]

    /// - Parameters:
    ///   - savings: `ScanReport.savings`; its `isLowerBound` says some counted item could not be fully read.
    ///   - plan: the plan rows; only delete rows noted `rootOnly` count towards the helper (`clean` never deletes them
    ///     without root).
    ///   - privacyRefusalCount: `ScanSummary.privacyRefusalCount`, the folders privacy protection refused.
    public static func rows(
        fullDiskAccess: FullDiskAccessState, helper: HelperState, savings: SavingsSummary, plan: [SavingsPlanRow], privacyRefusalCount: Int = 0
    ) -> [Row] {
        [fullDiskAccessRow(fullDiskAccess, savings: savings, refusals: privacyRefusalCount), helperRow(helper, plan: plan)]
    }

    /// The Overview's one access banner (spec §6.2: "at most one"): the first row that holds back something the scan
    /// measured, or nil. Full Disk Access holds something back when it is not granted and folders were refused or a size
    /// is a lower bound; the helper, when it is not enabled and root-only delete rows wait on it (`blocksBytes`). A row that
    /// holds nothing back stays in the Access view and never nags from the Overview.
    public static func banner(
        fullDiskAccess: FullDiskAccessState, helper: HelperState, savings: SavingsSummary, plan: [SavingsPlanRow], privacyRefusalCount: Int = 0
    ) -> Row? {
        rows(fullDiskAccess: fullDiskAccess, helper: helper, savings: savings, plan: plan, privacyRefusalCount: privacyRefusalCount).first { row in
            guard row.state != .granted else { return false }
            return switch row.need {
            case .fullDiskAccess: privacyRefusalCount > 0 || savings.isLowerBound
            case .privilegedHelper: row.blocksBytes != nil
            }
        }
    }

    static func fullDiskAccessRow(_ state: FullDiskAccessState, savings: SavingsSummary, refusals: Int) -> Row {
        switch state {
        case .granted:
            return Row(need: .fullDiskAccess, state: .granted, whyKey: Key.fdaWhyGranted, actionKey: nil, action: nil, blocksBytes: nil, blocksFolders: nil)
        case .unknown:
            // ADR-0007: "could not tell" is not a reason to send the user to Settings.
            return Row(
                need: .fullDiskAccess, state: .unknown, whyKey: Key.fdaWhyUnknown, actionKey: Key.fdaActionRecheck, action: .recheckFullDiskAccess,
                blocksBytes: nil, blocksFolders: nil)
        case .notGranted:
            let why = refusals > 0 ? Key.fdaWhyUnreadableFolders : savings.isLowerBound ? Key.fdaWhyUnreadable : Key.fdaWhyProtected
            return Row(
                need: .fullDiskAccess, state: .missing, whyKey: why, actionKey: Key.fdaActionOpenSettings, action: .openFullDiskAccessSettings,
                blocksBytes: nil, blocksFolders: refusals > 0 ? refusals : nil)
        }
    }

    static func helperRow(_ state: HelperState, plan: [SavingsPlanRow]) -> Row {
        let rootOnly = plan.filter { $0.option.bucket == .deleteAndRegenerate && $0.noteIDs.contains("rootOnly") }.reduce(UInt64(0)) { $0 + $1.bytes }
        let why = rootOnly > 0 ? Key.helperWhyRootOnlyBytes : Key.helperWhyRootActions
        let blocks = rootOnly > 0 ? rootOnly : nil
        return switch state {
        case .enabled:
            Row(need: .privilegedHelper, state: .granted, whyKey: Key.helperWhyEnabled, actionKey: nil, action: nil, blocksBytes: nil, blocksFolders: nil)
        case .notInstalled:
            Row(
                need: .privilegedHelper, state: .missing, whyKey: why, actionKey: Key.helperActionInstall, action: .installHelper, blocksBytes: blocks,
                blocksFolders: nil)
        case .awaitingApproval:
            Row(
                need: .privilegedHelper, state: .awaitingApproval, whyKey: why, actionKey: Key.helperActionApprove, action: .installHelper,
                blocksBytes: blocks, blocksFolders: nil)
        case .unavailableInThisBuild:
            // §6.3: what to do instead, never a bare "not available in this build".
            Row(
                need: .privilegedHelper, state: .unavailableInThisBuild, whyKey: why, actionKey: Key.helperActionSignedReleaseOrCLI,
                action: .guidanceOnly, blocksBytes: blocks, blocksFolders: nil)
        }
    }
}
