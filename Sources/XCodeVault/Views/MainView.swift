import AppKit
import SwiftUI
import XCodeVaultCore

/// The sidebar (spec 2026-10-03 §6.1): **Save space** — the Overview and one view per way of reclaiming — then
/// **Details**.
enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, delete, park, runExternally
    case storage, simulators, drives, health, history, access

    static let saveSpace: [SidebarSection] = [.overview, .delete, .park, .runExternally]
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

    /// The bucket views use their bucket's S5 symbol.
    var symbol: String {
        if let bucket { return bucket.symbolName }
        return switch self {
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
                    PermissionsView(model: model)  // needs no scan
                } else {
                    ContentUnavailableView(
                        L10n.tr("app.scanning.title"), systemImage: "magnifyingglass",
                        description: Text.l10n(L10n.tr("app.scanning.detail")))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(L10n.tr("app.action.rescan"), systemImage: "arrow.clockwise")
                    }.disabled(model.isScanning)
                }
                if model.isScanning { ToolbarItem { ProgressView().controlSize(.small) } }
            }
            .navigationTitle(model.section.title)
        }
        .alert(L10n.tr("app.alert.error.title"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button(L10n.tr("app.action.ok")) {
                // Dismissing is the whole action: SwiftUI clears the binding that presents this
                // alert, which the `set:` closure above turns into `lastError = nil`.
            }
        } message: {
            Text(verbatim: model.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.appDidBecomeActive() }
        }
        .sheet(isPresented: $model.showsHelperSheet) { HelperRequestSheet(model: model) }
        .overlay(alignment: .top) {
            if let progress = model.helperProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(verbatim: progress)
                    Button(L10n.tr("app.helper.stopWaiting")) { model.stopWaitingForApproval() }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .alert(
            L10n.tr("app.alert.done.title"),
            isPresented: Binding(get: { model.lastPrivilegedResult != nil }, set: { if !$0 { model.lastPrivilegedResult = nil } })
        ) {
            Button(L10n.tr("app.action.ok")) {
                // Dismissing is the whole action, as with the error alert above.
            }
        } message: {
            Text(verbatim: model.lastPrivilegedResult ?? "")
        }
    }

    /// Plain labels: in a selected row the symbol takes the selection style (BRAND.md), so no bucket tint here.
    private func rows(_ sections: [SidebarSection]) -> some View {
        ForEach(sections) { s in Label(s.title, systemImage: s.symbol).tag(s) }
    }

    @ViewBuilder
    private func detail(_ r: ScanReport) -> some View {
        switch model.section {
        case .overview:
            OverviewView(report: r, findings: model.findings, access: model.accessBanner, act: { model.handle($0) }, review: { model.review($0) })
        case .delete: CleanView(model: model)  // Task 4 turns this into the Delete view.
        case .park: BucketPlaceholderView(bucket: .parkExternally)
        case .runExternally: BucketPlaceholderView(bucket: .runFromExternal)
        case .storage: StorageView(report: r)
        case .simulators: RuntimesView(report: r)
        case .drives: VolumesView(report: r, checks: model.vaultChecks)
        case .health: DoctorView(model: model)
        case .history: JournalView(entries: model.journal)
        case .access: PermissionsView(model: model)
        }
    }
}

/// Park and Run externally until their plans arrive (S4 Task 4): what the bucket promises and what undoing it costs.
struct BucketPlaceholderView: View {
    let bucket: SavingsBucket
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: bucket.localizedTitle)
            } icon: {
                BucketSymbol(bucket: bucket)
            }
        } description: {
            Text(verbatim: bucket.localizedPromise + " " + bucket.localizedUndoCost)
        }
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
