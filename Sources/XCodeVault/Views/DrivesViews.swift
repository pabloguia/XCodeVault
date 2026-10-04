import SwiftUI
import XCodeVaultCore

/// Drives (R1): one row per drive — the running system's volume group as one "Internal disk (boot)" row — with whether it
/// can be a vault, one verdict line for a registered vault on its own volume's row, and a section only for the vaults that
/// are not connected. The rows and every decision are Core's (`DrivesList`, `DriveRow.vaultVerdict`,
/// `DriveRow.showsQualificationDetail`), through `AppModel.drivesList`.
struct DrivesView: View {
    let list: DrivesList
    /// Each row's usage bar (R2, `AppModel.driveBar`); nil draws none.
    var bar: (DriveRow) -> DiskBar? = { _ in nil }
    /// R6: the external drives, judged (`AppModel.driveAssessments`), and what their buttons do. Nil hides the section.
    var external: [DriveAssessment]? = nil
    var actions = ExternalDriveActions()
    var body: some View {
        List {
            if let external {
                Section(L10n.tr("app.drives.external")) {
                    if external.isEmpty {
                        Text.l10n(L10n.tr("app.drives.none")).foregroundStyle(.secondary)
                    }
                    ForEach(external) { ExternalDriveRowView(assessment: $0, actions: actions) }
                }
            }
            Section(L10n.tr("app.volumes.mounted")) {
                ForEach(list.rows) { DriveRowView(row: $0, bar: bar($0)) }
            }
            if list.hasNoVaults {
                Section(L10n.tr("app.volumes.vaults")) {
                    InlineCodeText(L10n.tr("app.volumes.vaults.none")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if !list.offlineVaults.isEmpty {
                Section(L10n.tr("app.volumes.vaults.offline")) {
                    // By position: a damaged registry can hold one UUID twice, and both entries are shown.
                    ForEach(Array(list.offlineVaults.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                // The state's words with its symbol (`DrivesList.offlineSymbol`); only the symbol is tinted
                                // (HIG review DR5), the words stay primary.
                                Label {
                                    Text(verbatim: AppText.vaultState(c.state))
                                } icon: {
                                    StatusIcon(.offlineVault(c), symbol: DrivesList.offlineSymbol(for: c))
                                }
                                Text(verbatim: c.volume.volumeName).font(.headline)
                            }
                            Text(verbatim: c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// One Drives row (R5, HIG review DR1–DR4): the name in `.headline` with its facts in one secondary line and the free
/// space trailing; one verdict line — the vault's, or whether the drive can be a vault, or "Boot volume"; the bar; then
/// the blockers and the vault's problem as symbol-tinted labels with primary text, and the warnings folded behind their
/// count. Never color alone: every tinted symbol stands beside its words.
struct DriveRowView: View {
    let row: DriveRow
    /// The drive's usage (R2): other data, developer data by bucket, free, with a legend; nil when its size is unknown.
    var bar: DiskBar?
    @State private var showsWarnings: Bool?

    private var name: String { row.isBootGroup ? L10n.tr("app.volumes.bootGroup") : row.volume.volumeName }

    var body: some View {
        let v = row.volume
        let q = row.qualification
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: name).font(.headline)
                Text(verbatim: facts).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(facts)
                Spacer()
                Text.l10n(L10n.tr("app.volumes.free", ByteCount.format(v.freeBytes))).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            verdictLine
            if let bar {
                // On a vault: what the scan found there, against other data; the registry keeps no sizes (R2 follow-up).
                DiskBarView(
                    bar: bar, caption: row.vault == nil ? nil : L10n.tr("app.volumes.bar.vault"),
                    accessibilityTitle: L10n.tr("app.volumes.bar.a11y", name), barHeight: 12
                )
                .padding(.vertical, 4)
            }
            if row.showsQualificationDetail {
                ForEach(q.blockers, id: \.self) { blocker in
                    Label {
                        InlineCodeText(blocker).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    } icon: {
                        StatusIcon(.blocker)
                    }
                }
            }
            // A mounted vault that cannot be used says why in visible text, not only in a tooltip (`DriveRow.showsVaultDetail`).
            if let vault = row.vault, row.showsVaultDetail {
                StatusLabel(.warning, vault.detail).font(.callout)
            }
            // Further registry entries for this volume (`DriveRow.duplicateVaults`): shown, never dropped.
            ForEach(Array(row.duplicateVaults.enumerated()), id: \.offset) { _, extra in
                StatusLabel(.warning, L10n.tr("app.volumes.vaultBadge", AppText.vaultState(extra.state)) + " — " + extra.detail).font(.callout)
            }
            if row.showsQualificationDetail, !q.warnings.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { showsWarnings ?? !row.warningsStartCollapsed }, set: { showsWarnings = $0 })) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(q.warnings, id: \.self) { warning in
                            StatusLabel(.warning, warning).font(.caption)
                        }
                    }
                } label: {
                    Text.l10n(L10n.plural("app.volumes.warnings.count", count: q.warnings.count)).font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// File system, bus and internal or external, in one line (HIG review DR4).
    private var facts: String {
        let v = row.volume
        return [v.filesystemPersonality, v.busProtocol, v.isInternal ? L10n.tr("app.volumes.internal") : L10n.tr("app.volumes.external")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One verdict (HIG review DR1, DR3): the vault's when the drive holds one; else whether it can be a vault; else, for
    /// the boot volume, only that it is the boot volume — expected, not an error.
    @ViewBuilder
    private var verdictLine: some View {
        if let verdict = row.vaultVerdict {
            StatusLabel(.vaultVerdict(verdict), AppText.vaultVerdict(verdict)).font(.callout)
                .help(row.vault?.detail ?? "")
        } else if row.showsQualificationDetail {
            StatusLabel(.neutral, AppText.verdict(row.qualification.verdict), symbol: Self.symbol(row.qualification.verdict)).font(.callout)
        } else {
            Text.l10n(L10n.tr("app.volumes.bootVolume")).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Whether a drive that holds no vault can be one: a neutral symbol, since not qualifying is not an error.
    static func symbol(_ verdict: VolumeQualification.Verdict) -> String {
        switch verdict {
        case .suitable: "checkmark.circle"
        case .suitableWithWarnings: "exclamationmark.circle"
        case .unsuitable: "minus.circle"
        }
    }
}

/// What an external drive's buttons do (R6), supplied by `AppModel`; empty closures by default, for renders.
struct ExternalDriveActions {
    var prepare: @MainActor (DriveAssessment, PreparationOption) -> Void = { _, _ in }
    var useDrive: @MainActor (DriveAssessment) -> Void = { _ in }
    var showInFinder: @MainActor (String) -> Void = { _ in }
    var copyOwnershipCommand: @MainActor (String) -> Void = { _ in }
}

/// One external drive (R6): its verdict in words with a symbol, its facts, why nothing can change it when that is so,
/// **Use This Drive** when one of its volumes qualifies, and each preparation option as a button, least destructive first,
/// every one marked experimental (rule 10). Decides nothing: `DriveEvaluation` did.
struct ExternalDriveRowView: View {
    let assessment: DriveAssessment
    let actions: ExternalDriveActions

    var body: some View {
        let a = assessment
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: a.displayName).font(.headline)
                Text(verbatim: DriveText.facts(a)).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(DriveText.facts(a))
                Spacer()
            }
            StatusLabel(.driveVerdict(a.verdict), DriveText.verdict(a.verdict), symbol: DriveText.symbol(a.verdict)).font(.callout)
            // `DriveAssessment.shownRefusals` and `.volumeReasons`: Core chose what to say.
            ForEach(a.shownRefusals, id: \.self) { r in
                Text(verbatim: DriveText.refusal(r)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(a.volumeReasons, id: \.volumeName) { reason in
                Label {
                    InlineCodeText(reason.volumeName + ": " + reason.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            // Least destructive first (minor 1): ownership runs nothing, so it comes before every button that does.
            ForEach(a.ownershipMountPoints, id: \.self) { mp in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: L10n.tr("app.drives.ownership.detail", (mp as NSString).lastPathComponent)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.tr("app.drives.ownership.show")) { actions.showInFinder(mp) }.actionButton().controlSize(.small)
                        CopyCommandButton { actions.copyOwnershipCommand(mp) }
                    }
                }
            }
            // The user ("destacar como botão", R7-A/R7-B): each action is a bordered button with a verb title, at most one
            // prominent per drive row (ruling B-1); the Experimental tag is on its own line above the options, never in the
            // buttons' row, and what each option costs is a footnote under them.
            if a.verdict == .canBeUsed {
                Button(L10n.tr("app.drives.useDrive")) { actions.useDrive(a) }.actionButton(prominent: a.useDriveIsPrimary)
            }
            if !a.commandOptions.isEmpty {
                Tag.marker(.experimental)
                HStack(spacing: Spacing.s) {
                    ForEach(a.commandOptions, id: \.self) { o in
                        Button(DriveText.optionButton(o)) { actions.prepare(a, o) }.actionButton(prominent: a.isRecommended(o))
                    }
                }
                if let note = DriveText.optionsFootnote(a) {
                    Text(verbatim: note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
