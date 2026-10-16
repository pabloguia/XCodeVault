import Accessibility
import AppKit
import SwiftUI
import XCodeVaultCore

/// The top of a bucket view: the bucket's symbol, title and color band, what it promises and what undoing it costs.
/// Never color alone: the symbol and the title say which bucket this is, and the color is a fill.
struct BucketHeaderView: View {
    let bucket: SavingsBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BucketSymbol(bucket: bucket, decorative: true).font(.title2)
                Text(verbatim: bucket.localizedTitle).font(.title3).bold()
            }
            Text(verbatim: bucket.localizedPromise).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: bucket.localizedUndoCost).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            // The bucket color as a fill, never as text.
            RoundedRectangle(cornerRadius: 2).fill(bucket.color).frame(width: 4).accessibilityHidden(true)
        }
    }
}

/// A row's markers as small badges, in Core's order and words (`SavingsMarker`). The experimental badge is how rule 10
/// reaches every experimental row.
struct MarkerBadges: View {
    let markers: [SavingsMarker]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                Label {
                    Text(verbatim: marker.localizedText)
                } icon: {
                    Image(systemName: Self.symbol(marker))
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            }
        }
    }

    static func symbol(_ marker: SavingsMarker) -> String {
        switch marker {
        case .experimental: "flask"
        case .losesUserData: "exclamationmark.triangle"
        case .actsImmediately: "bolt"
        case .newDataOnly: "arrow.forward.circle"
        case .perItem: "number"
        case .needsRoot: "lock"
        }
    }
}

/// A localized sentence with its backticked commands in monospace (`InlineCode.runs`), instead of literal backticks.
struct InlineCodeText: View {
    let runs: [InlineCode.Run]
    init(_ text: String) { runs = InlineCode.runs(text) }
    var body: some View {
        // Concatenated `Text`s wrap as one paragraph; the deployment target (macOS 14) predates `+`'s deprecation.
        runs.reduce(Text(verbatim: "")) { text, run in
            text + (run.isCode ? Text(verbatim: run.text).font(.system(.callout, design: .monospaced)) : Text(verbatim: run.text))
        }
    }
}

/// One plan row (Park, Run externally, and the Delete view's other-tool rows): name, size, markers, the command in
/// monospace with **Copy command**, and the notes. Every fact is the row's own (`SavingsPlanner.rows`).
struct PlanRowView: View {
    let row: SavingsPlanRow
    let copy: @MainActor () -> Void
    /// **Run…** (R3): set only for a row the app can run (`AppModel.canRun`); nil keeps the row copy-only.
    let run: (@MainActor () -> Void)?

    init(row: SavingsPlanRow, copy: @escaping @MainActor () -> Void, run: (@MainActor () -> Void)? = nil) {
        self.row = row
        self.copy = copy
        self.run = run
    }
    /// A moment of "Copied" after the button, said to VoiceOver too: feedback only, it decides nothing.
    @State private var copied = false
    /// Counts the clicks: each one restarts the moment (`.task(id:)` cancels the previous wait), and nothing outlives the view.
    @State private var copies = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: row.categoryName).bold()
                if row.option.appliesToExistingData {
                    Text(verbatim: ByteCount.format(row.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                MarkerBadges(markers: SavingsMarker.markers(for: row))
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline) {
                // A command is never translated (docs/process/LOCALIZATION.md).
                Text(verbatim: row.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    copy()
                    copied = true
                    copies += 1
                    AccessibilityNotification.Announcement(L10n.tr("app.plan.copied")).post()
                } label: {
                    Label(
                        copied ? L10n.tr("app.plan.copied") : L10n.tr("app.plan.copyCommand"),
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                // Several rows, several buttons: VoiceOver hears whose command each one copies.
                .accessibilityLabel(Text(verbatim: L10n.tr("app.plan.copyCommand.a11y", row.categoryName)))
                .task(id: copies) {
                    guard copies > 0 else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }  // cancelled: a newer click, or the view went away
                    copied = false
                }
                if let run {
                    Button(action: run) { Label(L10n.tr("app.plan.run"), systemImage: "play") }
                        .accessibilityLabel(Text(verbatim: L10n.tr("app.plan.run.a11y", row.categoryName)))
                }
            }
            ForEach(Array(row.localizedNotes.enumerated()), id: \.offset) { _, note in
                InlineCodeText(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Park and Run externally (spec §6.4): the plan for the bucket with **Copy command** per row, and **Run…** where the
/// app runs it (R3, ADR-0011, which supersedes §6.4's "no GUI writer").
struct PlanView: View {
    let bucket: SavingsBucket
    let rows: [SavingsPlanRow]
    /// Park's vault line; nil for Run externally, whose commands take a folder, not a vault.
    let vault: VaultStatus?
    let copy: @MainActor (SavingsPlanRow) -> Void
    /// The rows **Run…** is offered for, and what it does (`AppModel.canRun`, `AppModel.openRun`).
    var canRun: @MainActor (SavingsPlanRow) -> Bool = { _ in false }
    var run: @MainActor (SavingsPlanRow) -> Void = { _ in }
    /// The interrupted-migration banner (R3 §10).
    var interrupted: [InterruptedMigration] = []
    var copyCommand: @MainActor (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BucketHeaderView(bucket: bucket)
                InterruptedMigrationsBanner(items: interrupted, copy: copyCommand)
                if let vault {
                    Label {
                        InlineCodeText(AppText.vaultStatus(vault)).font(.callout)
                    } icon: {
                        Image(systemName: Self.vaultSymbol(vault))
                    }
                }
                InlineCodeText(L10n.tr("app.plan.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if rows.isEmpty {
                    Text.l10n(L10n.tr("cli.plan.empty")).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.categoryID) { row in
                    PlanRowView(row: row, copy: { copy(row) }, run: runAction(row))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **Run…** for a row the app runs; nil for a copy-only row.
    private func runAction(_ row: SavingsPlanRow) -> (@MainActor () -> Void)? {
        guard canRun(row) else { return nil }
        let run = self.run
        return { run(row) }
    }

    static func vaultSymbol(_ status: VaultStatus) -> String {
        switch status {
        case .noVault: "externaldrive.badge.plus"
        case .offline: "externaldrive.badge.xmark"
        case .needsAttention: "externaldrive.badge.exclamationmark"
        case .ready: "externaldrive.badge.checkmark"
        }
    }
}

/// Delete (spec §6.4): today's Clean view, grouped by category with a cost-to-undo column and markers; the same Trash
/// toggle, exact-count confirmation and journaling (`CleanExecutor` through `AppModel.applyClean`). The rows another tool
/// deletes (simulator devices, runtimes) are listed with their command and are not selectable here.
struct DeleteView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<String>()
    @State private var confirm = false
    @State private var useTrash = true
    /// The root row whose own button was pressed, waiting on its destructive confirmation.
    @State private var confirmPrivileged: CleanAction?
    /// The notes panel's state once the user opened or closed it; until then `DeleteNotes.startsExpanded` decides.
    @State private var notesExpanded: Bool?

    /// `notesInitiallyExpanded` is for `ScreenFitTests`, which measures the panel opened while the table has rows; the app
    /// passes nil and `DeleteNotes.startsExpanded` decides.
    init(model: AppModel, notesInitiallyExpanded: Bool? = nil) {
        _model = Bindable(model)
        _notesExpanded = State(initialValue: notesInitiallyExpanded)
    }

    var body: some View {
        if let plan = model.cleanPlan, let list = model.deleteList {
            VStack(alignment: .leading, spacing: 10) {
                BucketHeaderView(bucket: .deleteAndRegenerate).padding([.horizontal, .top])
                // Asked for where it matters (spec §6.3), and so never folded away: the helper's row, when a listed row needs
                // root and the helper is not enabled (`AppModel.deleteAccessRow`, from `AccessChecklist.deleteRow`).
                if let access = model.deleteAccessRow {
                    GroupBox { AccessRowView(row: access) { model.handle($0) } }.padding(.horizontal)
                }
                // No floor for the table (R1): a rigid minimum made the screen taller than the window, which pushed the split
                // view's sidebar off the top and left the table undrawn. The table takes whatever the notes and footer leave,
                // and gets the space first: the notes' bounded scroll gives way before it does.
                table(list).layoutPriority(1)
                if let notes = model.deleteNotes, !notes.isEmpty { notesPanel(plan, list, notes) }
                footer(list)
            }
            .onChange(of: model.deleteList) { _, newList in
                // A rescan keeps only the rows still listed selected (`DeleteList.retained`).
                if let newList { selection = newList.retained(selection) } else { selection = [] }
            }
            .confirmationDialog(
                useTrash
                    ? L10n.plural("app.clean.confirm.trash", count: list.deletable(selected: selection).count)
                    : L10n.plural("app.clean.confirm.delete", count: list.deletable(selected: selection).count),
                isPresented: $confirm
            ) {
                Button(useTrash ? L10n.tr("app.clean.action.moveToTrash") : L10n.tr("app.clean.action.delete"), role: .destructive) {
                    Task {
                        await model.applyClean(actions: list.deletable(selected: selection), useTrash: useTrash)
                        selection = []
                    }
                }
            } message: {
                Text.l10n(L10n.tr("app.clean.confirm.message"))
            }
            .confirmationDialog(
                confirmPrivileged?.privilegedAction?.title(in: L10n.locale) ?? "",
                isPresented: Binding(get: { confirmPrivileged != nil }, set: { if !$0 { confirmPrivileged = nil } }),
                presenting: confirmPrivileged
            ) { a in
                Button(L10n.tr("app.clean.privileged.empty", ByteCount.format(a.bytes)), role: .destructive) {
                    if let action = a.privilegedAction { model.request(action) }
                }
            } message: { _ in
                Text.l10n(L10n.tr("app.clean.privileged.message"))
            }
        } else {
            ProgressView()
        }
    }

    /// **Run…** for the runtime row another tool deletes; nil for the devices row, which stays copy-only (R3).
    private func runAction(_ row: SavingsPlanRow) -> (@MainActor () -> Void)? {
        guard model.canRun(row) else { return nil }
        let model = self.model
        return { model.openRun(row) }
    }

    private func table(_ list: DeleteList) -> some View {
        Table(of: CleanAction.self, selection: $selection) {
            TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.bytes)).monospacedDigit() }.width(90)
            // Category names are the catalog's English: StorageCategory data, not app text (S4 Task 2).
            TableColumn(L10n.tr("app.column.category")) { Text(verbatim: $0.categoryName) }
            TableColumn(L10n.tr("app.delete.column.undo")) { a in Text(verbatim: list.undo(of: a).map(AppText.undoCost) ?? "") }
            TableColumn(L10n.tr("app.delete.column.markers")) { MarkerBadges(markers: DeleteList.markers(for: $0)) }
            TableColumn(L10n.tr("app.column.path")) { Text(verbatim: $0.path).font(.system(.body, design: .monospaced)) }
        } rows: {
            ForEach(list.groups) { group in
                Section {
                    ForEach(group.actions) { TableRow($0) }
                } header: {
                    Text.l10n(L10n.tr("app.delete.group.header", group.categoryName, ByteCount.format(group.bytes)))
                }
            }
        }
    }

    /// Everything below the table, in one panel folded by default (R1): the planner's warnings, the root rows, the rows
    /// another tool deletes and the skipped lines. The access row is not here: it stays above the table. Open, it scrolls
    /// inside a bounded height, so it can never push the footer out of the window.
    private func notesPanel(_ plan: CleanPlan, _ list: DeleteList, _ notes: DeleteNotes) -> some View {
        let expanded = notesExpanded ?? notes.startsExpanded
        return VStack(alignment: .leading, spacing: 6) {
            // The disclosure triangle and its label only: a DisclosureGroup's own content keeps its full height, which put a
            // floor under the screen again; the content below is a plain scroll that can shrink to nothing.
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { notesExpanded = $0 })) {
                EmptyView()
            } label: {
                // Names the warnings when there are any (`DeleteNotes.title`): folded, the panel never hides that they exist.
                Text.l10n(AppText.deleteNotesTitle(notes.title)).font(.callout)
            }
            if expanded { notesContent(plan, list) }
        }
        .padding(.horizontal)
    }

    private func notesContent(_ plan: CleanPlan, _ list: DeleteList) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                privileged(plan)
                otherTools(list)
                skipped(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    /// The root rows the helper can act on (the dyld cache): name, the experimental badge in the words every other badge
    /// uses (rule 10), size, and its own button, with the same confirmation as before. What the helper is and how to get
    /// it is the access row above the table, not repeated here.
    @ViewBuilder
    private func privileged(_ plan: CleanPlan) -> some View {
        let privileged = plan.actions.filter { $0.privilegedAction != nil }
        if !privileged.isEmpty {
            GroupBox {
                ForEach(privileged) { a in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: a.categoryName).bold()
                        // The helper's dyld verb is experimental wherever it appears (`app.clean.privileged.message`).
                        MarkerBadges(markers: [.experimental])
                        Text(verbatim: ByteCount.format(a.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        if let action = a.privilegedAction {
                            // Its guidance is left out when the access row above the table already gives it.
                            PrivilegedActionControlView(action: action, state: model.helperState, showsGuidance: model.deleteControlShowsGuidance) {
                                confirmPrivileged = a
                            }
                        }
                    }
                }
            }
        }
    }

    /// Simulator devices and runtimes: deleted by `simctl` / `runtime delete`, never from this list. The runtime row also
    /// has **Run…** (R3); the devices row stays copy-only.
    @ViewBuilder
    private func otherTools(_ list: DeleteList) -> some View {
        if !list.otherTools.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text.l10n(L10n.tr("app.delete.otherTools.detail")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(list.otherTools, id: \.categoryID) { row in
                        PlanRowView(row: row, copy: { model.copyCommand(row) }, run: runAction(row))
                    }
                }
            } label: {
                Text.l10n(L10n.tr("app.delete.otherTools.title"))
            }
        }
    }

    /// What the planner did not offer, and why: one line each, folded away by default.
    @ViewBuilder
    private func skipped(_ plan: CleanPlan) -> some View {
        if !plan.skipped.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.skipped, id: \.self) {
                        Text.l10n(L10n.tr("app.clean.skipped", $0)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text.l10n(L10n.plural("app.delete.skipped.title", count: plan.skipped.count)).font(.callout)
            }
        }
    }

    private func footer(_ list: DeleteList) -> some View {
        HStack {
            let chosen = list.deletable(selected: selection)
            Text.l10n(L10n.plural("app.clean.selected", count: chosen.count, ByteCount.format(chosen.reduce(0) { $0 + $1.bytes })))
            // The CLI has --trash; without this the GUI was strictly more destructive than
            // the CLI with no way to say so, because CleanExecutor() defaults to useTrash: false.
            Toggle(L10n.tr("app.clean.useTrash"), isOn: $useTrash)
            Spacer()
            Button(L10n.tr("app.clean.deleteSelected")) { confirm = true }.disabled(chosen.isEmpty)
        }
        .padding()
    }
}
