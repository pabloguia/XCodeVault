import SwiftUI
import XCodeVaultCore

/// Text for the app (S4 Task 2). Every user-visible string comes from the catalog through `L10n.tr` with a literal
/// key (`scripts/l10n.sh check` reads the literals), and reaches SwiftUI through `Text(verbatim:)` or a
/// `StringProtocol` initializer: a string literal would be looked up as a `LocalizedStringKey` in a bundle the app
/// does not have, and its `%` re-interpreted. `AppTextCoverageTests` holds the sources to this.
extension Text {
    /// Already-localized text, shown as is.
    static func l10n(_ s: String) -> Text { Text(verbatim: s) }
}

enum AppText {
    /// The product name, never translated (docs/process/LOCALIZATION.md).
    static let productName = "XCodeVault"

    /// "(experimental)": translated, and shown wherever the English shows it (CLAUDE.md rule 10).
    static var experimental: String { L10n.tr("app.label.experimental") }

    /// `name (experimental)` when `isExperimental`.
    static func name(_ name: String, experimental isExperimental: Bool) -> String {
        isExperimental ? name + " " + experimental : name
    }

    static func severity(_ severity: Finding.Severity) -> String {
        switch severity {
        case .info: L10n.tr("app.severity.info")
        case .warning: L10n.tr("app.severity.warning")
        case .error: L10n.tr("app.severity.error")
        case .critical: L10n.tr("app.severity.critical")
        }
    }

    static func verdict(_ verdict: VolumeQualification.Verdict) -> String {
        switch verdict {
        case .suitable: L10n.tr("app.volumes.verdict.suitable")
        case .suitableWithWarnings: L10n.tr("app.volumes.verdict.suitableWithWarnings")
        case .unsuitable: L10n.tr("app.volumes.verdict.unsuitable")
        }
    }

    static func vaultState(_ state: VaultVolumeState) -> String {
        switch state {
        case .verified: L10n.tr("app.vault.state.verified")
        case .absent: L10n.tr("app.vault.state.absent")
        case .movedMountPoint: L10n.tr("app.vault.state.movedMountPoint")
        case .foreign: L10n.tr("app.vault.state.foreign")
        case .ambiguous: L10n.tr("app.vault.state.ambiguous")
        case .sentinelMissing: L10n.tr("app.vault.state.sentinelMissing")
        }
    }

    /// The Delete view's cost-to-undo column, from the category's regenerability (`DeleteList.Group.undo`).
    static func undoCost(_ regenerability: Regenerability) -> String {
        switch regenerability {
        case .regenerable: L10n.tr("app.delete.undo.regenerable")
        case .redownloadable: L10n.tr("app.delete.undo.redownloadable")
        case .userRecreatable: L10n.tr("app.delete.undo.userRecreatable")
        case .nonRegenerable: L10n.tr("app.delete.undo.nonRegenerable")
        }
    }

    /// Park's vault line (`VaultStatus.make`).
    static func vaultStatus(_ status: VaultStatus) -> String {
        switch status {
        case .noVault: L10n.tr("app.plan.vault.none")
        case .offline: L10n.tr("app.plan.vault.offline")
        case .ready(let name): L10n.tr("app.plan.vault.ready", name)
        }
    }

    /// A date in the app's language.
    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L10n.locale)))
    }

    /// An `AccessChecklist` row's text, from its key and the facts the sentence takes (`blocksBytes`,
    /// `blocksFolders`). Each key has its own literal call; an unknown key shows itself, which is a bug report.
    static func access(_ key: String, bytes: UInt64?, folders: Int?) -> String {
        typealias K = AccessChecklist.Key
        switch key {
        case K.fdaWhyGranted: return L10n.tr("app.access.fda.why.granted")
        case K.fdaWhyUnreadableFolders: return L10n.plural("app.access.fda.why.unreadableFolders", count: folders ?? 0)
        case K.fdaWhyUnreadable: return L10n.tr("app.access.fda.why.unreadable")
        case K.fdaWhyProtected: return L10n.tr("app.access.fda.why.protected")
        case K.fdaWhyUnknown: return L10n.tr("app.access.fda.why.unknown")
        case K.fdaActionOpenSettings: return L10n.tr("app.access.fda.action.openSettings")
        case K.fdaActionRecheck: return L10n.tr("app.access.fda.action.recheck")
        case K.helperWhyEnabled: return L10n.tr("app.access.helper.why.enabled")
        case K.helperWhyRootOnlyBytes: return L10n.tr("app.access.helper.why.rootOnlyBytes", ByteCount.format(bytes ?? 0))
        case K.helperWhyRootActions: return L10n.tr("app.access.helper.why.rootActions")
        case K.helperActionInstall: return L10n.tr("app.access.helper.action.install")
        case K.helperActionApprove: return L10n.tr("app.access.helper.action.approve")
        case K.helperActionSignedReleaseOrCLI: return L10n.tr("app.access.helper.action.signedReleaseOrCLI")
        default: return key
        }
    }
}
