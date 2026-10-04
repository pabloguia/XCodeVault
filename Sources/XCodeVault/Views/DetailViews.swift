import AppKit
import SwiftUI
import XCodeVaultCore

// The Details screens (spec 2026-10-03 §6.1): Storage and Simulators here; Drives in DrivesViews.swift; Health and History
// in HealthHistoryViews.swift. Each shows what the scan, the doctor, the vault checks or the journal recorded; none changes
// anything except Health's root-action buttons, which go through `AppModel.request(_:)`. The rows, their order, the filter
// and the search are Core's (`StorageTable`, `SimulatorsTable`), through the model.

/// Storage (R2; one filter model since R5): a chart of the scan's items by option over the table of them. The filter is one
/// set of options, shown three ways that stay in step: the bars (a click shows only that option, ⌘-click adds or removes
/// it), the legend chips under the chart (toggles), and the summary "Filtering: Delete, Park ×" beside **Show All**, which
/// appear whenever anything narrows the table. The search field filters by name or path, combined with the options.
/// Rows can be selected, with Show in Finder and Copy Path. Never color alone: every option shows its symbol and name.
struct StorageView: View {
    @Bindable var model: AppModel
    let report: ScanReport

    /// The chart box's greatest height: modest and bounded, so the screen keeps fitting the window (R1, `ScreenFitTests`); the
    /// rows scroll inside it when wrapped labels make them taller (R7-A).
    static let chartHeight: CGFloat = 130

    var body: some View {
        let bars = model.storageBars(report)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text.l10n(L10n.tr("app.storage.chart.title")).font(.headline)
                Spacer(minLength: 0)
                if model.storageIsFiltered { filterSummary }
            }
            .padding(.horizontal)
            if bars.isEmpty {
                // No row in any option: a sentence, not an empty plot (R2 review M4).
                Text.l10n(L10n.tr("app.storage.chart.none")).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                ChartBox(barCount: bars.count, maximum: Self.chartHeight, title: L10n.tr("app.storage.chart.title")) {
                    StorageBucketChart(bars: bars, selected: model.storageBucketFilter) { model.clickStorageBar($0, extending: $1) }
                }
                .padding(.horizontal)
                legend(bars)
                // A persistent hint (the user's feedback): the chart filters.
                Text.l10n(L10n.tr("app.storage.chart.caption")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal)
            }
            table
        }
        .padding(.top, 8)
        .searchable(text: $model.storageQuery, placement: .toolbar, prompt: Text(verbatim: L10n.tr("app.search.storage")))
    }

    /// "Filtering: Delete, Park" as plain text with the filter symbol, and one **Show All** beside it: always visible while
    /// filtered. No capsule and no second clear (R7-B, audit row 9): one way to clear, and nothing that reads like a chip.
    private var filterSummary: some View {
        HStack(spacing: Spacing.s) {
            Label {
                Text(verbatim: AppText.storageFilterSummary(model.storageFilterBuckets, query: model.storageQuery)).lineLimit(1)
            } icon: {
                Image(systemName: "line.3.horizontal.decrease.circle").accessibilityHidden(true)
            }
            .font(.callout).foregroundStyle(.secondary)
            .help(AppText.storageFilterSummary(model.storageFilterBuckets, query: model.storageQuery))
            Button(L10n.tr("app.storage.filter.clear")) { model.clearStorageFilter() }.actionButton().controlSize(.small)
        }
    }

    /// One filter chip per option with rows (R7-B, §3.3): its symbol, name and size, a checkmark and an accent outline when
    /// on — never a button's look. On when the table shows that option; the bars say the same. Keyboard and VoiceOver reach
    /// the filter here, without a pointer.
    private func legend(_ bars: [StorageTable.BucketBar]) -> some View {
        HStack(spacing: Spacing.s) {
            ForEach(bars) { bar in
                Toggle(isOn: Binding(get: { model.storageBucketFilter.contains(bar.bucket) }, set: { _ in model.toggleStorageBucket(bar.bucket) })) {
                    HStack(spacing: 4) {
                        BucketSymbol(bucket: bar.bucket, decorative: true)
                        Text(verbatim: AppText.bucketShortName(bar.bucket))
                        Text(verbatim: ByteCount.format(bar.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(FilterChipStyle())
                .help(bar.bucket.localizedTitle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
    }

    private var table: some View {
        Table(model.storageRows(report), selection: $model.storageSelection, sortOrder: $model.storageSortOrder) {
            // Category names and outcomes are the catalog's English: StorageCategory data, not app text (S4 Task 2).
            TableColumn(L10n.tr("app.column.size"), sortUsing: StorageTable.Column.size.comparator()) {
                Text(verbatim: ByteCount.format($0.item.allocatedBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn(L10n.tr("app.column.bucket"), sortUsing: StorageTable.Column.bucket.comparator()) { row in
                if let bucket = row.bucket {
                    HStack(spacing: 4) {
                        BucketSymbol(bucket: bucket, decorative: true)
                        Text(verbatim: AppText.bucketShortName(bucket))
                    }
                    .help(bucket.localizedTitle)
                }
            }
            TableColumn(L10n.tr("app.column.category"), sortUsing: StorageTable.Column.category.comparator()) { Text(verbatim: $0.categoryName) }
            TableColumn(L10n.tr("app.column.outcome"), sortUsing: StorageTable.Column.outcome.comparator()) { Text(verbatim: $0.outcome).help($0.outcome) }
            TableColumn(L10n.tr("app.column.strategy"), sortUsing: StorageTable.Column.strategy.comparator()) { row in
                // The strategy's name in words, and the experimental badge every experimental row carries (rule 10).
                HStack(spacing: 4) {
                    Text(verbatim: row.strategy.map(AppText.strategy) ?? "")
                    if row.isExperimental { Tag.marker(.experimental) }
                }
            }
            TableColumn(L10n.tr("app.column.path"), sortUsing: StorageTable.Column.path.comparator()) { row in
                StoragePathCell(item: row.item)
            }
        }
        // Read-only actions: Storage changes nothing (HIG review ST3).
        .contextMenu(forSelectionType: String.self) { ids in
            let paths = model.storagePaths(ids, report: report)
            Button(L10n.tr("app.action.showInFinder")) { model.showInFinder(paths) }.disabled(paths.isEmpty)
            Button(L10n.tr("app.action.copyPath")) { model.copyPaths(paths) }.disabled(paths.isEmpty)
        }
        .overlay {
            if model.storageRows(report).isEmpty, model.storageIsFiltered {
                ContentUnavailableView {
                    Label(L10n.tr("app.search.none"), systemImage: "magnifyingglass")
                } actions: {
                    Button(L10n.tr("app.storage.filter.clear")) { model.clearStorageFilter() }
                }
            }
        }
    }
}

/// A Storage path (R5, HIG review ST4, X3): a symlink, a mount point or an unreadable mount state as a symbol and a short
/// word before the path — the cue stays visible (rule 7) without uppercase text appended to it — and the whole path in
/// its tooltip.
struct StoragePathCell: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 6) {
            if item.isSymlink { marker("arrow.turn.up.right", L10n.tr("app.storage.symlink")) }
            if item.isMountPoint { marker("externaldrive.connected.to.line.below", L10n.tr("app.storage.mountPoint")) }
            if item.mountStateUndetermined { marker("questionmark.circle", L10n.tr("app.storage.mountStateUnreadable")) }
            Text(verbatim: item.path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .help(item.path)
    }

    private func marker(_ symbol: String, _ word: String) -> some View {
        Label {
            Text(verbatim: word)
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
    }
}

/// Simulators (R5, HIG review SI1): a chart of every measured runtime and device over one table with two sections —
/// runtimes, then devices — and shared columns. The table owns its scrolling; the chart's box is bounded and scrolls
/// inside when there are many bars, so the screen fits the window (R1). A click on a bar selects its row and scrolls the
/// table to it; **Clear Selection** and a click in an empty part of the table clear it. The search filters by name,
/// runtime or path. Read-only: runtimes and devices are deleted from the Delete view, never from here. An unmeasured
/// size says so, never zero, and has no bar.
struct SimulatorsView: View {
    @Bindable var model: AppModel
    let report: ScanReport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chart box's most height; a longer chart scrolls inside it.
    static let chartBoxHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart.padding(.horizontal)
            ScrollViewReader { proxy in
                table
                    // Only a chart click scrolls (R2 review M8); Reduce Motion scrolls without animating (HIG review SI4).
                    .onChange(of: model.simulatorScrollRequests) {
                        guard let id = model.simulatorScrollTarget(report) else { return }
                        if reduceMotion { proxy.scrollTo(id, anchor: .center) } else { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
            }
            Text.l10n(L10n.tr("app.simulators.footer")).font(.footnote).foregroundStyle(.secondary).padding([.horizontal, .bottom])
        }
        .padding(.top, 8)
        .searchable(text: $model.simulatorQuery, placement: .toolbar, prompt: Text(verbatim: L10n.tr("app.search.simulators")))
    }

    @ViewBuilder
    private var chart: some View {
        let bars = SimulatorsChart.bars(report: report)
        HStack(alignment: .firstTextBaseline) {
            Text.l10n(L10n.tr("app.simulators.chart.title")).font(.headline)
            if !bars.isEmpty { SimulatorsChartView.legend.padding(.leading, 8) }
            Spacer(minLength: 0)
            if !model.simulatorSelection.isEmpty {
                Button(L10n.tr("app.simulators.clearSelection")) { model.clearSimulatorSelection() }.actionButton().controlSize(.small)
            }
        }
        if bars.isEmpty {
            Text.l10n(L10n.tr("app.simulators.chart.none")).foregroundStyle(.secondary)
        } else {
            ChartBox(barCount: bars.count, maximum: Self.chartBoxHeight, title: L10n.tr("app.simulators.chart.title")) {
                SimulatorsChartView(bars: bars, selection: model.simulatorSelection) { id, _ in model.clickSimulatorBar(id) }
            }
            Text.l10n(L10n.tr("app.simulators.chart.caption")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        let unmeasured = SimulatorsChart.unmeasuredCount(report: report)
        if unmeasured > 0 {
            Text.l10n(L10n.plural("app.simulators.chart.unmeasured", count: unmeasured)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var table: some View {
        let runtimes = model.simulatorRows(report, kind: .runtime)
        let devices = model.simulatorRows(report, kind: .device)
        return Table(of: SimulatorListRow.self, selection: $model.simulatorSelection, sortOrder: $model.simulatorSortOrder) {
            // Names, versions, states and paths are simctl's own record, and the platform Apple's name for it: never translated.
            TableColumn(L10n.tr("app.column.size"), sortUsing: SimulatorsTable.ListColumn.size.comparator()) { row in
                Text(verbatim: row.bytes.map { ByteCount.format($0) } ?? L10n.tr("app.value.notMeasured")).monospacedDigit()
                    .foregroundStyle(row.bytes == nil ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)
            TableColumn(L10n.tr("app.column.name"), sortUsing: SimulatorsTable.ListColumn.name.comparator()) { row in
                Label {
                    Text(verbatim: row.name)
                } icon: {
                    Image(systemName: row.kind.symbolName).foregroundStyle(.secondary)
                }
            }
            TableColumn(L10n.tr("app.column.version"), sortUsing: SimulatorsTable.ListColumn.detail.comparator()) { Text(verbatim: $0.detail) }
            TableColumn(L10n.tr("app.column.state"), sortUsing: SimulatorsTable.ListColumn.state.comparator()) { row in
                // A runtime's mounted image is part of its state; an unknown value is a secondary dash (HIG review SI2).
                Text(verbatim: AppText.simulatorState(row)).foregroundStyle(row.state == nil ? .secondary : .primary)
            }
            TableColumn(L10n.tr("app.column.path"), sortUsing: SimulatorsTable.ListColumn.path.comparator()) { row in
                Text(verbatim: row.path ?? "—").font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(row.path == nil ? .secondary : .primary)
                    .help(row.path ?? "")
            }
        } rows: {
            Section {
                ForEach(runtimes) { TableRow($0) }
            } header: {
                Text.l10n(L10n.tr("app.simulators.runtimes.title", ByteCount.format(SimulatorsTable.runtimesBytes(report: report))))
            }
            Section {
                ForEach(devices) { TableRow($0) }
            } header: {
                // simctl's per-device data size, not the catalog's `du` of the Devices folder that Delete shows (final review M2).
                Text.l10n(L10n.tr("app.simulators.devices.title", ByteCount.format(SimulatorsTable.devicesBytes(report: report))))
                    .help(L10n.tr("app.simulators.devices.caption"))
            }
        }
        .overlay {
            if runtimes.isEmpty, devices.isEmpty {
                if !SimulatorsTable.isSearching(query: model.simulatorQuery) {
                    ContentUnavailableView(L10n.tr("app.simulators.none"), systemImage: "iphone.slash")
                } else {
                    ContentUnavailableView(L10n.tr("app.search.none"), systemImage: "magnifyingglass")
                }
            }
        }
    }
}
