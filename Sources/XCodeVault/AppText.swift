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

    /// "Experimental": the one badge every experimental row, option and action carries (CLAUDE.md rule 10), in title case
    /// app-wide (R5, HIG review P3).
    static var experimental: String { L10n.tr("app.label.experimental") }

    /// A marker badge's word (R5, HIG review P3, X2): the app's "Experimental"; the others are the `plan` command's
    /// words, which the app starts with a capital as a label does.
    static func marker(_ marker: SavingsMarker) -> String {
        if case .experimental = marker { return experimental }
        // The CLI's label says its Full Disk Access is unmeasured (R5 review m2); the badge is short.
        if case .needsRoot(.helperWithFullDiskAccess) = marker { return L10n.tr("app.marker.needsRootWithFullDiskAccess") }
        let text = marker.localizedText
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A strategy's name in words (R5, HIG review ST4, X1): never its identifier. Core's, so the Storage column sorts by
    /// what it shows (`StorageRow.strategySortKey`).
    static func strategy(_ strategy: Strategy) -> String { strategy.localizedName }

    /// Why a root action needs the helper, in the helper sheet: the app's words for the requirement whose shared text
    /// keeps the CLI's evidence references (R5 review m2).
    static func requirementWhy(_ requirement: PrivilegeRequirement) -> String {
        switch requirement {
        case .helperWithFullDiskAccess: L10n.tr("app.requirement.helperWithFullDiskAccess.why")
        default: requirement.why(in: L10n.locale)
        }
    }

    /// A bucket's short name, where its full title does not fit (the Storage chart, chips and column; R5): the name of
    /// its sidebar view.
    static func bucketShortName(_ bucket: SavingsBucket) -> String {
        switch bucket {
        case .deleteAndRegenerate: L10n.tr("app.section.delete")
        case .parkExternally: L10n.tr("app.section.park")
        case .runFromExternal: L10n.tr("app.section.runExternally")
        case .keepLocal: L10n.tr("app.bucket.keepLocal.short")
        }
    }

    /// The Storage filter's summary (R5, the user's feedback): "Filtering: Delete, Park", with the search in quotes.
    static func storageFilterSummary(_ buckets: [SavingsBucket], query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = buckets.map(bucketShortName) + (text.isEmpty ? [] : [L10n.tr("app.storage.filter.query", text)])
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: L10n.locale)
        return L10n.tr("app.storage.filter.summary", formatter.string(from: parts) ?? parts.joined(separator: ", "))
    }

    /// A Simulators row's state: simctl's word, "—" when it gave none, and "Mounted" for a runtime whose image is.
    static func simulatorState(_ row: SimulatorListRow) -> String {
        [row.state ?? "—", row.isMounted == true ? L10n.tr("app.simulators.mounted") : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Overview card's eyebrow (R5, HIG review O1): what happens to the space, not to the deletion.
    static func cardEyebrow(permanent: Bool) -> String {
        permanent ? L10n.tr("app.overview.card.eyebrow.permanent") : L10n.tr("app.overview.card.eyebrow.temporary")
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

    /// The error alert's title when a root action did not run or failed (R5, HIG review N10).
    static func privilegedFailed(_ action: PrivilegedAction) -> String {
        switch action {
        case .createVaultDirectory: L10n.tr("app.error.createVaultDirectory.title")
        case .emptyCoreSimulatorDyldCache: L10n.tr("app.error.emptyDyldCache.title")
        }
    }

    /// The inline result's line when a root action succeeded (R5, HIG review N11).
    static func privilegedDone(_ action: PrivilegedAction) -> String {
        switch action {
        case .createVaultDirectory: L10n.tr("app.feedback.createVaultDirectory")
        case .emptyCoreSimulatorDyldCache: L10n.tr("app.feedback.emptyDyldCache")
        }
    }

    /// A root action's button, title case (HIG review X5). The cache's keeps "Experimental" (rule 10).
    static func privilegedButton(_ action: PrivilegedAction) -> String {
        switch action {
        case .createVaultDirectory: L10n.tr("app.privileged.button.createVaultDirectory")
        case .emptyCoreSimulatorDyldCache: L10n.tr("app.privileged.button.emptyDyldCache")
        }
    }

    /// The root action's confirmation, as a question (R5, HIG review D4). The cache's keeps "experimental" (rule 10).
    static func privilegedConfirmTitle(_ action: PrivilegedAction) -> String {
        switch action {
        case .createVaultDirectory: L10n.tr("app.privileged.confirm.createVaultDirectory")
        case .emptyCoreSimulatorDyldCache: L10n.tr("app.privileged.confirm.emptyDyldCache")
        }
    }

    /// What a clean did, inline: how many items, how much, and where the space went.
    static func cleanFeedback(_ result: CleanResult, useTrash: Bool) -> AppFeedback? {
        guard !result.deleted.isEmpty else { return nil }
        let size = ByteCount.format(result.bytesFreed)
        if useTrash {
            return AppFeedback(
                kind: .success, title: L10n.plural("app.feedback.clean.trash", count: result.deleted.count, size), detail: [L10n.tr("app.clean.trashNote")])
        }
        return AppFeedback(kind: .success, title: L10n.plural("app.feedback.clean.deleted", count: result.deleted.count, size))
    }

    /// The items a clean could not delete, as an alert: the count as the title, each path and why as the message.
    static func cleanFailures(_ result: CleanResult) -> AppError? {
        guard !result.failedPairs.isEmpty else { return nil }
        return AppError(
            title: L10n.plural("app.error.clean.partial", count: result.failedPairs.count),
            message: result.failedPairs.map { $0.path + "\n" + $0.error }.joined(separator: "\n\n"))
    }

    /// The Delete confirmation's message for the rows it acts on (R5, HIG review D2, D3): each undo cost present, where
    /// the deletion is recorded, and where the space goes with the Trash.
    static func deleteConfirmation(costs: Set<Regenerability>, useTrash: Bool) -> String {
        var lines: [String] = []
        if costs.contains(.regenerable) { lines.append(L10n.tr("app.clean.confirm.regenerable")) }
        if costs.contains(.redownloadable) { lines.append(L10n.tr("app.clean.confirm.redownloadable")) }
        if costs.contains(.userRecreatable) { lines.append(L10n.tr("app.clean.confirm.userRecreatable")) }
        // Never listed by `DeleteList` today; said plainly if it ever is (R5 safety LOW-1).
        if costs.contains(.nonRegenerable) { lines.append(L10n.tr("app.clean.confirm.nonRegenerable")) }
        lines.append(L10n.tr("app.clean.confirm.history"))
        if useTrash { lines.append(L10n.tr("app.clean.trashNote")) }
        return lines.joined(separator: " ")
    }

    /// A drive's vault verdict, one line (R5, HIG review DR3).
    static func vaultVerdict(_ verdict: DriveRow.VaultVerdict) -> String {
        switch verdict {
        case .ready: L10n.tr("app.volumes.vault.ready")
        case .readyWithWarnings: L10n.tr("app.volumes.vault.readyWithWarnings")
        case .needsAttention: L10n.tr("app.volumes.vault.needsAttention")
        case .notUsable: L10n.tr("app.volumes.vault.notUsable")
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
        case .diskPreparation: L10n.tr("app.history.kind.diskPreparation")
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
        case .planned: L10n.tr("app.history.outcome.planned")
        }
    }

    /// A History section's header: Today, Yesterday, then the date, in the app's language and in `calendar`'s time zone —
    /// the calendar that grouped the rows (`AppModel.historySections`), so the header names the day that was grouped.
    static func historyDay(_ day: JournalTimeline.Day, calendar: Calendar = .current) -> String {
        switch day {
        case .today: L10n.tr("app.history.day.today")
        case .yesterday: L10n.tr("app.history.day.yesterday")
        case .date(let date):
            date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone).locale(Locale(identifier: L10n.locale)))
        }
    }

    /// A History row's time, in `calendar`'s time zone; the section header gives the day.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone).locale(Locale(identifier: L10n.locale)))
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
        case K.fdaStatusOff: return L10n.tr("app.access.status.fda.off")
        case K.helperStatusEnabled: return L10n.tr("app.access.status.helper.enabled")
        case K.helperStatusMissing: return L10n.tr("app.access.status.helper.missing")
        case K.helperStatusAwaitingApproval: return L10n.tr("app.access.status.helper.awaitingApproval")
        case K.helperStatusUnavailable: return L10n.tr("app.access.status.helper.unavailable")
        case K.fdaHintInList: return L10n.tr("app.access.fda.hint.inList")
        case K.helperManualRoute: return L10n.tr("app.access.helper.action.manualRoute")
        case K.fdaActionRelaunch: return L10n.tr("app.access.fda.action.relaunch")
        case K.fdaHintRelaunch: return L10n.tr("app.access.fda.hint.relaunch")
        default: return key
        }
    }
}
