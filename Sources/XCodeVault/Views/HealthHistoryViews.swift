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
            ContentUnavailableView(L10n.tr("app.doctor.empty"), systemImage: "checkmark.seal")
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
                InlineCodeText("→ " + fix).font(.callout).fixedSize(horizontal: false, vertical: true)
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

/// History: one row per operation, grouped by the day it started (Today, Yesterday, then the date), newest first. Each
/// row has the time, the kind's badge, the state as a symbol and a word, the summary (whole in its tooltip) and the size
/// when one was recorded. The kinds menu hides kinds.
struct HistoryView: View {
    @Bindable var model: AppModel

    /// The columns' widths, shared by the header and the rows so they line up.
    enum Width {
        static let time: CGFloat = 72
        static let kind: CGFloat = 176
        static let state: CGFloat = 128
        static let size: CGFloat = 80
    }

    var body: some View {
        if model.historyRows.isEmpty {
            ContentUnavailableView(
                L10n.tr("app.journal.empty.title"), systemImage: "list.bullet.rectangle", description: Text.l10n(L10n.tr("app.journal.empty.detail")))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                InterruptedMigrationsBanner(items: model.interruptedMigrations) { model.environment.copy($0) }.padding(.horizontal)
                filterBar
                header
                let sections = model.historySections()
                if sections.isEmpty {
                    Text.l10n(L10n.tr("app.history.filter.none")).foregroundStyle(.secondary).padding(.horizontal)
                    Spacer(minLength: 0)
                } else {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { HistoryRowView(row: $0) }
                            } header: {
                                Text(verbatim: AppText.historyDay(section.day))
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .padding(.top, 8)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Menu(L10n.tr("app.history.filter.menu")) {
                ForEach(model.historyKinds, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { model.historyShows(kind) }, set: { _ in model.toggleHistoryKind(kind) })) {
                        Label(AppText.historyKind(kind), systemImage: kind.symbolName)
                    }
                }
            }
            .fixedSize()
            Button(L10n.tr("app.history.filter.all")) { model.showAllHistoryKinds() }
                .disabled(model.historyHiddenKinds.isEmpty)
        }
        .padding(.horizontal)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text.l10n(L10n.tr("app.column.when")).frame(width: Width.time, alignment: .leading)
            Text.l10n(L10n.tr("app.column.kind")).frame(width: Width.kind, alignment: .leading)
            Text.l10n(L10n.tr("app.column.state")).frame(width: Width.state, alignment: .leading)
            Text.l10n(L10n.tr("app.column.summary")).frame(maxWidth: .infinity, alignment: .leading)
            Text.l10n(L10n.tr("app.column.size")).frame(width: Width.size, alignment: .trailing)
        }
        .font(.caption).bold().foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 26)
        .accessibilityHidden(true)
    }
}

/// One operation. The summary is the journal's English; the tooltip gives it whole, with how it ended.
struct HistoryRowView: View {
    let row: JournalTimeline.Row

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: AppText.time(row.started)).monospacedDigit().lineLimit(1).frame(width: HistoryView.Width.time, alignment: .leading)
            HistoryKindBadge(kind: row.kind).frame(width: HistoryView.Width.kind, alignment: .leading)
            Label {
                Text(verbatim: AppText.historyOutcome(row.outcome)).lineLimit(1)
            } icon: {
                Image(systemName: row.outcome.symbolName).accessibilityHidden(true)
            }
            .frame(width: HistoryView.Width.state, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.summary).lineLimit(1).truncationMode(.middle)
                // How it ended, under it, when it did not end well (R4 review M5); every step is in `xcodevaultctl journal`.
                if row.showsEndSummary, let end = row.endSummary {
                    Text(verbatim: end).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(fullSummary)
            Text(verbatim: row.bytes.map { ByteCount.format($0) } ?? "").monospacedDigit().lineLimit(1)
                .frame(width: HistoryView.Width.size, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var fullSummary: String { [row.summary, row.endSummary].compactMap { $0 }.joined(separator: "\n") }
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
