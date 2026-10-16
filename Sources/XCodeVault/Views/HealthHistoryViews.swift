import SwiftUI
import XCodeVaultCore

// Health and History (R4). Neither decides anything: the cards, their order and what they fold are `HealthCard`'s; the
// rows, their kinds, their states, the days and the filter are `JournalTimeline`'s, through the model. The doctor's and the
// journal's prose stays English (S2); the labels around it are translated.

/// Health: a summary line of counts by severity, then one card per finding, most severe first, then largest. Each card has
/// the severity (symbol and word), the title, one short sentence, the size when there is one and the finding's control;
/// the long text is folded under "Details".
struct HealthView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.findings.isEmpty {
            // An empty state that explains and offers the next step (HIG review H3).
            ContentUnavailableView {
                Label(L10n.tr("app.doctor.empty"), systemImage: "checkmark.seal")
            } description: {
                Text.l10n(L10n.tr("app.doctor.empty.detail"))
            } actions: {
                Button(L10n.tr("app.action.rescan")) { Task { await model.refresh() } }.disabled(model.isScanning || model.isOperationRunning)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HealthSummaryLine(counts: model.healthCounts)
                    ForEach(model.healthCards) { card in
                        HealthCardView(card: card, helperState: model.helperState) { model.request($0) }
                    }
                }
                .padding()
            }
        }
    }
}

/// "1 warning · 3 info": each count with its severity's symbol and word, never its color alone.
struct HealthSummaryLine: View {
    let counts: [(severity: Finding.Severity, count: Int)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, item in
                if index > 0 { Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true) }
                Label {
                    Text(verbatim: AppText.healthCount(item.severity, item.count))
                } icon: {
                    // The word is next to it: the symbol is not said twice.
                    Image(systemName: item.severity.symbolName).foregroundStyle(HealthCardView.tint(item.severity)).accessibilityHidden(true)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// One finding as a card. The severity's symbol takes its color; the word, the title and every sentence are `.primary`
/// or `.secondary` text.
struct HealthCardView: View {
    let card: HealthCard
    let helperState: HelperState
    let perform: @MainActor (PrivilegedAction) -> Void
    @State private var showsDetails = false

    /// The severity symbol's tint. It repeats the word next to it, never replaces it.
    static func tint(_ severity: Finding.Severity) -> Color {
        switch severity {
        case .critical, .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(verbatim: AppText.severity(card.severity)).font(.caption).bold()
                } icon: {
                    Image(systemName: card.severity.symbolName).foregroundStyle(Self.tint(card.severity)).accessibilityHidden(true)
                }
                Text(verbatim: card.title).bold().fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let bytes = card.bytes {
                    Text(verbatim: ByteCount.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(verbatim: card.sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            // The finding carries the action; the button never re-derives it (carried note 2).
            if let action = card.finding.action {
                PrivilegedActionControlView(action: action, state: helperState) { perform(action) }
            } else if let fix = card.fixSentence {
                // The fix with a symbol, not an ASCII arrow (HIG review H2, X3).
                Label {
                    InlineCodeText(fix).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary).accessibilityLabel(Text(verbatim: L10n.tr("app.health.fix")))
                }
            }
            if let details = card.details {
                DisclosureGroup(isExpanded: $showsDetails) {
                    HealthDetailsView(details: details).padding(.top, 4)
                } label: {
                    Text.l10n(L10n.tr("app.health.details")).font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// What a card folds: the whole explanation, the per-device sizes as an aligned list, why `clean` does not offer it, the
/// whole fix, the path and the evidence.
struct HealthDetailsView: View {
    let details: HealthCard.Details

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let explanation = details.explanation {
                InlineCodeText(explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !details.lines.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    ForEach(details.lines, id: \.label) { line in
                        GridRow {
                            Text(verbatim: line.label).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(verbatim: ByteCount.format(line.bytes)).font(.caption).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if let note = details.notOfferedByClean {
                VStack(alignment: .leading, spacing: 2) {
                    InlineCodeText(L10n.tr("app.health.notOffered")).font(.caption).bold()
                    InlineCodeText(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let fix = details.fix {
                VStack(alignment: .leading, spacing: 2) {
                    Text.l10n(L10n.tr("app.health.fix")).font(.caption).bold()
                    InlineCodeText(fix).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let path = details.path {
                Text(verbatim: path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let evidence = details.evidence {
                Text.l10n(L10n.tr("app.doctor.evidence", evidence)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// History (R5, HIG review HI1–HI3): one table, one row per operation, in sections by the day it started (Today,
/// Yesterday, then the date), newest first. Real columns — the time, the kind's badge, the state as a symbol and a word,
/// the summary (whole in its tooltip, how it ended under it when it did not end well) and the size when one was recorded —
/// with headers VoiceOver reads, keyboard selection and Copy Summary. The kinds menu says the filter's state and hides
/// kinds; **Show All** is inside it.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<String>()

    var body: some View {
        if model.historyRows.isEmpty {
            ContentUnavailableView(
                L10n.tr("app.journal.empty.title"), systemImage: "list.bullet.rectangle", description: Text.l10n(L10n.tr("app.journal.empty.detail")))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                InterruptedMigrationsBanner(items: model.interruptedMigrations) { model.environment.copy($0) }.padding(.horizontal)
                HStack {
                    Spacer(minLength: 0)
                    filterMenu
                }
                .padding(.horizontal)
                let sections = model.historySections()
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.tr("app.history.filter.none"), systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button(L10n.tr("app.history.filter.all")) { model.showAllHistoryKinds() }
                    }
                } else {
                    table(sections)
                }
            }
            .padding(.top, 8)
        }
    }

    private var filterMenu: some View {
        Menu(model.historyFilterTitle) {
            ForEach(model.historyKinds, id: \.self) { kind in
                Toggle(isOn: Binding(get: { model.historyShows(kind) }, set: { _ in model.toggleHistoryKind(kind) })) {
                    Label(AppText.historyKind(kind), systemImage: kind.symbolName)
                }
            }
            Divider()
            Button(L10n.tr("app.history.filter.all")) { model.showAllHistoryKinds() }.disabled(model.historyHiddenKinds.isEmpty)
        }
        .fixedSize()
    }

    private func table(_ sections: [JournalTimeline.DaySection]) -> some View {
        Table(of: JournalTimeline.Row.self, selection: $selection) {
            TableColumn(L10n.tr("app.column.when")) { Text(verbatim: AppText.time($0.started)).monospacedDigit() }.width(min: 56, ideal: 72)
            TableColumn(L10n.tr("app.column.kind")) { HistoryKindBadge(kind: $0.kind) }.width(min: 100, ideal: 140)
            TableColumn(L10n.tr("app.column.state")) { HistoryOutcomeLabel(outcome: $0.outcome) }.width(min: 90, ideal: 120)
            TableColumn(L10n.tr("app.column.summary")) { HistorySummaryCell(row: $0) }
            TableColumn(L10n.tr("app.column.size")) { row in
                Text(verbatim: row.bytes.map { ByteCount.format($0) } ?? "").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        } rows: {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { TableRow($0) }
                } header: {
                    Text(verbatim: AppText.historyDay(section.day))
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(L10n.tr("app.history.copySummary")) { model.copyHistorySummaries(ids) }.disabled(ids.isEmpty)
        }
    }
}

/// A History row's state: its symbol, tinted for a failed (red) or interrupted (orange) operation (HIG review HI2), and its
/// word, which always says it.
struct HistoryOutcomeLabel: View {
    let outcome: JournalTimeline.Outcome

    var body: some View {
        Label {
            Text(verbatim: AppText.historyOutcome(outcome)).lineLimit(1)
        } icon: {
            Image(systemName: outcome.symbolName).foregroundStyle(Self.tint(outcome)).accessibilityHidden(true)
        }
    }

    static func tint(_ outcome: JournalTimeline.Outcome) -> Color {
        switch outcome {
        case .failed: .red
        case .interrupted: .orange
        default: .secondary
        }
    }
}

/// One operation's summary: the journal's English, whole in its tooltip with how it ended; how it ended under it when it
/// did not end well (R4 review M5); every step is in `xcodevaultctl journal`.
struct HistorySummaryCell: View {
    let row: JournalTimeline.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: row.summary).lineLimit(1).truncationMode(.middle)
            if row.showsEndSummary, let end = row.endSummary {
                Text(verbatim: end).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .help([row.summary, row.endSummary].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// A kind at a glance: its symbol in its color and its short name, on a tinted capsule. The name is `.primary` text.
struct HistoryKindBadge: View {
    let kind: JournalTimeline.Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName).foregroundStyle(kind.color).accessibilityHidden(true)
            Text(verbatim: AppText.historyKind(kind)).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(kind.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.7)))
    }
}
