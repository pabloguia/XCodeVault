import AppKit
import Combine
import SwiftUI
import XCodeVaultCore

/// The GUI is a projection of XCodeVaultCore: every number and action here comes from the same
/// Scanner / Doctor / CleanPlanner / VaultVerifier the CLI uses (ADR-0003).
@main
struct XCodeVaultApp: App {
    @State private var model = AppModel()

    /// Before any tool runs: once the user grants Full Disk Access, every tool the app starts works inside
    /// that grant, so what `xcrun` resolves must not come from this process's inherited environment.
    init() {
        GrantedToolEnvironment.applyToThisProcess()
    }

    var body: some Scene {
        WindowGroup("XCodeVault") {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Deliberately empty — an empty replacement is how AppKit's File > New item is
                // removed. XCodeVault has no document model, so "New" would have nothing to make.
            }
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
    /// Every scan starts through this: never two at once, and one more after the running one when a scan was
    /// asked for meanwhile (`ScanGate`, in Core and tested; carried note 7 of the 2026-09-27 permissions plan).
    private var scanGate = ScanGate()
    var isScanning: Bool { scanGate.isScanning }
    var lastError: String?
    var lastCleanResult: CleanResult?
    var fullDiskAccess: FullDiskAccessState = .unknown
    var helperState: HelperState = .unavailableInThisBuild
    /// Set when the app sends the user to System Settings, so coming back re-checks and rescans once, not on
    /// every activation — a scan measures sizes, it is not free.
    var returningFromSettings = false

    /// Both checks are cheap and read-only: one `open(2)` of H15's indicator, and `SMAppService`'s status.
    /// Nothing here connects to the helper.
    func refreshPermissions() {
        fullDiskAccess = FullDiskAccessProbe().state()
        helperState = LiveHelper().state()
    }

    /// The most an app can do for Full Disk Access (ADR-0007): open the exact pane.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: FullDiskAccessProbe.settingsURL) else { return }
        returningFromSettings = true
        NSWorkspace.shared.open(url)
    }

    func appDidBecomeActive() async {
        guard returningFromSettings else { return }
        returningFromSettings = false
        await refresh()
    }

    /// Does not clear `lastError`: the alert clears it when dismissed, and `perform(_:)` reports an outcome and
    /// then asks for a rescan, which would otherwise erase the error before it was seen.
    func refresh() async {
        guard scanGate.requestScan() else { return }
        repeat {
            refreshPermissions()
            let (report, findings, checks, plan, journal) = await Task.detached(priority: .userInitiated) {
                () -> (ScanReport, [Finding], [VaultVolumeCheck], CleanPlan, [JournalEntry]) in
                // No capability detection: it runs `xcodebuild` and `simctl` from every bundle that calls itself
                // Xcode in /Applications or ~/Applications, inside the app's grant. Nothing in the app reads it.
                let report = XCodeVaultCore.Scanner(detectXcodeCapabilities: false).scan()
                let doctor = Doctor()
                let findings = doctor.diagnoseAll(report: report)
                let checks = (try? VaultVerifier().checkAll()) ?? []
                let plan = CleanPlanner().plan(report: report)
                let journal = (try? Journal().entries()) ?? []
                return (report, findings, checks, plan, journal)
            }.value
            self.report = report; self.findings = findings; self.vaultChecks = checks; self.cleanPlan = plan
            self.journal = journal.suffix(100).reversed()
        } while scanGate.scanEnded()
    }

    // MARK: - Root actions through the privileged helper (deliverable 4 of the 2026-09-27 permissions plan)

    /// A root action waiting on the helper's approval: set when the user chose one and the helper still needs
    /// approving; `showsHelperSheet` presents the one-sentence explanation with **Allow**.
    var pendingPrivilegedAction: PrivilegedAction?
    var showsHelperSheet = false
    /// Non-nil while waiting for the user to approve the helper in System Settings.
    var helperProgress: String?
    var lastPrivilegedResult: String?
    private var approvalTask: Task<Void, Never>?

    /// Every button that runs a root action comes through here and decides by `helperState.actionControl`, the
    /// tested function, never on its own.
    func request(_ action: PrivilegedAction) {
        switch helperState.actionControl {
        case .run:
            Task { await perform(action) }
        case .requestHelper:
            pendingPrivilegedAction = action
            showsHelperSheet = true
        case .notAvailableInThisBuild:
            return  // no button is shown in this state (ADR-0007)
        }
    }

    /// **Allow** in the sheet (with the action) and **Install…** in Permissions (without one).
    ///
    /// One wait at a time: a second request replaces the running wait instead of adding one, which would run its
    /// own action whenever the helper came up (migration-safety and helper-security reviews of deliverable 4).
    func installHelper(then action: PrivilegedAction?) {
        approvalTask?.cancel()
        showsHelperSheet = false
        pendingPrivilegedAction = nil
        helperProgress = "Waiting for you to approve XCodeVault in System Settings ▸ General ▸ Login Items & Extensions…"
        approvalTask = Task {
            let outcome = await HelperApprovalFlow(helper: LiveHelper()).run()
            // Cancelled by Stop or by a newer request: this wait no longer owns the progress text, or the action.
            guard !Task.isCancelled else { return }
            helperProgress = nil
            approvalTask = nil
            refreshPermissions()
            switch outcome {
            case .enabled:
                if let action { await perform(action) }
            case .notAvailableInThisBuild:
                lastError = HelperState.unavailableInThisBuild.why
            case .timedOut:
                lastError = "macOS has not approved the helper yet. Approve it in System Settings ▸ General ▸ Login Items & Extensions, then try again."
            case .cancelled:
                break
            case .failed(let why):
                lastError = why
            }
        }
    }

    /// The cancelled wait returns without touching anything, so the state it would have cleared is cleared here.
    func stopWaitingForApproval() {
        approvalTask?.cancel()
        approvalTask = nil
        helperProgress = nil
        refreshPermissions()
    }

    func perform(_ action: PrivilegedAction) async {
        switch await PrivilegedActionRunner(helper: LiveHelper()).run(action) {
        case .done(let reply): lastPrivilegedResult = [reply.message, action.afterSuccess].compactMap { $0 }.joined(separator: "\n\n")
        case .refused(let why), .failed(let why): lastError = why
        }
        await refresh()
    }

    func uninstallHelper() async {
        do { try await LiveHelper().unregister() } catch { lastError = "\(error)" }
        refreshPermissions()
    }

    func applyClean(actions: [CleanAction], useTrash: Bool) async {
        guard let plan = cleanPlan else { return }
        let selected = CleanPlan(actions: actions, skipped: plan.skipped, warnings: plan.warnings)
        do {
            let result = try await Task.detached { try CleanExecutor(useTrash: useTrash).execute(selected) }.value
            lastCleanResult = result
            await refresh()
        } catch { lastError = "\(error)" }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview", storage = "Storage", doctor = "Doctor", clean = "Clean", volumes = "Volumes", runtimes = "Runtimes",
        journal = "Journal", permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "internaldrive";
        case .storage: "chart.pie";
        case .doctor: "stethoscope";
        case .clean: "trash"
        case .volumes: "externaldrive";
        case .runtimes: "iphone";
        case .journal: "list.bullet.rectangle"
        case .permissions: "lock.shield"
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
                    case .overview:
                        OverviewView(
                            report: r, findings: model.findings, fullDiskAccess: model.fullDiskAccess,
                            openSettings: { model.openFullDiskAccessSettings() })
                    case .storage: StorageView(report: r)
                    case .doctor: DoctorView(model: model)
                    case .clean: CleanView(model: model)
                    case .volumes: VolumesView(report: r, checks: model.vaultChecks)
                    case .runtimes: RuntimesView(report: r)
                    case .journal: JournalView(entries: model.journal)
                    case .permissions: PermissionsView(model: model)
                    }
                } else if section == .permissions {
                    PermissionsView(model: model)  // needs no scan
                } else {
                    ContentUnavailableView(
                        "Scanning…", systemImage: "magnifyingglass",
                        description: Text("Discovering Xcodes, runtimes, volumes and measuring storage. Nothing is changed."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }.disabled(model.isScanning)
                }
                if model.isScanning { ToolbarItem { ProgressView().controlSize(.small) } }
            }
            .navigationTitle(section.rawValue)
        }
        .alert("Error", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {
                // Dismissing is the whole action: SwiftUI clears the binding that presents this
                // alert, which the `set:` closure above turns into `lastError = nil`.
            }
        } message: {
            Text(model.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.appDidBecomeActive() }
        }
        .sheet(isPresented: $model.showsHelperSheet) { HelperRequestSheet(model: model) }
        .overlay(alignment: .top) {
            if let progress = model.helperProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress)
                    Button("Stop waiting") { model.stopWaitingForApproval() }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .alert("Done", isPresented: Binding(get: { model.lastPrivilegedResult != nil }, set: { if !$0 { model.lastPrivilegedResult = nil } })) {
            Button("OK") {
                // Dismissing is the whole action, as with the error alert above.
            }
        } message: {
            Text(model.lastPrivilegedResult ?? "")
        }
    }
}

struct OverviewView: View {
    let report: ScanReport; let findings: [Finding]
    let fullDiskAccess: FullDiskAccessState
    let openSettings: @MainActor () -> Void
    var body: some View {
        let s = report.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "macOS \(report.host.macOSVersion) · \(report.host.architecture) · \(ByteCount.format(report.host.dataVolumeFreeBytes)) free of \(ByteCount.format(report.host.dataVolumeTotalBytes)) internal"
                ).font(.headline)
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
                if PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: s.privacyRefusalCount, state: fullDiskAccess) {
                    GroupBox {
                        HStack {
                            Label("Some folders could not be read", systemImage: "lock")
                            Spacer()
                            Button("Open Settings", action: openSettings)
                        }
                        Text(PrivilegeRequirement.appFullDiskAccess.why).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !report.warnings.isEmpty {
                    GroupBox("Before you act") {
                        VStack(alignment: .leading) {
                            ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                    }
                }
                let critical = findings.filter { $0.severity >= .error }
                if !critical.isEmpty {
                    GroupBox("Doctor: \(critical.count) issue(s) need attention") {
                        VStack(alignment: .leading) { ForEach(critical) { Text("\($0.severity.rawValue.uppercased()): \($0.title)") } }
                    }
                }
                Text(
                    "Every strategy marked (experimental) has not met the Definition of Done for your macOS/Xcode combination. Nothing in this app deletes non-regenerable data automatically."
                ).font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
    }
    func row(_ label: String, _ bytes: UInt64, _ note: String?) -> some View {
        GridRow {
            Text(label); Text(ByteCount.format(bytes)).monospacedDigit().bold(); Text(note ?? "").foregroundStyle(.secondary).font(.caption)
        }
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
            TableColumn("Strategy") { it in
                let c = report.category(for: it); Text((c?.recommendedStrategy.rawValue ?? "") + ((c?.isExperimental ?? false) ? " (experimental)" : ""))
            }
            TableColumn("Path") { it in
                Text(
                    it.path + (it.isSymlink ? "  → SYMLINK" : "") + (it.isMountPoint ? "  [mount point]" : "")
                        + (it.mountStateUndetermined ? "  [mount state unreadable]" : "")
                ).font(.system(.body, design: .monospaced))
            }
        }
    }
}

struct DoctorView: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.findings.isEmpty {
            ContentUnavailableView("No findings", systemImage: "checkmark.seal")
        } else {
            List(model.findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(f.severity.rawValue.uppercased()).font(.caption).bold().foregroundStyle(
                            f.severity >= .error ? .red : (f.severity == .warning ? .orange : .secondary));
                        Text(f.title).bold()
                    }
                    Text(f.detail).font(.callout)
                    if let p = f.path { Text(p).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    if let r = f.remediation { Text("→ " + r).font(.callout) }
                    // The finding carries the action; the button never re-derives it (carried note 2).
                    if let action = f.action {
                        PrivilegedActionControlView(action: action, state: model.helperState) { model.request(action) }
                    }
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
    @State private var useTrash = true
    /// The root row whose own button was pressed, waiting on its destructive confirmation.
    @State private var confirmPrivileged: CleanAction?

    /// The rows that will actually be deleted: selected, and not root-owned. Rows needing root are
    /// listed and selectable but never acted on by **Delete selected…** (`CleanAction.privilegeRequirement`
    /// says what they lack); the dyld cache has its own button, through the privileged helper.
    ///
    /// This is a single definition on purpose. The confirmation dialog used to title itself with
    /// `selection.count` while the delete acted on this filtered set, so selecting one root-owned
    /// row alongside two ordinary ones asked "Delete 3 item(s) permanently?" and deleted two. The
    /// count in a destructive confirmation is the last thing a user reads before agreeing to it.
    private func deletable(in plan: CleanPlan) -> [CleanAction] {
        plan.actions.filter { selection.contains($0.id) && !$0.requiresRoot }
    }

    var body: some View {
        if let plan = model.cleanPlan {
            VStack(alignment: .leading) {
                Table(plan.actions, selection: $selection) {
                    TableColumn("Size") { Text(ByteCount.format($0.bytes)).monospacedDigit() }.width(90)
                    TableColumn("Category") { Text($0.categoryName + ($0.isExperimental ? " (experimental)" : "")) }
                    TableColumn("Path") { Text($0.path).font(.system(.body, design: .monospaced)) }
                    TableColumn("Needs") { Text($0.privilegeRequirement?.label ?? "") }
                }
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                ForEach(plan.skipped, id: \.self) { Text("skipped: " + $0).font(.caption).foregroundStyle(.secondary) }
                let privileged = plan.actions.filter { $0.privilegedAction != nil }
                if !privileged.isEmpty {
                    GroupBox("Needs the privileged helper") {
                        ForEach(privileged) { a in
                            HStack {
                                Text("\(a.categoryName) (experimental) — \(ByteCount.format(a.bytes))")
                                Spacer()
                                if let action = a.privilegedAction {
                                    PrivilegedActionControlView(action: action, state: model.helperState) { confirmPrivileged = a }
                                }
                            }
                        }
                    }
                }
                HStack {
                    let chosen = deletable(in: plan)
                    Text("\(chosen.count) selected · \(ByteCount.format(chosen.reduce(0) { $0 + $1.bytes }))")
                    // The CLI has --trash; without this the GUI was strictly more destructive than
                    // the CLI with no way to say so, because CleanExecutor() defaults to useTrash: false.
                    Toggle("Move to Trash instead of deleting (space is freed only when the Trash is emptied)", isOn: $useTrash)
                    Spacer()
                    Button("Delete selected…") { confirm = true }.disabled(chosen.isEmpty)
                }.padding()
            }
            .confirmationDialog(
                useTrash
                    ? "Move \(deletable(in: plan).count) item(s) to the Trash?"
                    : "Delete \(deletable(in: plan).count) item(s) permanently?",
                isPresented: $confirm
            ) {
                Button(useTrash ? "Move to Trash" : "Delete", role: .destructive) {
                    Task {
                        await model.applyClean(actions: deletable(in: plan), useTrash: useTrash)
                        selection = []
                    }
                }
            } message: {
                Text(
                    "Only regenerable data is listed here. Xcode will rebuild it on demand. Non-regenerable data (Archives) never appears in this list. Deletions are journaled."
                )
            }
            .confirmationDialog(
                confirmPrivileged?.privilegedAction?.title ?? "",
                isPresented: Binding(get: { confirmPrivileged != nil }, set: { if !$0 { confirmPrivileged = nil } }),
                presenting: confirmPrivileged
            ) { a in
                Button("Empty \(ByteCount.format(a.bytes))", role: .destructive) {
                    if let action = a.privilegedAction { model.request(action) }
                }
            } message: { _ in
                Text(
                    "Experimental. It is deleted, not moved to the Trash. Simulators run without a shared cache until something rebuilds it, and what rebuilds a deleted cache is not identified (H14). Refused while Xcode, a simulator, simctl, xcodebuild or the cache builder runs."
                )
            }
        } else {
            ProgressView()
        }
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
                        HStack {
                            Text(v.volumeName).bold(); Text(v.filesystemPersonality); Text(v.busProtocol); Text(v.isInternal ? "internal" : "external");
                            Spacer(); Text("free \(ByteCount.format(v.freeBytes))").monospacedDigit()
                        }
                        Text(v.isBootVolume ? "boot volume" : q.verdict.rawValue).font(.caption).foregroundStyle(.secondary)
                        ForEach(q.blockers, id: \.self) { Text("✗ " + $0).font(.caption).foregroundStyle(.red) }
                        ForEach(q.warnings, id: \.self) { Text("! " + $0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section("Vault volumes (identified by UUID + sentinel)") {
                if checks.isEmpty { Text("None registered. Use `xcodevaultctl vault init /Volumes/<name>`.").foregroundStyle(.secondary) }
                ForEach(checks, id: \.volume.volumeUUID) { c in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(c.state.rawValue.uppercased()).bold().foregroundStyle(c.isUsable ? .green : .red); Text(c.volume.volumeName)
                        }; Text(c.detail).font(.caption)
                    }
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
        if entries.isEmpty {
            ContentUnavailableView(
                "Journal is empty", systemImage: "list.bullet.rectangle", description: Text("Every change XCodeVault makes is recorded here."))
        } else {
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

/// Spec §3: two rows, each with a status, one sentence of why, and one control. The texts come from
/// `PermissionsReport`, the same the CLI prints; this view decides nothing.
struct PermissionsView: View {
    @Bindable var model: AppModel
    @State private var confirmUninstall = false
    var body: some View {
        let report = PermissionsReport(fullDiskAccess: model.fullDiskAccess, helper: model.helperState)
        Form {
            Section("Full Disk Access") {
                LabeledContent("Status", value: report.fullDiskAccess.state.displayName)
                Text(report.fullDiskAccess.why).font(.callout)
                if model.fullDiskAccess.offersOpenSettings {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                }
            }
            Section("Privileged helper") {
                LabeledContent("Status", value: report.helper.state.displayName)
                Text(report.helper.why).font(.callout)
                switch model.helperState.rowButton {
                case .install: Button("Install…") { model.installHelper(then: nil) }
                case .uninstall: Button("Uninstall…") { confirmUninstall = true }
                case .none: Text(report.helper.nextStep).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("XCodeVault never runs a shell and never asks for your password itself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { model.refreshPermissions() }
        .confirmationDialog("Uninstall the privileged helper?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallHelper() } }
        } message: {
            Text("Actions that need root are unavailable until you install it again.")
        }
    }
}

/// What stands next to a root action. `HelperState.actionControl` decides; this only renders it, and never
/// renders a button for a build that cannot reach the helper.
struct PrivilegedActionControlView: View {
    let action: PrivilegedAction
    let state: HelperState
    let perform: @MainActor () -> Void
    var body: some View {
        switch state.actionControl {
        case .run: Button(action.title, action: perform)
        case .requestHelper: Button(action.title + "…", action: perform)
        case .notAvailableInThisBuild: Text("Not available in this build.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Spec §3: one sentence of why, and **Allow**.
struct HelperRequestSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.pendingPrivilegedAction?.title ?? "Install the privileged helper").font(.headline)
            Text(model.pendingPrivilegedAction?.requirement.why ?? PrivilegeRequirement.helper.why)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.showsHelperSheet = false
                    model.pendingPrivilegedAction = nil
                }
                Button("Allow") { model.installHelper(then: model.pendingPrivilegedAction) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
