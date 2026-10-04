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

    /// The Delete notes panel's label (`DeleteNotes.title`).
    static func deleteNotesTitle(_ title: DeleteNotes.Title) -> String {
        switch title {
        case .notes(let n): L10n.plural("app.delete.notes.title", count: n)
        case .warnings(let n): L10n.plural("app.delete.notes.warnings", count: n)
        case .warningsAndMore(let w, let more):
            L10n.tr("app.delete.notes.warningsAndMore", L10n.plural("app.delete.notes.warnings", count: w), L10n.plural("app.delete.notes.more", count: more))
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
        case .needsAttention(let name): L10n.tr("app.plan.vault.attention", name)
        case .ready(let name): L10n.tr("app.plan.vault.ready", name)
        }
    }

    /// A date in the app's language.
    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L10n.locale)))
    }

    /// Health's summary line: "2 warnings", one per severity (R4).
    static func healthCount(_ severity: Finding.Severity, _ count: Int) -> String {
        switch severity {
        case .critical: L10n.plural("app.health.count.critical", count: count)
        case .error: L10n.plural("app.health.count.error", count: count)
        case .warning: L10n.plural("app.health.count.warning", count: count)
        case .info: L10n.plural("app.health.count.info", count: count)
        }
    }

    /// A History badge's short name.
    static func historyKind(_ kind: JournalTimeline.Kind) -> String {
        switch kind {
        case .clean: L10n.tr("app.history.kind.clean")
        case .runtimeDelete: L10n.tr("app.history.kind.runtimeDelete")
        case .runtimeOffload: L10n.tr("app.history.kind.runtimeOffload")
        case .runtimeExport: L10n.tr("app.history.kind.runtimeExport")
        case .runtimeImport: L10n.tr("app.history.kind.runtimeImport")
        case .migration: L10n.tr("app.history.kind.migration")
        case .xcodeLocationChange: L10n.tr("app.history.kind.xcodeLocationChange")
        case .privileged: L10n.tr("app.history.kind.privileged")
        case .other: L10n.tr("app.history.kind.other")
        }
    }

    /// A History row's state word.
    static func historyOutcome(_ outcome: JournalTimeline.Outcome) -> String {
        switch outcome {
        case .completed: L10n.tr("app.history.outcome.completed")
        case .failed: L10n.tr("app.history.outcome.failed")
        case .rolledBack: L10n.tr("app.history.outcome.rolledBack")
        case .skipped: L10n.tr("app.history.outcome.skipped")
        case .interrupted: L10n.tr("app.history.outcome.interrupted")
        case .inProgress: L10n.tr("app.history.outcome.inProgress")
        }
    }

    /// A History section's header: Today, Yesterday, then the date, in the app's language.
    static func historyDay(_ day: JournalTimeline.Day) -> String {
        switch day {
        case .today: L10n.tr("app.history.day.today")
        case .yesterday: L10n.tr("app.history.day.yesterday")
        case .date(let date): date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: L10n.locale)))
        }
    }

    /// A History row's time; the section header gives the day.
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: L10n.locale)))
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
        case K.fdaTitle: return L10n.tr("perm.fda.title")
        case K.helperTitle: return L10n.tr("perm.helper.title")
        case K.fdaStatusGranted: return L10n.tr("app.access.status.fda.granted")
        case K.fdaStatusMissing: return L10n.tr("app.access.status.fda.missing")
        case K.fdaStatusUnknown: return L10n.tr("app.access.status.fda.unknown")
        case K.helperStatusEnabled: return L10n.tr("app.access.status.helper.enabled")
        case K.helperStatusMissing: return L10n.tr("app.access.status.helper.missing")
        case K.helperStatusAwaitingApproval: return L10n.tr("app.access.status.helper.awaitingApproval")
        case K.helperStatusUnavailable: return L10n.tr("app.access.status.helper.unavailable")
        case K.fdaHintInList: return L10n.tr("app.access.fda.hint.inList")
        default: return key
        }
    }
}
