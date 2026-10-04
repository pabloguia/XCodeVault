import SwiftUI
import XCodeVaultCore

// The Details screens (spec 2026-10-03 §6.1): Storage, Simulators, Drives, Health, History. Each shows what the scan,
// the doctor, the vault checks or the journal recorded; none changes anything except Health's root-action buttons, which
// go through `AppModel.request(_:)`. The rows and their order are Core's (`StorageTable`, `SimulatorsTable`).

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
            TableColumn(L10n.tr("app.column.strategy"), sortUsing: StorageTable.Column.strategy.comparator()) {
                Text(verbatim: AppText.name($0.strategy?.rawValue ?? "", experimental: $0.isExperimental))
            }
            TableColumn(L10n.tr("app.column.path"), sortUsing: StorageTable.Column.path.comparator()) { row in
                let it = row.item
                let marks =
                    (it.isSymlink ? "  " + L10n.tr("app.storage.symlink") : "") + (it.isMountPoint ? "  " + L10n.tr("app.storage.mountPoint") : "")
                    + (it.mountStateUndetermined ? "  " + L10n.tr("app.storage.mountStateUnreadable") : "")
                Text(verbatim: it.path + marks).font(.system(.body, design: .monospaced))
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
                        Text(verbatim: ($0.version ?? "?") + " (" + ($0.build ?? "?") + ")")
                    }
                    TableColumn(L10n.tr("app.column.state"), sortUsing: SimulatorsTable.RuntimeColumn.state.comparator()) { Text(verbatim: $0.state ?? "?") }
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

/// Drives (R1): one row per drive — the running system's volume group as one "Internal disk (boot)" row — with whether it
/// qualifies as a vault, a vault badge on the row of a registered vault's own volume, and a section only for the vaults
/// that are not connected. The rows are Core's (`DrivesList`), through `AppModel.drivesList`.
struct DrivesView: View {
    let list: DrivesList
    /// Each row's usage bar (R2, `AppModel.driveBar`); nil draws none.
    var bar: (DriveRow) -> DiskBar? = { _ in nil }
    var body: some View {
        List {
            Section(L10n.tr("app.volumes.mounted")) {
                ForEach(list.rows) { DriveRowView(row: $0, bar: bar($0)) }
            }
            if list.hasNoVaults {
                Section(L10n.tr("app.volumes.vaults")) {
                    Text.l10n(L10n.tr("app.volumes.vaults.none")).foregroundStyle(.secondary)
                }
            } else if !list.offlineVaults.isEmpty {
                Section(L10n.tr("app.volumes.vaults.offline")) {
                    // By position: a damaged registry can hold one UUID twice, and both entries are shown.
                    ForEach(Array(list.offlineVaults.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading) {
                            HStack {
                                // The state's words and its symbol first (`DrivesList.offlineSymbol`); the color only repeats them.
                                Label(AppText.vaultState(c.state), systemImage: DrivesList.offlineSymbol(for: c)).bold()
                                    .foregroundStyle(c.isUsable ? .green : .red)
                                Text(verbatim: c.volume.volumeName)
                            }
                            Text(verbatim: c.detail).font(.caption)
                        }
                    }
                }
            }
        }
    }
}

/// One Drives row: the name (or "Internal disk (boot)"), the facts, the vault badge, the blockers always, and the warnings
/// folded behind their count (`DriveRow.warningsStartCollapsed`).
struct DriveRowView: View {
    let row: DriveRow
    /// The drive's usage (R2): other data, developer data by bucket, free, with a legend; nil when its size is unknown.
    var bar: DiskBar?
    @State private var showsWarnings: Bool?

    var body: some View {
        let v = row.volume
        let q = row.qualification
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: row.isBootGroup ? L10n.tr("app.volumes.bootGroup") : v.volumeName).bold()
                Text(verbatim: v.filesystemPersonality)
                Text(verbatim: v.busProtocol)
                Text(verbatim: v.isInternal ? L10n.tr("app.volumes.internal") : L10n.tr("app.volumes.external"))
                if let vault = row.vault, let symbol = row.vaultSymbolName {
                    // The vault's state in words, with its symbol: never color alone.
                    Label(L10n.tr("app.volumes.vaultBadge", AppText.vaultState(vault.state)), systemImage: symbol)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help(vault.detail)
                }
                Spacer()
                Text.l10n(L10n.tr("app.volumes.free", ByteCount.format(v.freeBytes))).monospacedDigit()
            }
            Text(verbatim: v.isBootVolume ? L10n.tr("app.volumes.bootVolume") : AppText.verdict(q.verdict)).font(.caption)
                .foregroundStyle(.secondary)
            if let bar {
                // On a vault: what the scan found there, against other data; the registry keeps no sizes (R2 follow-up).
                DiskBarView(
                    bar: bar, caption: row.vault == nil ? nil : L10n.tr("app.volumes.bar.vault"),
                    accessibilityTitle: L10n.tr("app.volumes.bar.a11y", row.isBootGroup ? L10n.tr("app.volumes.bootGroup") : v.volumeName),
                    barHeight: 12
                )
                .padding(.vertical, 4)
            }
            // A mark and a sentence before the color: never color alone.
            ForEach(q.blockers, id: \.self) { Text(verbatim: "✗ " + $0).font(.caption).foregroundStyle(.red) }
            // A mounted vault that is not usable says why in visible text, not only in the badge's tooltip
            // (`DriveRow.showsVaultDetail`).
            if let vault = row.vault, row.showsVaultDetail {
                Text(verbatim: vault.detail).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            // Further registry entries for this volume (`DriveRow.duplicateVaults`): shown, never dropped.
            ForEach(Array(row.duplicateVaults.enumerated()), id: \.offset) { _, extra in
                Label(L10n.tr("app.volumes.vaultBadge", AppText.vaultState(extra.state)) + " — " + extra.detail, systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if !q.warnings.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { showsWarnings ?? !row.warningsStartCollapsed }, set: { showsWarnings = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(q.warnings, id: \.self) {
                            Text(verbatim: "! " + $0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } label: {
                    Text.l10n(L10n.plural("app.volumes.warnings.count", count: q.warnings.count)).font(.caption)
                }
            }
        }
    }
}

/// Health: the doctor's findings, with the proposed fix and, where the helper can apply it, the action's control.
struct HealthView: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.findings.isEmpty {
            ContentUnavailableView(L10n.tr("app.doctor.empty"), systemImage: "checkmark.seal")
        } else {
            List(model.findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // The severity word is there; the color only repeats it.
                        Text(verbatim: AppText.severity(f.severity)).font(.caption).bold()
                            .foregroundStyle(f.severity >= .error ? .red : (f.severity == .warning ? .orange : .secondary))
                        Text(verbatim: f.title).bold()
                    }
                    Text(verbatim: f.detail).font(.callout)
                    if let p = f.path { Text(verbatim: p).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    if let r = f.remediation { Text(verbatim: "→ " + r).font(.callout) }
                    // The finding carries the action; the button never re-derives it (carried note 2).
                    if let action = f.action {
                        PrivilegedActionControlView(action: action, state: model.helperState) { model.request(action) }
                    }
                    if let e = f.evidence { Text.l10n(L10n.tr("app.doctor.evidence", e)).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// History: the last 100 journal entries, newest first.
struct HistoryView: View {
    let entries: [JournalEntry]
    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                L10n.tr("app.journal.empty.title"), systemImage: "list.bullet.rectangle", description: Text.l10n(L10n.tr("app.journal.empty.detail")))
        } else {
            Table(entries) {
                // Kind, state and summary are the journal's own record: never translated (docs/process/LOCALIZATION.md).
                TableColumn(L10n.tr("app.column.sequence")) { Text(verbatim: String($0.sequence)) }.width(40)
                TableColumn(L10n.tr("app.column.when")) { Text(verbatim: AppText.date($0.timestamp)) }
                TableColumn(L10n.tr("app.column.kind")) { Text(verbatim: $0.kind.rawValue) }
                TableColumn(L10n.tr("app.column.state")) { Text(verbatim: $0.state.rawValue) }
                TableColumn(L10n.tr("app.column.summary")) { Text(verbatim: $0.summary) }
            }
        }
    }
}
