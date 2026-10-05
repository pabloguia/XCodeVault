import Accessibility
import AppKit
import SwiftUI
import XCodeVaultCore

/// The sidebar (spec 2026-10-03 §6.1): **Save space** — the Overview and one view per way of reclaiming — then
/// **Details**.
enum SidebarSection: String, CaseIterable, Identifiable {
    case plan, overview, delete, park, runExternally
    case storage, simulators, drives, health, history, access

    /// The guided Plan first (R7-C): the path through the other views, in order.
    static let saveSpace: [SidebarSection] = [.plan, .overview, .delete, .park, .runExternally]
    static let details: [SidebarSection] = [.storage, .simulators, .drives, .health, .history, .access]
    static var saveSpaceTitle: String { L10n.tr("app.sidebar.saveSpace") }
    static var detailsTitle: String { L10n.tr("app.sidebar.details") }

    /// The view an Overview card's **Review** selects; nil for keeping, which has no view.
    init?(reviewing bucket: SavingsBucket) {
        switch bucket {
        case .deleteAndRegenerate: self = .delete
        case .parkExternally: self = .park
        case .runFromExternal: self = .runExternally
        case .keepLocal: return nil
        }
    }

    var id: String { rawValue }

    /// The bucket a Save-space view shows.
    var bucket: SavingsBucket? {
        switch self {
        case .delete: .deleteAndRegenerate
        case .park: .parkExternally
        case .runExternally: .runFromExternal
        default: nil
        }
    }

    var title: String {
        switch self {
        case .plan: L10n.tr("app.section.plan")
        case .overview: L10n.tr("app.section.overview")
        case .delete: L10n.tr("app.section.delete")
        case .park: L10n.tr("app.section.park")
        case .runExternally: L10n.tr("app.section.runExternally")
        case .storage: L10n.tr("app.section.storage")
        case .simulators: L10n.tr("app.section.simulators")
        case .drives: L10n.tr("app.section.drives")
        case .health: L10n.tr("app.section.health")
        case .history: L10n.tr("app.section.history")
        case .access: L10n.tr("app.section.access")
        }
    }

    /// The sidebar's symbols. Park and Run Externally use their bucket's S5 symbol; Delete uses `trash` here, as a sidebar
    /// item's symbol is its meaning and the bucket's counter-clockwise arrow reads as Undo next to "Delete" (R5, HIG review
    /// N6; BRAND.md records the split — the bucket symbol stays wherever the bucket's title is shown).
    var symbol: String {
        if self == .delete { return "trash" }
        if let bucket { return bucket.symbolName }
        return switch self {
        case .plan: "list.number"
        case .overview: "square.grid.2x2"
        case .storage: "chart.pie"
        case .simulators: "iphone"
        case .drives: "externaldrive"
        case .health: "stethoscope"
        case .history: "list.bullet.rectangle"
        default: "lock.shield"
        }
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section(SidebarSection.saveSpaceTitle) { rows(SidebarSection.saveSpace) }
                Section(SidebarSection.detailsTitle) { rows(SidebarSection.details) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if let r = model.report {
                    detail(r)
                } else if model.section == .access {
                    AccessView(model: model)  // needs no scan
                } else {
                    // A scan in progress, labelled (HIG review N8): not an empty state.
                    ScanningView()
                }
            }
            // The last action's result, inline above the screen until the next action or its × (HIG review N11). Inside the
            // zero-ideal-height frame below, so its wrapped lines never ask the window for height (R5 review I2).
            .safeAreaInset(edge: .top, spacing: 0) {
                if let feedback = model.feedback { FeedbackBanner(feedback: feedback) { model.dismissFeedback() } }
            }
            // The detail takes the column it is given and proposes no height of its own to the window. Without this a screen
            // whose wrapped text is measured at the split view's near-zero ideal width (Delete's header, access row and footer)
            // asked the window for ~4000 pt; the window, centred on that, showed neither the sidebar nor the table (R1, measured).
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
            .toolbar {
                // Back and Forward (R5, HIG review N1): icon-only chevrons with tooltips, ⌘[ and ⌘] as in Safari and
                // Finder, always shown and disabled when there is nowhere to go, so the title never shifts.
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        model.goBack()
                    } label: {
                        Label(L10n.tr("app.action.back"), systemImage: "chevron.backward")
                    }
                    .labelStyle(.iconOnly).help(L10n.tr("app.action.back"))
                    .keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
                    Button {
                        model.goForward()
                    } label: {
                        Label(L10n.tr("app.action.forward"), systemImage: "chevron.forward")
                    }
                    .labelStyle(.iconOnly).help(L10n.tr("app.action.forward"))
                    .keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
                }
                ToolbarItem(placement: .primaryAction) {
                    // One item whose content swaps while scanning (HIG review N9): no item pops in beside it.
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.isScanning {
                            ProgressView().controlSize(.small).accessibilityLabel(Text(verbatim: L10n.tr("app.scanning.title")))
                        } else {
                            Label(L10n.tr("app.action.rescan"), systemImage: "arrow.clockwise")
                        }
                    }
                    .help(L10n.tr("app.action.rescan"))
                    .disabled(model.isScanning || model.isOperationRunning)
                }
            }
            .navigationTitle(model.section.title)
            // The Mac and its disk, or the scan in progress, quietly on every screen (HIG review N2).
            .navigationSubtitle(model.windowSubtitle)
        }
        // The title says what failed, the message why and what to do (R5, HIG review N10).
        .alert(model.lastError?.title ?? "", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button(L10n.tr("app.action.ok")) {
                // Dismissing is the whole action: SwiftUI clears the binding that presents this
                // alert, which the `set:` closure above turns into `lastError = nil`.
            }
        } message: {
            Text(verbatim: model.lastError?.message ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.appDidBecomeActive() }
        }
        // The request and, after Install Helper…, the wait for approval: one sheet, two states (HIG review N12).
        .sheet(isPresented: Binding(get: { model.helperSheetIsPresented }, set: { if !$0 { model.dismissHelperSheet() } })) {
            HelperRequestSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.operationSheet != nil }, set: { if !$0 { model.closeOperationSheet() } })) {
            OperationSheetView(model: model)
        }
    }

    /// Plain labels: in a selected row the symbol takes the selection style (BRAND.md), so no bucket tint here.
    private func rows(_ sections: [SidebarSection]) -> some View {
        ForEach(sections) { s in Label(s.title, systemImage: s.symbol).tag(s) }
    }

    /// The selected section's screen. Internal, not private, so the review snapshots can draw a screen on its own and
    /// `ScreenFitTests` can measure each screen's minimum height, which must fit the window (R1).
    @ViewBuilder
    func detail(_ r: ScanReport) -> some View {
        switch model.section {
        case .plan:
            if let plan = model.plan { GuidedPlanView(plan: plan) { model.performPlanAction($0) } }
        case .overview:
            OverviewView(
                report: r, findings: model.findings, access: model.accessBanner, act: { model.handle($0) }, review: { model.review($0) },
                showHealth: { model.section = .health })
        case .delete: DeleteView(model: model)
        case .park, .runExternally:
            let bucket: SavingsBucket = model.section == .park ? .parkExternally : .runFromExternal
            PlanView(
                bucket: bucket, rows: model.rows(for: bucket), vault: model.section == .park ? model.vaultStatus : nil, copy: { model.copyCommand($0) },
                canRun: { model.canRun($0) }, run: { model.openRun($0) }, interrupted: model.interruptedMigrations,
                copyCommand: { model.environment.copy($0) }, suggestion: { model.commandSuggestion($0) }, showDrives: { model.section = .drives })
        case .storage: StorageView(model: model, report: r)
        case .simulators: SimulatorsView(model: model, report: r)
        case .drives:
            DrivesView(
                list: model.drivesList(r), bar: { model.driveBar($0, report: r) }, external: model.driveAssessments, actions: model.externalDriveActions)
        case .health: HealthView(model: model)
        case .history: HistoryView(model: model)
        case .access: AccessView(model: model)
        }
    }
}

/// A scan in progress (R5, HIG review N8): an indeterminate progress with what is happening, never a bare spinner.
struct ScanningView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.large)
            Text(verbatim: L10n.tr("app.scanning.title")).font(.headline)
            Text(verbatim: L10n.tr("app.scanning.detail")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// An action's result (R5, HIG review N11): its symbol, one line and the details under it, with an × that clears it. Said
/// to VoiceOver once when it appears. The commands in a detail line are monospaced and selectable.
struct FeedbackBanner: View {
    let feedback: AppFeedback
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusIcon(.feedback(feedback.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: feedback.title).font(.callout).bold()
                ForEach(Array(feedback.detail.enumerated()), id: \.offset) { _, line in
                    InlineCodeText(line).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).minimumTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: L10n.tr("app.feedback.dismiss")))
            .help(L10n.tr("app.feedback.dismiss"))
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task(id: feedback) { AccessibilityNotification.Announcement(feedback.title).post() }
    }
}

/// A bucket's S5 symbol in its color, labelled with its localized title for VoiceOver: never color alone. `decorative`
/// where the title is already the next text, so VoiceOver does not say it twice.
struct BucketSymbol: View {
    let bucket: SavingsBucket
    var decorative = false
    var body: some View {
        if decorative {
            image.accessibilityHidden(true)
        } else {
            image.accessibilityLabel(Text(verbatim: bucket.localizedTitle))
        }
    }

    private var image: some View {
        Image(systemName: bucket.symbolName).foregroundStyle(bucket.color)
    }
}
