import SwiftUI
import XCodeVaultCore

// The Details screens (spec 2026-10-03 §6.1): Storage, Simulators, Drives, Health, History. Each shows what the scan,
// the doctor, the vault checks or the journal recorded; none changes anything except Health's root-action buttons, which
// go through `AppModel.request(_:)`. The rows and their order are Core's (`StorageTable`, `SimulatorsTable`).

/// Storage: every item the scan found, largest first, with the bucket the savings model counts it under — its symbol
/// and its title, never its color alone.
struct StorageView: View {
    let report: ScanReport
    var body: some View {
        Table(StorageTable.rows(report: report)) {
            // Category names and outcomes are the catalog's English: StorageCategory data, not app text (S4 Task 2).
            TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.item.allocatedBytes)).monospacedDigit() }.width(90)
            TableColumn(L10n.tr("app.column.bucket")) { row in
                if let bucket = row.bucket {
                    HStack(spacing: 4) {
                        BucketSymbol(bucket: bucket, decorative: true)
                        Text(verbatim: bucket.localizedTitle)
                    }
                }
            }
            TableColumn(L10n.tr("app.column.category")) { Text(verbatim: $0.categoryName) }
            TableColumn(L10n.tr("app.column.outcome")) { Text(verbatim: $0.outcome) }
            TableColumn(L10n.tr("app.column.strategy")) { Text(verbatim: AppText.name($0.strategy?.rawValue ?? "", experimental: $0.isExperimental)) }
            TableColumn(L10n.tr("app.column.path")) { row in
                let it = row.item
                let marks =
                    (it.isSymlink ? "  " + L10n.tr("app.storage.symlink") : "") + (it.isMountPoint ? "  " + L10n.tr("app.storage.mountPoint") : "")
                    + (it.mountStateUndetermined ? "  " + L10n.tr("app.storage.mountStateUnreadable") : "")
                Text(verbatim: it.path + marks).font(.system(.body, design: .monospaced))
            }
        }
    }
}

/// Simulators: the installed runtimes and the devices with the size of their data. Read-only: runtimes and devices are
/// deleted by `simctl` and `xcodebuild`, never from here (the Delete view lists their commands).
struct SimulatorsView: View {
    let report: ScanReport
    var body: some View {
        let runtimes = SimulatorsTable.runtimes(report: report)
        let devices = SimulatorsTable.devices(report: report)
        VStack(alignment: .leading, spacing: 8) {
            Text.l10n(L10n.tr("app.simulators.runtimes.title", ByteCount.format(SimulatorsTable.runtimesBytes(report: report)))).font(.headline)
            if runtimes.isEmpty {
                Text.l10n(L10n.tr("app.simulators.runtimes.none")).foregroundStyle(.secondary)
            } else {
                Table(runtimes) {
                    // Platform, version, build and state are simctl's own record: never translated.
                    TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.sizeBytes ?? 0)).monospacedDigit() }.width(90)
                    TableColumn(L10n.tr("app.column.platform")) { Text(verbatim: $0.platformName) }
                    TableColumn(L10n.tr("app.column.version")) { Text(verbatim: ($0.version ?? "?") + " (" + ($0.build ?? "?") + ")") }
                    TableColumn(L10n.tr("app.column.state")) { Text(verbatim: $0.state ?? "?") }
                    TableColumn(L10n.tr("app.column.mounted")) { Text(verbatim: $0.isMounted ? L10n.tr("app.value.yes") : L10n.tr("app.value.no")) }
                    TableColumn(L10n.tr("app.column.image")) { Text(verbatim: $0.path ?? "").font(.system(.caption, design: .monospaced)) }
                }
                .frame(minHeight: 140)
            }
            Text.l10n(L10n.tr("app.simulators.devices.title", ByteCount.format(SimulatorsTable.devicesBytes(report: report)))).font(.headline)
            if devices.isEmpty {
                Text.l10n(L10n.tr("app.simulators.devices.none")).foregroundStyle(.secondary)
            } else {
                Table(devices) {
                    // An unmeasured device shows no size rather than a zero.
                    TableColumn(L10n.tr("app.column.size")) { Text(verbatim: $0.bytes.map { ByteCount.format($0) } ?? "").monospacedDigit() }.width(90)
                    TableColumn(L10n.tr("app.column.name")) { Text(verbatim: $0.device.name) }
                    TableColumn(L10n.tr("app.column.runtime")) { Text(verbatim: $0.runtime) }
                    TableColumn(L10n.tr("app.column.state")) { Text(verbatim: $0.device.state) }
                    TableColumn(L10n.tr("app.column.path")) { Text(verbatim: $0.device.dataPath ?? "").font(.system(.caption, design: .monospaced)) }
                }
                .frame(minHeight: 140)
            }
            Text.l10n(L10n.tr("app.simulators.footer")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Drives: mounted volumes, whether each qualifies as a vault, and the registered vault volumes.
struct DrivesView: View {
    let report: ScanReport
    let checks: [VaultVolumeCheck]
    var body: some View {
        List {
            Section(L10n.tr("app.volumes.mounted")) {
                ForEach(report.volumes) { v in
                    let q = VolumeQualification.evaluate(v)
                    VStack(alignment: .leading) {
                        HStack {
                            Text(verbatim: v.volumeName).bold()
                            Text(verbatim: v.filesystemPersonality)
                            Text(verbatim: v.busProtocol)
                            Text(verbatim: v.isInternal ? L10n.tr("app.volumes.internal") : L10n.tr("app.volumes.external"))
                            Spacer()
                            Text.l10n(L10n.tr("app.volumes.free", ByteCount.format(v.freeBytes))).monospacedDigit()
                        }
                        Text(verbatim: v.isBootVolume ? L10n.tr("app.volumes.bootVolume") : AppText.verdict(q.verdict)).font(.caption)
                            .foregroundStyle(.secondary)
                        // A mark and a sentence before the color: never color alone.
                        ForEach(q.blockers, id: \.self) { Text(verbatim: "✗ " + $0).font(.caption).foregroundStyle(.red) }
                        ForEach(q.warnings, id: \.self) { Text(verbatim: "! " + $0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section(L10n.tr("app.volumes.vaults")) {
                if checks.isEmpty { Text.l10n(L10n.tr("app.volumes.vaults.none")).foregroundStyle(.secondary) }
                ForEach(checks, id: \.volume.volumeUUID) { c in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(verbatim: AppText.vaultState(c.state)).bold().foregroundStyle(c.isUsable ? .green : .red)
                            Text(verbatim: c.volume.volumeName)
                        }
                        Text(verbatim: c.detail).font(.caption)
                    }
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
