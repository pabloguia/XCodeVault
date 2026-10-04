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

        /// What to do once the button has done its part, said next to it: the Full Disk Access button tries to register
        /// the app and opens the pane (`FullDiskAccessRegistration`). H16 is verified on macOS 26.7.1 (the user's check,
        /// 2026-10-04), so the text says the app is in the list; other versions are unmeasured, so it keeps the **+**
        /// fallback. Nil for every other row. It never claims the app turns the switch on: only the user can.
        public var hintKey: String? { action == .openFullDiskAccessSettings ? Key.fdaHintInList : nil }

        /// The tooltip beside a row's guidance (R5, HIG review X6): the guidance itself is one line, and the manual route
        /// — the commands that print the step to run — is here. Nil for every row with a button.
        public var helpKey: String? { action == .guidanceOnly ? Key.helperManualRoute : nil }

        /// The need's name: the titles `xcodevaultctl permissions` prints.
        public var titleKey: String { need == .fullDiskAccess ? Key.fdaTitle : Key.helperTitle }

        /// Whether the missing access holds anything back (R5, HIG review A1). Full Disk Access that is off while every
        /// folder the scan reached was read (`fdaWhyProtected`) is optional: the row says "Off" with a neutral symbol, not
        /// a failure. Every other row is needed or met.
        public var isNeeded: Bool { !(need == .fullDiskAccess && state == .missing && whyKey == Key.fdaWhyProtected) }

        /// The row's status word, shown beside a symbol (never color alone).
        public var statusKey: String {
            switch (need, state) {
            case (.fullDiskAccess, .granted): Key.fdaStatusGranted
            case (.fullDiskAccess, .unknown): Key.fdaStatusUnknown
            // Optional, not missing: nothing the scan reached was refused (`isNeeded`).
            case (.fullDiskAccess, .missing) where whyKey == Key.fdaWhyProtected: Key.fdaStatusOff
            // Full Disk Access has no approval step and is in every build: only "missing" is left.
            case (.fullDiskAccess, _): Key.fdaStatusMissing
            case (.privilegedHelper, .granted): Key.helperStatusEnabled
            case (.privilegedHelper, .awaitingApproval): Key.helperStatusAwaitingApproval
            case (.privilegedHelper, .unavailableInThisBuild): Key.helperStatusUnavailable
            // The helper's probe always tells: `unknown` does not arise, and reads as not installed.
            case (.privilegedHelper, _): Key.helperStatusMissing
            }
        }
    }

    public enum Key {
        public static let fdaTitle = "perm.fda.title"
        public static let helperTitle = "perm.helper.title"
        public static let fdaStatusGranted = "app.access.status.fda.granted"
        public static let fdaStatusMissing = "app.access.status.fda.missing"
        public static let fdaStatusUnknown = "app.access.status.fda.unknown"
        /// Full Disk Access off while nothing needs it (`Row.isNeeded`).
        public static let fdaStatusOff = "app.access.status.fda.off"
        public static let helperStatusEnabled = "app.access.status.helper.enabled"
        public static let helperStatusMissing = "app.access.status.helper.missing"
        public static let helperStatusAwaitingApproval = "app.access.status.helper.awaitingApproval"
        public static let helperStatusUnavailable = "app.access.status.helper.unavailable"
        public static let fdaWhyGranted = "app.access.fda.why.granted"
        /// Takes `blocksFolders`.
        public static let fdaWhyUnreadableFolders = "app.access.fda.why.unreadableFolders"
        public static let fdaWhyUnreadable = "app.access.fda.why.unreadable"
        public static let fdaWhyProtected = "app.access.fda.why.protected"
        public static let fdaWhyUnknown = "app.access.fda.why.unknown"
        public static let fdaActionOpenSettings = "app.access.fda.action.openSettings"
        public static let fdaActionRecheck = "app.access.fda.action.recheck"
        public static let fdaHintInList = "app.access.fda.hint.inList"
        public static let helperWhyEnabled = "app.access.helper.why.enabled"
        /// Takes `blocksBytes`.
        public static let helperWhyRootOnlyBytes = "app.access.helper.why.rootOnlyBytes"
        public static let helperWhyRootActions = "app.access.helper.why.rootActions"
        public static let helperActionInstall = "app.access.helper.action.install"
        public static let helperActionApprove = "app.access.helper.action.approve"
        /// What to do instead in a build without the helper. A condition, not an instruction: the helper needs a signed build
        /// that includes it, and none is released yet (#30); where there is a manual route, `doctor` or `vault init` prints it.
        public static let helperActionSignedReleaseOrCLI = "app.access.helper.action.signedReleaseOrCLI"
        /// The guidance's manual route, in its tooltip (`Row.helpKey`).
        public static let helperManualRoute = "app.access.helper.action.manualRoute"
        /// **Relaunch XCodeVault** and what it is for (`offersRelaunch`).
        public static let fdaActionRelaunch = "app.access.fda.action.relaunch"
        public static let fdaHintRelaunch = "app.access.fda.hint.relaunch"
    }

    /// Every key a row can return.
    public static let allKeys: [String] = [
        Key.fdaWhyGranted, Key.fdaWhyUnreadableFolders, Key.fdaWhyUnreadable, Key.fdaWhyProtected, Key.fdaWhyUnknown,
        Key.fdaActionOpenSettings, Key.fdaActionRecheck, Key.helperWhyEnabled, Key.helperWhyRootOnlyBytes, Key.helperWhyRootActions,
        Key.helperActionInstall, Key.helperActionApprove, Key.helperActionSignedReleaseOrCLI, Key.fdaTitle, Key.helperTitle, Key.fdaStatusGranted,
        Key.fdaStatusMissing, Key.fdaStatusUnknown, Key.helperStatusEnabled, Key.helperStatusMissing, Key.helperStatusAwaitingApproval,
        Key.helperStatusUnavailable, Key.fdaHintInList, Key.fdaStatusOff, Key.helperManualRoute, Key.fdaActionRelaunch, Key.fdaHintRelaunch,
    ]

    /// Whether the hint next to the Full Disk Access button shows (R5, HIG review A2): only once the user has opened the
    /// pane from the app, when the next step is theirs. Before that the button says enough.
    public static func showsHint(_ row: Row, openedSettings: Bool) -> Bool { row.hintKey != nil && openedSettings }

    /// Whether the Full Disk Access row offers **Relaunch XCodeVault** (R5, the user's check of H16 on 2026-10-04: after
    /// the switch was turned on, macOS recommended relaunching). Once the user has opened the pane from the app and this
    /// process still cannot open the indicator: a grant the running process does not see yet looks exactly like no
    /// grant, so the button comes with "if you turned it on". Never for a granted or undetermined state.
    public static func offersRelaunch(_ row: Row, openedSettings: Bool) -> Bool {
        row.need == .fullDiskAccess && row.state == .missing && openedSettings
    }

    /// - Parameters:
    ///   - savings: `ScanReport.savings`; its `isLowerBound` says some counted item could not be fully read.
    ///   - plan: the plan rows; only delete rows noted `rootOnly` count towards the helper (`clean` never deletes them
    ///     without root).
    ///   - privacyRefusalCount: `ScanSummary.privacyRefusalCount`, the folders privacy protection refused.
    ///   - deleteList: the Delete view's list, when there is one. Its root actions are then the helper row's bytes, so the
    ///     Access screen, the Overview banner and the Delete view's row say the same number (`rootOnlyBytes`).
    public static func rows(
        fullDiskAccess: FullDiskAccessState, helper: HelperState, savings: SavingsSummary, plan: [SavingsPlanRow], privacyRefusalCount: Int = 0,
        deleteList: DeleteList? = nil
    ) -> [Row] {
        [
            fullDiskAccessRow(fullDiskAccess, savings: savings, refusals: privacyRefusalCount),
            helperRow(helper, rootOnlyBytes: rootOnlyBytes(plan: plan, list: deleteList)),
        ]
    }

    /// The bytes only root can delete: the Delete list's root actions when there is a list — what the Delete view shows —
    /// otherwise the plan's delete rows noted `rootOnly`. One source per call, so two screens never show two numbers.
    public static func rootOnlyBytes(plan: [SavingsPlanRow], list: DeleteList?) -> UInt64 {
        if let list { return list.groups.flatMap(\.actions).filter(\.requiresRoot).reduce(UInt64(0)) { $0 + $1.bytes } }
        return plan.filter { $0.option.bucket == .deleteAndRegenerate && $0.noteIDs.contains("rootOnly") }.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    /// The Overview's one access banner (spec §6.2: "at most one"): the first row that holds back something the scan
    /// measured, or nil. Full Disk Access holds something back when it is not granted and folders were refused or a size
    /// is a lower bound; the helper, when it is not enabled and root-only delete rows wait on it (`blocksBytes`). A row that
    /// holds nothing back stays in the Access view and never nags from the Overview. Nor does the helper's row in a build
    /// that can never reach it (`unavailableInThisBuild`): the user cannot act on it from there, so it stays on the Access
    /// screen and above the Delete table, where the root rows it holds back are listed.
    public static func banner(
        fullDiskAccess: FullDiskAccessState, helper: HelperState, savings: SavingsSummary, plan: [SavingsPlanRow], privacyRefusalCount: Int = 0,
        deleteList: DeleteList? = nil
    ) -> Row? {
        rows(
            fullDiskAccess: fullDiskAccess, helper: helper, savings: savings, plan: plan, privacyRefusalCount: privacyRefusalCount, deleteList: deleteList
        ).first { row in
            guard row.state != .granted else { return false }
            return switch row.need {
            case .fullDiskAccess: privacyRefusalCount > 0 || savings.isLowerBound
            case .privilegedHelper: row.state != .unavailableInThisBuild && row.blocksBytes != nil
            }
        }
    }

    /// The helper row the Delete view shows above its table (spec §6.3, "contextual"): when the list it shows has a
    /// root-only row and the helper is not enabled. Its bytes are those root rows', so the sentence matches the table.
    /// Nil when the helper is enabled or nothing listed needs root: the Access view still has the row.
    public static func deleteRow(helper: HelperState, list: DeleteList) -> Row? {
        guard helper != .enabled, list.groups.contains(where: { $0.actions.contains(where: \.requiresRoot) }) else { return nil }
        return helperRow(helper, rootOnlyBytes: rootOnlyBytes(plan: [], list: list))
    }

    /// Whether a root action's own control (`PrivilegedActionControlView`) shows its "what to do instead" text. Only in a
    /// build that cannot reach the helper is there such text; it is left out when `shownRow` — the access row already on
    /// screen above the control — gives the same guidance, so it is never said twice. The action and its confirmation are
    /// not affected: in that build the control has no button either way.
    public static func controlShowsGuidance(helper: HelperState, besides shownRow: Row?) -> Bool {
        guard helper.actionControl == .notAvailableInThisBuild else { return true }
        return shownRow?.actionKey != Key.helperActionSignedReleaseOrCLI
    }

    /// Whether the app rescans when it becomes active again (R4). Only when Full Disk Access became granted — a scan with
    /// it measures folders the last one could not — and only once there is a scan to redo or the user is back from the
    /// pane the app opened: the launch's own scan is never doubled, and an activation that changed nothing scans nothing.
    public static func rescansOnActivation(
        before: FullDiskAccessState, after: FullDiskAccessState, hasScanned: Bool, returningFromSettings: Bool
    ) -> Bool {
        before != .granted && after == .granted && (hasScanned || returningFromSettings)
    }

    /// Whether the Access view offers **Uninstall…** under `row`: the helper's row, once it is enabled
    /// (`HelperState.rowButton`). The uninstall still asks for confirmation.
    public static func offersUninstall(_ row: Row, helper: HelperState) -> Bool {
        row.need == .privilegedHelper && helper.rowButton == .uninstall
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

    static func helperRow(_ state: HelperState, rootOnlyBytes rootOnly: UInt64) -> Row {
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
