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

    /// Calls nothing outside the process: the checklist starts from the states below until `refreshPermissions()`.
    init(environment: AppEnvironment = .live) {
        self.environment = environment
        updateAccessBanner()
    }

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
        updateAccessBanner()
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
            // The bucket views first: the Delete view's access row reads their list.
            updateBucketViews()
            updateAccessBanner()
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

    /// **Allow** in the sheet (with the action) and the helper row's button in Access (without one).
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
    /// (`AccessChecklist.banner`, in Core and tested). Nil before the first scan. Stored, not computed: the plan rows it
    /// reads are re-planned only when the scan or the permissions change, never per redraw.
    private(set) var accessBanner: AccessChecklist.Row?
    /// The Access view's checklist (`AccessChecklist.rows`): one row per need. Before the first scan there is nothing
    /// measured to hold back, so the rows give the general reasons.
    private(set) var accessRows: [AccessChecklist.Row] = []
    /// The helper row above the Delete table (`AccessChecklist.deleteRow`): nil unless the list has a root-only row and the
    /// helper is not enabled.
    private(set) var deleteAccessRow: AccessChecklist.Row?

    /// Whether the Delete view's dyld control shows its "what to do instead" text: not when `deleteAccessRow` above the
    /// table already says it (`AccessChecklist.controlShowsGuidance`). The action and its confirmation are unchanged.
    var deleteControlShowsGuidance: Bool { AccessChecklist.controlShowsGuidance(helper: helperState, besides: deleteAccessRow) }

    /// Whether the Access view offers **Uninstall…** under `row` (`AccessChecklist.offersUninstall`).
    func offersUninstall(_ row: AccessChecklist.Row) -> Bool { AccessChecklist.offersUninstall(row, helper: helperState) }

    private func updateAccessBanner() {
        guard let report else {
            accessBanner = nil
            deleteAccessRow = nil
            accessRows = AccessChecklist.rows(fullDiskAccess: fullDiskAccess, helper: helperState, savings: SavingsSummary(), plan: [])
            return
        }
        let plan = SavingsPlanner.rows(report: report, bucket: .deleteAndRegenerate)
        let refusals = report.summary.privacyRefusalCount
        // The Delete list, when there is one, is the one source of the root-only bytes on every screen (final review M1).
        accessRows = AccessChecklist.rows(
            fullDiskAccess: fullDiskAccess, helper: helperState, savings: report.savings, plan: plan, privacyRefusalCount: refusals,
            deleteList: deleteList)
        accessBanner = AccessChecklist.banner(
            fullDiskAccess: fullDiskAccess, helper: helperState, savings: report.savings, plan: plan, privacyRefusalCount: refusals,
            deleteList: deleteList)
        deleteAccessRow = deleteList.flatMap { AccessChecklist.deleteRow(helper: helperState, list: $0) }
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

    // MARK: - The bucket views (S4 Task 4)

    /// Park's and Run externally's rows: `SavingsPlanner.rows` for the scan, in its order. Stored like `accessBanner`:
    /// planned once per scan, never per redraw.
    private(set) var planRows: [SavingsBucket: [SavingsPlanRow]] = [:]
    /// The Delete view's list: the clean plan by category, and the rows another tool deletes (`DeleteList.make`).
    private(set) var deleteList: DeleteList?
    /// Park's vault line.
    var vaultStatus: VaultStatus { VaultStatus.make(vaultChecks) }

    func rows(for bucket: SavingsBucket) -> [SavingsPlanRow] { planRows[bucket] ?? [] }

    private func updateBucketViews() {
        guard let report else {
            planRows = [:]
            deleteList = nil
            return
        }
        let buckets: [SavingsBucket] = [.parkExternally, .runFromExternal]
        planRows = Dictionary(uniqueKeysWithValues: buckets.map { ($0, SavingsPlanner.rows(report: report, bucket: $0)) })
        deleteList = cleanPlan.map { DeleteList.make(plan: $0, report: report) }
    }

    /// **Copy command**: exactly the row's command, never a variant of it. The app runs none of these (spec §6.4).
    func copyCommand(_ row: SavingsPlanRow) { environment.copy(row.command) }

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

/// What stands next to a root action. `HelperState.actionControl` decides; this only renders it, and never
/// renders a button for a build that cannot reach the helper.
struct PrivilegedActionControlView: View {
    let action: PrivilegedAction
    let state: HelperState
    /// False where an access row on the same screen already gives the guidance (`AccessChecklist.controlShowsGuidance`).
    var showsGuidance = true
    let perform: @MainActor () -> Void
    var body: some View {
        switch state.actionControl {
        case .run: Button(action.title(in: L10n.locale), action: perform)
        case .requestHelper: Button(action.title(in: L10n.locale) + "…", action: perform)
        // What to do instead, never a bare "not available" (spec §6.3): the same guidance as the Access checklist.
        case .notAvailableInThisBuild:
            if showsGuidance {
                InlineCodeText(L10n.tr("app.access.helper.action.signedReleaseOrCLI")).font(.caption).foregroundStyle(.secondary)
            }
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
