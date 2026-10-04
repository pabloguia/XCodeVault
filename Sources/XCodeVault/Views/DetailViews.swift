import SwiftUI
import XCodeVaultCore

// The Details screens (spec 2026-10-03 §6.1): Storage, Simulators and Drives here; Health and History in
// HealthHistoryViews.swift. Each shows what the scan, the doctor, the vault checks or the journal recorded; none changes
// anything except Health's root-action buttons, which go through `AppModel.request(_:)`. The rows and their order are
// Core's (`StorageTable`, `SimulatorsTable`).

/// Storage (R2): a chart of the scan's items by savings bucket over the table of them. A click on a bar filters the table to
/// that bucket (a chip says so, with an × to clear it, as does **All**); every column sorts. The rows, the bars, the filter
/// and the order are Core's and the model's (`StorageTable`, `AppModel.storageRows`); the bucket shows its symbol and its
/// title, never its color alone.
struct StorageView: View {
    @Bindable var model: AppModel
    let report: ScanReport

    /// The chart's height: modest and fixed, so the screen keeps fitting the window (R1, `ScreenFitTests`).
    static let chartHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            let bars = model.storageBars(report)
            if bars.isEmpty {
                // No row in any bucket: a sentence, not an empty plot (R2 review M4).
                Text.l10n(L10n.tr("app.storage.chart.none")).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                StorageBucketChart(bars: bars, selected: model.storageBucketFilter) { model.clickStorageBar($0) }
                    .frame(height: Self.chartHeight)
                    .accessibilityLabel(Text(verbatim: L10n.tr("app.storage.chart.title")))
            }
            table
        }
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text.l10n(L10n.tr("app.storage.chart.title")).font(.headline)
            Text.l10n(L10n.tr("app.storage.chart.caption")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let bucket = model.storageBucketFilter {
                // The active filter in words with the bucket's symbol, and an × to clear it.
                HStack(spacing: 4) {
                    BucketSymbol(bucket: bucket, decorative: true)
                    Text.l10n(L10n.tr("app.storage.filter.active", bucket.localizedTitle)).font(.caption)
                    Button {
                        model.clearStorageFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: L10n.tr("app.storage.filter.clear")))
                    .help(L10n.tr("app.storage.filter.clear"))
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
            // The chart's filter without a pointer (R2 review M5): the same buckets, for keyboard and VoiceOver.
            Menu(L10n.tr("app.storage.filter.menu")) {
                ForEach(model.storageBars(report)) { bar in
                    Button {
                        model.chooseStorageFilter(bar.bucket)
                    } label: {
                        Label(bar.bucket.localizedTitle, systemImage: bar.bucket.symbolName)
                    }
                }
            }
            .fixedSize()
            // Nothing to choose from without bars (R2 review N1), as **All** is disabled without a filter.
            .disabled(!model.storageFilterMenuEnabled(report))
            Button(L10n.tr("app.storage.filter.all")) { model.clearStorageFilter() }
                .disabled(model.storageBucketFilter == nil)
        }
        .padding(.horizontal)
    }

    private var table: some View {
        Table(model.storageRows(report), sortOrder: $model.storageSortOrder) {
            // Category names and outcomes are the catalog's English: StorageCategory data, not app text (S4 Task 2).
            TableColumn(L10n.tr("app.column.size"), sortUsing: StorageTable.Column.size.comparator()) {
                Text(verbatim: ByteCount.format($0.item.allocatedBytes)).monospacedDigit()
            }
            .width(90)
            TableColumn(L10n.tr("app.column.bucket"), sortUsing: StorageTable.Column.bucket.comparator()) { row in
                if let bucket = row.bucket {
                    HStack(spacing: 4) {
                        BucketSymbol(bucket: bucket, decorative: true)
                        Text(verbatim: bucket.localizedTitle)
                    }
                }
            }
            TableColumn(L10n.tr("app.column.category"), sortUsing: StorageTable.Column.category.comparator()) { Text(verbatim: $0.categoryName) }
            TableColumn(L10n.tr("app.column.outcome"), sortUsing: StorageTable.Column.outcome.comparator()) { Text(verbatim: $0.outcome) }
            TableColumn(L10n.tr("app.column.strategy"), sortUsing: StorageTable.Column.strategy.comparator()) { row in
                // The strategy's name in words, and the experimental badge every experimental row carries (rule 10).
                HStack(spacing: 4) {
                    Text(verbatim: row.strategy.map(AppText.strategy) ?? "")
                    if row.isExperimental { MarkerBadges(markers: [.experimental]) }
                }
            }
            TableColumn(L10n.tr("app.column.path"), sortUsing: StorageTable.Column.path.comparator()) { row in
                StoragePathCell(item: row.item)
            }
        }
    }
}

/// Simulators: a chart of every measured runtime and device over the installed runtimes and the devices with the size of
/// their data. A click on a bar selects its row and scrolls the page to it (R2); both tables sort. Read-only: runtimes and
/// devices are deleted with `simctl`, never from here (the Delete view lists the commands). An unmeasured size says so,
/// never zero, and has no bar.
struct SimulatorsView: View {
    @Bindable var model: AppModel
    let report: ScanReport

    var body: some View {
        let runtimes = model.simulatorRuntimes(report)
        let devices = model.simulatorDevices(report)
        // One page that scrolls as a whole (R1): each table is exactly as tall as its rows (`SimulatorsTable.fittedTableHeight`)
        // and does not scroll inside, and the chart is as tall as its bars (`SimulatorsChart.height`), so the screen never asks
        // the window for more height than it has.
        ScrollViewReader { proxy in
            ScrollView {
                content(runtimes: runtimes, devices: devices)
            }
            // Only a click on the chart scrolls (R2 review M8): a click in a table leaves the table under the pointer.
            .onChange(of: model.simulatorScrollRequests) {
                guard let target = model.simulatorScrollTarget(report) else { return }
                withAnimation { proxy.scrollTo(target.table, anchor: UnitPoint(x: 0, y: target.anchor)) }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let bars = SimulatorsChart.bars(report: report)
        Text.l10n(L10n.tr("app.simulators.chart.title")).font(.headline)
        if bars.isEmpty {
            Text.l10n(L10n.tr("app.simulators.chart.none")).foregroundStyle(.secondary)
        } else {
            SimulatorsChartView(bars: bars, selection: model.simulatorSelection) { model.clickSimulatorBar($0) }
                .frame(height: SimulatorsChart.height(barCount: bars.count))
                .accessibilityLabel(Text(verbatim: L10n.tr("app.simulators.chart.title")))
            Text.l10n(L10n.tr("app.simulators.chart.caption")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let unmeasured = SimulatorsChart.unmeasuredCount(report: report)
        if unmeasured > 0 {
            Text.l10n(L10n.plural("app.simulators.chart.unmeasured", count: unmeasured)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func content(runtimes: [SimulatorRuntime], devices: [SimulatorDeviceRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            Text.l10n(L10n.tr("app.simulators.runtimes.title", ByteCount.format(SimulatorsTable.runtimesBytes(report: report)))).font(.headline)
            if runtimes.isEmpty {
                Text.l10n(L10n.tr("app.simulators.runtimes.none")).foregroundStyle(.secondary)
            } else {
                Table(
                    runtimes, selection: Binding(get: { model.simulatorSelection.runtimeID }, set: { model.selectRuntimeRow($0) }),
                    sortOrder: $model.runtimeSortOrder
                ) {
                    // Version, build and state are simctl's own record, and the platform Apple's name for it: never translated.
                    TableColumn(L10n.tr("app.column.size"), sortUsing: SimulatorsTable.RuntimeColumn.size.comparator()) {
                        Text(verbatim: $0.sizeBytes.map { ByteCount.format($0) } ?? L10n.tr("app.value.notMeasured")).monospacedDigit()
                    }
                    .width(90)
                    TableColumn(L10n.tr("app.column.platform"), sortUsing: SimulatorsTable.RuntimeColumn.platform.comparator()) {
                        Text(verbatim: $0.platformDisplayName)
                    }
                    TableColumn(L10n.tr("app.column.version"), sortUsing: SimulatorsTable.RuntimeColumn.version.comparator()) {
                        Text(verbatim: [$0.version, $0.build.map { "(" + $0 + ")" }].compactMap { $0 }.joined(separator: " "))
                    }
                    TableColumn(L10n.tr("app.column.state"), sortUsing: SimulatorsTable.RuntimeColumn.state.comparator()) {
                        Text(verbatim: $0.state ?? "—").foregroundStyle($0.state == nil ? .secondary : .primary)
                    }
                    TableColumn(L10n.tr("app.column.mounted"), sortUsing: SimulatorsTable.RuntimeColumn.mounted.comparator()) {
                        Text(verbatim: $0.isMounted ? L10n.tr("app.value.yes") : L10n.tr("app.value.no"))
                    }
                    TableColumn(L10n.tr("app.column.image"), sortUsing: SimulatorsTable.RuntimeColumn.image.comparator()) {
                        Text(verbatim: $0.path ?? "").font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(height: SimulatorsTable.fittedTableHeight(rowCount: runtimes.count))
                .id(SimulatorBar.Kind.runtime)
            }
            Text.l10n(L10n.tr("app.simulators.devices.title", ByteCount.format(SimulatorsTable.devicesBytes(report: report)))).font(.headline)
            // simctl's per-device data size, not the catalog's `du` of the Devices folder that Delete shows (final review M2).
            Text.l10n(L10n.tr("app.simulators.devices.caption")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if devices.isEmpty {
                Text.l10n(L10n.tr("app.simulators.devices.none")).foregroundStyle(.secondary)
            } else {
                Table(
                    devices, selection: Binding(get: { model.simulatorSelection.deviceID }, set: { model.selectDeviceRow($0) }),
                    sortOrder: $model.deviceSortOrder
                ) {
                    TableColumn(L10n.tr("app.column.size"), sortUsing: SimulatorsTable.DeviceColumn.size.comparator()) {
                        Text(verbatim: $0.bytes.map { ByteCount.format($0) } ?? L10n.tr("app.value.notMeasured")).monospacedDigit()
                    }
                    .width(90)
                    TableColumn(L10n.tr("app.column.name"), sortUsing: SimulatorsTable.DeviceColumn.name.comparator()) { Text(verbatim: $0.device.name) }
                    TableColumn(L10n.tr("app.column.runtime"), sortUsing: SimulatorsTable.DeviceColumn.runtime.comparator()) { Text(verbatim: $0.runtime) }
                    TableColumn(L10n.tr("app.column.state"), sortUsing: SimulatorsTable.DeviceColumn.state.comparator()) { Text(verbatim: $0.device.state) }
                    TableColumn(L10n.tr("app.column.path"), sortUsing: SimulatorsTable.DeviceColumn.path.comparator()) {
                        Text(verbatim: $0.device.dataPath ?? "").font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(height: SimulatorsTable.fittedTableHeight(rowCount: devices.count))
                .id(SimulatorBar.Kind.device)
            }
            Text.l10n(L10n.tr("app.simulators.footer")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
