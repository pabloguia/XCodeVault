import SwiftUI
import XCodeVaultCore

/// The GUI is a projection of XCodeVaultCore: every number and action here comes from the same
/// Scanner / Doctor / CleanPlanner / VaultVerifier the CLI uses (ADR-0003).
@main
struct XCodeVaultApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("XCodeVault") {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Rescan") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

@MainActor @Observable
final class AppModel {
    var report: ScanReport?
    var findings: [Finding] = []
    var vaultChecks: [VaultVolumeCheck] = []
    var cleanPlan: CleanPlan?
    var journal: [JournalEntry] = []
    var isScanning = false
    var lastError: String?
    var lastCleanResult: CleanResult?

    func refresh() async {
        isScanning = true; lastError = nil
        let (report, findings, checks, plan, journal) = await Task.detached(priority: .userInitiated) { () -> (ScanReport, [Finding], [VaultVolumeCheck], CleanPlan, [JournalEntry]) in
            let report = XCodeVaultCore.Scanner().scan()
            let doctor = Doctor()
            let findings = doctor.diagnose(report: report) + doctor.diagnoseVault(report: report)
            let checks = (try? VaultVerifier().checkAll()) ?? []
            let plan = CleanPlanner().plan(report: report)
            let journal = (try? Journal().entries()) ?? []
            return (report, findings, checks, plan, journal)
        }.value
        self.report = report; self.findings = findings; self.vaultChecks = checks; self.cleanPlan = plan; self.journal = journal.suffix(100).reversed()
        isScanning = false
    }

    func applyClean(actions: [CleanAction]) async {
        guard let plan = cleanPlan else { return }
        let selected = CleanPlan(actions: actions, skipped: plan.skipped, warnings: plan.warnings)
        do {
            let result = try await Task.detached { try CleanExecutor().execute(selected) }.value
            lastCleanResult = result
            await refresh()
        } catch { lastError = "\(error)" }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview", storage = "Storage", doctor = "Doctor", clean = "Clean", volumes = "Volumes", runtimes = "Runtimes", journal = "Journal"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "internaldrive"; case .storage: "chart.pie"; case .doctor: "stethoscope"; case .clean: "trash"
        case .volumes: "externaldrive"; case .runtimes: "iphone"; case .journal: "list.bullet.rectangle"
        }
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var section: SidebarSection = .overview
    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { s in Label(s.rawValue, systemImage: s.symbol).tag(s) }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                if let r = model.report {
                    switch section {
                    case .overview: OverviewView(report: r, findings: model.findings)
                    case .storage: StorageView(report: r)
                    case .doctor: DoctorView(findings: model.findings)
                    case .clean: CleanView(model: model)
                    case .volumes: VolumesView(report: r, checks: model.vaultChecks)
                    case .runtimes: RuntimesView(report: r)
                    case .journal: JournalView(entries: model.journal)
                    }
                } else {
                    ContentUnavailableView("Scanning…", systemImage: "magnifyingglass", description: Text("Discovering Xcodes, runtimes, volumes and measuring storage. Nothing is changed."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(model.isScanning)
                }
                if model.isScanning { ToolbarItem { ProgressView().controlSize(.small) } }
            }
            .navigationTitle(section.rawValue)
        }
        .alert("Error", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) { Button("OK") {} } message: { Text(model.lastError ?? "") }
    }
}

struct OverviewView: View {
    let report: ScanReport; let findings: [Finding]
    var body: some View {
        let s = report.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("macOS \(report.host.macOSVersion) · \(report.host.architecture) · \(ByteCount.format(report.host.dataVolumeFreeBytes)) free of \(ByteCount.format(report.host.dataVolumeTotalBytes)) internal").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Internal developer storage", s.internalDeveloperBytes, s.lowerBound ? "lower bound" : nil)
                    row("  of which simulator runtime images", s.runtimeImageBytes, "delete with simctl; keep installers external")
                    row("Safely cleanable", s.cleanableBytes, nil)
                    row("Relocatable (supported mechanisms)", s.relocatableBytes, nil)
                    row("Apple-managed (info only)", s.appleManagedBytes, nil)
                    row("Must remain local", s.mustRemainLocalBytes, nil)
                    row("Reclaimable from the boot volume", s.estimatedInternalSavingsBytes, "via recommended actions")
                    row("  with verified strategies only", s.verifiedSavingsBytes, "the rest is experimental")
                }
                if !report.warnings.isEmpty {
                    GroupBox("Before you act") { VStack(alignment: .leading) { ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } } }
                }
                let critical = findings.filter { $0.severity >= .error }
                if !critical.isEmpty {
                    GroupBox("Doctor: \(critical.count) issue(s) need attention") { VStack(alignment: .leading) { ForEach(critical) { Text("\($0.severity.rawValue.uppercased()): \($0.title)") } } }
                }
                Text("Every strategy marked (experimental) has not met the Definition of Done for your macOS/Xcode combination. Nothing in this app deletes non-regenerable data automatically.").font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
    }
    func row(_ label: String, _ bytes: UInt64, _ note: String?) -> some View {
        GridRow { Text(label); Text(ByteCount.format(bytes)).monospacedDigit().bold(); Text(note ?? "").foregroundStyle(.secondary).font(.caption) }
    }
}

struct StorageView: View {
    let report: ScanReport
    var body: some View {
        let items = report.items.filter { $0.exists }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        Table(items) {
            TableColumn("Size") { Text(ByteCount.format($0.allocatedBytes)).monospacedDigit() }.width(90)
            TableColumn("Category") { Text(report.category(for: $0)?.name ?? $0.categoryID) }
            TableColumn("Outcome") { Text(report.category(for: $0)?.outcomeLabel ?? "") }
            TableColumn("Strategy") { it in let c = report.category(for: it); Text((c?.recommendedStrategy.rawValue ?? "") + ((c?.isExperimental ?? false) ? " (experimental)" : "")) }
            TableColumn("Path") { it in Text(it.path + (it.isSymlink ? "  → SYMLINK" : "") + (it.isMountPoint ? "  [mount point]" : "")).font(.system(.body, design: .monospaced)) }
        }
    }
}

struct DoctorView: View {
    let findings: [Finding]
    var body: some View {
        if findings.isEmpty { ContentUnavailableView("No findings", systemImage: "checkmark.seal") } else {
            List(findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(f.severity.rawValue.uppercased()).font(.caption).bold().foregroundStyle(f.severity >= .error ? .red : (f.severity == .warning ? .orange : .secondary)); Text(f.title).bold() }
                    Text(f.detail).font(.callout)
                    if let p = f.path { Text(p).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    if let r = f.remediation { Text("→ " + r).font(.callout) }
                    if let e = f.evidence { Text("evidence: " + e).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
        }
    }
}

struct CleanView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<String>()
    @State private var confirm = false
    var body: some View {
        if let plan = model.cleanPlan {
            VStack(alignment: .leading) {
                Table(plan.actions, selection: $selection) {
                    TableColumn("Size") { Text(ByteCount.format($0.bytes)).monospacedDigit() }.width(90)
                    TableColumn("Category") { Text($0.categoryName + ($0.isExperimental ? " (experimental)" : "")) }
                    TableColumn("Path") { Text($0.path).font(.system(.body, design: .monospaced)) }
                    TableColumn("Needs") { Text($0.requiresRoot ? "privileged helper (not available yet)" : "") }
                }
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                ForEach(plan.skipped, id: \.self) { Text("skipped: " + $0).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    let chosen = plan.actions.filter { selection.contains($0.id) && !$0.requiresRoot }
                    Text("\(chosen.count) selected · \(ByteCount.format(chosen.reduce(0) { $0 + $1.bytes }))")
                    Spacer()
                    Button("Delete selected…") { confirm = true }.disabled(chosen.isEmpty)
                }.padding()
            }
            .confirmationDialog("Delete \(selection.count) item(s) permanently?", isPresented: $confirm) {
                Button("Delete", role: .destructive) { Task { await model.applyClean(actions: plan.actions.filter { selection.contains($0.id) && !$0.requiresRoot }); selection = [] } }
            } message: { Text("Only regenerable data is listed here. Xcode will rebuild it on demand. Non-regenerable data (Archives) never appears in this list. Deletions are journaled.") }
        } else { ProgressView() }
    }
}

struct VolumesView: View {
    let report: ScanReport; let checks: [VaultVolumeCheck]
    var body: some View {
        List {
            Section("Mounted volumes") {
                ForEach(report.volumes) { v in
                    let q = VolumeQualification.evaluate(v)
                    VStack(alignment: .leading) {
                        HStack { Text(v.volumeName).bold(); Text(v.filesystemPersonality); Text(v.busProtocol); Text(v.isInternal ? "internal" : "external"); Spacer(); Text("free \(ByteCount.format(v.freeBytes))").monospacedDigit() }
                        Text(v.isBootVolume ? "boot volume" : q.verdict.rawValue).font(.caption).foregroundStyle(.secondary)
                        ForEach(q.blockers, id: \.self) { Text("✗ " + $0).font(.caption).foregroundStyle(.red) }
                        ForEach(q.warnings, id: \.self) { Text("! " + $0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section("Vault volumes (identified by UUID + sentinel)") {
                if checks.isEmpty { Text("None registered. Use `xcodevaultctl vault init /Volumes/<name>`.").foregroundStyle(.secondary) }
                ForEach(checks, id: \.volume.volumeUUID) { c in
                    VStack(alignment: .leading) { HStack { Text(c.state.rawValue.uppercased()).bold().foregroundStyle(c.isUsable ? .green : .red); Text(c.volume.volumeName) }; Text(c.detail).font(.caption) }
                }
            }
        }
    }
}

struct RuntimesView: View {
    let report: ScanReport
    var body: some View {
        Table(report.runtimes) {
            TableColumn("Platform") { Text($0.platformName) }
            TableColumn("Version") { Text(($0.version ?? "?") + " (" + ($0.build ?? "?") + ")") }
            TableColumn("State") { Text($0.state ?? "?") }
            TableColumn("Size") { Text(ByteCount.format($0.sizeBytes ?? 0)).monospacedDigit() }
            TableColumn("Mounted") { Text($0.isMounted ? "yes" : "NO") }
            TableColumn("Image") { Text($0.path ?? "").font(.system(.caption, design: .monospaced)) }
        }
    }
}

struct JournalView: View {
    let entries: [JournalEntry]
    var body: some View {
        if entries.isEmpty { ContentUnavailableView("Journal is empty", systemImage: "list.bullet.rectangle", description: Text("Every change XCodeVault makes is recorded here.")) } else {
            Table(entries) {
                TableColumn("#") { Text("\($0.sequence)") }.width(40)
                TableColumn("When") { Text($0.timestamp.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Kind") { Text($0.kind.rawValue) }
                TableColumn("State") { Text($0.state.rawValue) }
                TableColumn("Summary") { Text($0.summary) }
            }
        }
    }
}
