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
    ///
    /// The language is chosen once, before any view is built: the app's own localization as macOS resolved it
    /// (`CFBundleLocalizations` lists the five), then the user's preferences. The environment is empty on
    /// purpose: `XCODEVAULT_LANG` is the CLI's, and the app follows the system.
    init() {
        L10n.configure(override: nil, environment: [:], preferred: Bundle.main.preferredLocalizations + Locale.preferredLanguages)
        GrantedToolEnvironment.applyToThisProcess()
    }

    var body: some Scene {
        WindowGroup(AppText.productName) {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Deliberately empty — an empty replacement is how AppKit's File > New item is
                // removed. XCodeVault has no document model, so "New" would have nothing to make.
            }
            CommandMenu(L10n.tr("app.menu.scan")) {
                Button(L10n.tr("app.action.rescan")) { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

@MainActor @Observable
final class AppModel {
    /// A scan and what is derived from it, in the order `refresh()` stores them.
    typealias Survey = (ScanReport, [Finding], [VaultVolumeCheck], CleanPlan, [JournalEntry])

    /// Everything outside the process; `.live` in the app (`AppEnvironment`).
    let environment: AppEnvironment

    init(environment: AppEnvironment = .live) { self.environment = environment }

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
        fullDiskAccess = environment.fullDiskAccess()
        helperState = environment.helper.state()
    }

    /// The most an app can do for Full Disk Access (ADR-0007): open the exact pane.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: FullDiskAccessProbe.settingsURL) else { return }
        returningFromSettings = true
        environment.open(url)
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
        let survey = environment.survey  // nil in the app: the real scan below runs
        repeat {
            refreshPermissions()
            let (report, findings, checks, plan, journal) = await Task.detached(priority: .userInitiated) {
                () -> (ScanReport, [Finding], [VaultVolumeCheck], CleanPlan, [JournalEntry]) in
                if let survey { return survey() }
                // No capability detection: nothing in the app reads it, and it would run the selected Xcode's
                // `xcodebuild` and `simctl` inside the app's grant for no use (ADR-0009).
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
        helperProgress = L10n.tr("app.helper.progress.waiting")
        approvalTask = Task {
            let outcome = await environment.approvalFlow(environment.helper).run()
            // Cancelled by Stop or by a newer request: this wait no longer owns the progress text, or the action.
            guard !Task.isCancelled else { return }
            helperProgress = nil
            approvalTask = nil
            refreshPermissions()
            switch outcome {
            case .enabled:
                if let action { await perform(action) }
            case .notAvailableInThisBuild:
                lastError = HelperState.unavailableInThisBuild.why(in: L10n.locale)
            case .timedOut:
                lastError = L10n.tr("app.helper.error.timedOut")
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
        switch await environment.runner(environment.helper).run(action) {
        case .done(let reply): lastPrivilegedResult = [reply.message, action.afterSuccess(in: L10n.locale)].compactMap { $0 }.joined(separator: "\n\n")
        case .refused(let why), .failed(let why): lastError = why
        }
        await refresh()
    }

    func uninstallHelper() async {
        do { try await environment.helper.unregister() } catch { lastError = "\(error)" }
        refreshPermissions()
    }

    // MARK: - Navigation and the Overview (S4 Task 3)

    /// The sidebar's selection. The Overview's **Review** buttons set it through `review(_:)`.
    var section: SidebarSection = .overview

    /// **Review** on an Overview card: that bucket's view. Keeping has no view, so it changes nothing.
    func review(_ bucket: SavingsBucket) {
        if let target = SidebarSection(reviewing: bucket) { section = target }
    }

    /// The Overview's one access banner: the first `AccessChecklist` row that holds back something the scan measured
    /// (`AccessChecklist.banner`, in Core and tested). Nil before the first scan.
    var accessBanner: AccessChecklist.Row? {
        guard let report else { return nil }
        return AccessChecklist.banner(
            fullDiskAccess: fullDiskAccess, helper: helperState, savings: report.savings,
            plan: SavingsPlanner.rows(report: report, bucket: .deleteAndRegenerate), privacyRefusalCount: report.summary.privacyRefusalCount)
    }

    /// A checklist row's button: the existing flows only (ADR-0007) — the Settings pane, a re-check of the probe, the
    /// `SMAppService` approval. Guidance is text and does nothing.
    func handle(_ action: AccessChecklist.Action) {
        switch action {
        case .openFullDiskAccessSettings: openFullDiskAccessSettings()
        case .recheckFullDiskAccess: refreshPermissions()
        case .installHelper: installHelper(then: nil)
        case .guidanceOnly: break
        }
    }

    func applyClean(actions: [CleanAction], useTrash: Bool) async {
        guard let plan = cleanPlan else { return }
        let selected = CleanPlan(actions: actions, skipped: plan.skipped, warnings: plan.warnings)
        let clean = environment.clean
        do {
            let result = try await Task.detached { try clean(selected, useTrash) }.value
            lastCleanResult = result
            await refresh()
        } catch { lastError = "\(error)" }
    }
}

struct StorageView: View {
    let report: ScanReport
    var body: some View {
        let items = report.items.filter { $0.exists }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        Table(items) {
            // Category names and outcomes are the catalog's English: StorageCategory data, not app text (S4 Task 2).
            TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.allocatedBytes)).monospacedDigit() }.width(90)
            TableColumn(L10n.tr("app.column.category")) { Text(verbatim: report.category(for: $0)?.name ?? $0.categoryID) }
            TableColumn(L10n.tr("app.column.outcome")) { Text(verbatim: report.category(for: $0)?.outcomeLabel ?? "") }
            TableColumn(L10n.tr("app.column.strategy")) { it in
                let c = report.category(for: it)
                Text(verbatim: AppText.name(c?.recommendedStrategy.rawValue ?? "", experimental: c?.isExperimental ?? false))
            }
            TableColumn(L10n.tr("app.column.path")) { it in
                let marks =
                    (it.isSymlink ? "  " + L10n.tr("app.storage.symlink") : "") + (it.isMountPoint ? "  " + L10n.tr("app.storage.mountPoint") : "")
                    + (it.mountStateUndetermined ? "  " + L10n.tr("app.storage.mountStateUnreadable") : "")
                Text(verbatim: it.path + marks).font(.system(.body, design: .monospaced))
            }
        }
    }
}

struct DoctorView: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.findings.isEmpty {
            ContentUnavailableView(L10n.tr("app.doctor.empty"), systemImage: "checkmark.seal")
        } else {
            List(model.findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: AppText.severity(f.severity)).font(.caption).bold().foregroundStyle(
                            f.severity >= .error ? .red : (f.severity == .warning ? .orange : .secondary));
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
                    TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.bytes)).monospacedDigit() }.width(90)
                    TableColumn(L10n.tr("app.column.category")) { Text(verbatim: AppText.name($0.categoryName, experimental: $0.isExperimental)) }
                    TableColumn(L10n.tr("app.column.path")) { Text(verbatim: $0.path).font(.system(.body, design: .monospaced)) }
                    TableColumn(L10n.tr("app.column.needs")) { Text(verbatim: $0.privilegeRequirement?.label(in: L10n.locale) ?? "") }
                }
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                ForEach(plan.skipped, id: \.self) { Text.l10n(L10n.tr("app.clean.skipped", $0)).font(.caption).foregroundStyle(.secondary) }
                let privileged = plan.actions.filter { $0.privilegedAction != nil }
                if !privileged.isEmpty {
                    GroupBox(L10n.tr("app.clean.privileged.title")) {
                        ForEach(privileged) { a in
                            HStack {
                                Text(verbatim: AppText.name(a.categoryName, experimental: true) + " — " + ByteCount.format(a.bytes))
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
                    Text.l10n(L10n.plural("app.clean.selected", count: chosen.count, ByteCount.format(chosen.reduce(0) { $0 + $1.bytes })))
                    // The CLI has --trash; without this the GUI was strictly more destructive than
                    // the CLI with no way to say so, because CleanExecutor() defaults to useTrash: false.
                    Toggle(L10n.tr("app.clean.useTrash"), isOn: $useTrash)
                    Spacer()
                    Button(L10n.tr("app.clean.deleteSelected")) { confirm = true }.disabled(chosen.isEmpty)
                }.padding()
            }
            .confirmationDialog(
                useTrash
                    ? L10n.plural("app.clean.confirm.trash", count: deletable(in: plan).count)
                    : L10n.plural("app.clean.confirm.delete", count: deletable(in: plan).count),
                isPresented: $confirm
            ) {
                Button(useTrash ? L10n.tr("app.clean.action.moveToTrash") : L10n.tr("app.clean.action.delete"), role: .destructive) {
                    Task {
                        await model.applyClean(actions: deletable(in: plan), useTrash: useTrash)
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
}

struct VolumesView: View {
    let report: ScanReport; let checks: [VaultVolumeCheck]
    var body: some View {
        List {
            Section(L10n.tr("app.volumes.mounted")) {
                ForEach(report.volumes) { v in
                    let q = VolumeQualification.evaluate(v)
                    VStack(alignment: .leading) {
                        HStack {
                            Text(verbatim: v.volumeName).bold(); Text(verbatim: v.filesystemPersonality); Text(verbatim: v.busProtocol)
                            Text(verbatim: v.isInternal ? L10n.tr("app.volumes.internal") : L10n.tr("app.volumes.external"))
                            Spacer(); Text.l10n(L10n.tr("app.volumes.free", ByteCount.format(v.freeBytes))).monospacedDigit()
                        }
                        Text(verbatim: v.isBootVolume ? L10n.tr("app.volumes.bootVolume") : AppText.verdict(q.verdict)).font(.caption)
                            .foregroundStyle(.secondary)
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
                            Text(verbatim: AppText.vaultState(c.state)).bold().foregroundStyle(c.isUsable ? .green : .red); Text(verbatim: c.volume.volumeName)
                        }; Text(verbatim: c.detail).font(.caption)
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
            TableColumn(L10n.tr("app.column.platform")) { Text(verbatim: $0.platformName) }
            TableColumn(L10n.tr("app.column.version")) { Text(verbatim: ($0.version ?? "?") + " (" + ($0.build ?? "?") + ")") }
            TableColumn(L10n.tr("app.column.state")) { Text(verbatim: $0.state ?? "?") }
            TableColumn(L10n.tr("app.column.size")) { Text(verbatim: ByteCount.format($0.sizeBytes ?? 0)).monospacedDigit() }
            TableColumn(L10n.tr("app.column.mounted")) { Text(verbatim: $0.isMounted ? L10n.tr("app.value.yes") : L10n.tr("app.value.no")) }
            TableColumn(L10n.tr("app.column.image")) { Text(verbatim: $0.path ?? "").font(.system(.caption, design: .monospaced)) }
        }
    }
}

struct JournalView: View {
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

/// Spec §3: two rows, each with a status, one sentence of why, and one control. The texts come from the `perm.*`
/// keys `xcodevaultctl permissions` prints, in the app's language; this view decides nothing.
struct PermissionsView: View {
    @Bindable var model: AppModel
    @State private var confirmUninstall = false
    var body: some View {
        let locale = L10n.locale
        let access = model.fullDiskAccess, helper = model.helperState
        Form {
            Section(L10n.tr("perm.fda.title")) {
                LabeledContent(L10n.tr("app.permissions.status"), value: access.displayName(in: locale))
                Text(verbatim: access.why(in: locale)).font(.callout)
                if access.offersOpenSettings {
                    Button(L10n.tr("app.action.openSettings")) { model.openFullDiskAccessSettings() }
                }
            }
            Section(L10n.tr("perm.helper.title")) {
                LabeledContent(L10n.tr("app.permissions.status"), value: helper.displayName(in: locale))
                Text(verbatim: helper.why(in: locale)).font(.callout)
                switch helper.rowButton {
                case .install: Button(L10n.tr("app.permissions.install")) { model.installHelper(then: nil) }
                case .uninstall: Button(L10n.tr("app.permissions.uninstallEllipsis")) { confirmUninstall = true }
                case .none: Text(verbatim: helper.nextStep(in: locale)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Text.l10n(L10n.tr("app.permissions.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { model.refreshPermissions() }
        .confirmationDialog(L10n.tr("app.permissions.uninstall.confirm"), isPresented: $confirmUninstall) {
            Button(L10n.tr("app.permissions.uninstall"), role: .destructive) { Task { await model.uninstallHelper() } }
        } message: {
            Text.l10n(L10n.tr("app.permissions.uninstall.message"))
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
        case .run: Button(action.title(in: L10n.locale), action: perform)
        case .requestHelper: Button(action.title(in: L10n.locale) + "…", action: perform)
        // What to do instead, never a bare "not available" (spec §6.3): the same guidance as the Access checklist.
        case .notAvailableInThisBuild:
            Text.l10n(L10n.tr("app.access.helper.action.signedReleaseOrCLI")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Spec §3: one sentence of why, and **Allow**.
struct HelperRequestSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: model.pendingPrivilegedAction?.title(in: L10n.locale) ?? L10n.tr("app.helper.sheet.installTitle")).font(.headline)
            Text(verbatim: (model.pendingPrivilegedAction?.requirement ?? PrivilegeRequirement.helper).why(in: L10n.locale))
            HStack {
                Spacer()
                Button(L10n.tr("app.action.cancel")) {
                    model.showsHelperSheet = false
                    model.pendingPrivilegedAction = nil
                }
                Button(L10n.tr("app.helper.sheet.allow")) { model.installHelper(then: model.pendingPrivilegedAction) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
