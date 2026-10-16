import AppKit
import Combine
import SwiftUI
import XCodeVaultCore

/// The GUI is a projection of XCodeVaultCore: every number and action here comes from the same
/// Scanner / Doctor / CleanPlanner / VaultVerifier the CLI uses (ADR-0003).
@main
struct XCodeVaultApp: App {
    /// Owns the model, so the quit guard can ask it whether an operation runs (R3), and so an operation outlives its
    /// window being closed.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

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
                Button(L10n.tr("app.action.rescan")) { Task { await model.refresh() } }.keyboardShortcut("r").disabled(model.isOperationRunning)
            }
        }
    }
}

/// The quit guard (R3 §9): while an operation runs, quitting asks first. Closing the window does not interrupt it — the
/// model lives here, not in the window — so only quitting is guarded.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// The decision is `AppModel.quitChoice` (review M1, `OperationKind.canBeStopped`): copy, verify, remove, export and
    /// offload only keep running; a runtime deletion from Delete or a folder change can be stopped — its command terminated
    /// and waited for — before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("app.quit.title")
        // The safe choice is the default (HIG): Return keeps the operation running.
        alert.addButton(withTitle: L10n.tr("app.quit.keepRunning"))
        switch model.quitChoice {
        case .quitNow:
            return .terminateNow
        case .keepRunningOnly(let reason):
            switch reason {
            case .migration: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.migration")
            case .export: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.export")
            case .offload: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.offload")
            }
            alert.runModal()
            return .terminateCancel
        case .stopThenQuit:
            alert.informativeText = L10n.tr("app.quit.message")
            alert.addButton(withTitle: L10n.tr("app.quit.stopAndQuit")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            Task { @MainActor in
                let stopped = await model.stopOperationForQuit()
                sender.reply(toApplicationShouldTerminate: stopped)
                guard !stopped else { return }
                // Never quit with a command still alive: say so, and stay.
                let failed = NSAlert()
                failed.alertStyle = .critical
                failed.messageText = L10n.tr("app.quit.couldNotStop.title")
                failed.informativeText = L10n.tr("app.quit.couldNotStop.message")
                failed.runModal()
            }
            return .terminateLater
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
    /// Every scan starts through this: never two at once, and one more after the running one when a scan was
    /// asked for meanwhile (`ScanGate`, in Core and tested; carried note 7 of the 2026-09-27 permissions plan).
    private var scanGate = ScanGate()
    var isScanning: Bool { scanGate.isScanning }
    var lastError: String?
    var lastCleanResult: CleanResult?
    var fullDiskAccess: FullDiskAccessState = .unknown
    var helperState: HelperState = .unavailableInThisBuild
    /// Set when the app sends the user to System Settings, so coming back can rescan once if Full Disk Access was
    /// granted there, not on every activation — a scan measures sizes, it is not free.
    var returningFromSettings = false

    /// Both checks are cheap and read-only: one `open(2)` of H15's indicator, and `SMAppService`'s status.
    /// Nothing here connects to the helper.
    func refreshPermissions() {
        fullDiskAccess = environment.fullDiskAccess()
        helperState = environment.helper.state()
        updateAccessBanner()
    }

    /// The most an app can do for Full Disk Access (ADR-0007): put itself in the pane's list, then open the exact pane.
    /// The attempt comes first so the list should already show the app when the pane opens (R4, `FullDiskAccessRegistration`,
    /// unverified: H16); the user turns its switch on, or adds the app with + if it is not there.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: FullDiskAccessProbe.settingsURL) else { return }
        returningFromSettings = true
        environment.registerForFullDiskAccess()
        environment.open(url)
    }

    /// Every activation re-checks the permissions, so the Access row, the banner and the Overview follow what the user did
    /// in System Settings. A rescan follows only when Full Disk Access became granted, and only after a scan or a trip to
    /// the pane (`AccessChecklist.rescansOnActivation`): the launch's own scan is not doubled, and coming back without
    /// granting it scans nothing.
    func appDidBecomeActive() async {
        let before = fullDiskAccess
        let returning = returningFromSettings
        returningFromSettings = false
        refreshPermissions()
        guard
            AccessChecklist.rescansOnActivation(
                // A scan in flight counts as one: it ran without the grant, and `ScanGate` queues the follow-up (review M9).
                before: before, after: fullDiskAccess, hasScanned: report != nil || isScanning, returningFromSettings: returning)
        else { return }
        await refresh()
    }

    /// Does not clear `lastError`: the alert clears it when dismissed, and `perform(_:)` reports an outcome and
    /// then asks for a rescan, which would otherwise erase the error before it was seen.
    func refresh() async {
        // No scan while an operation runs (review M3): it would walk the trees a copy is writing, on the same disk, and
        // read a half-done journal. Every operation rescans when it ends.
        guard !isOperationRunning else { return }
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
            // One row per operation (R4), the newest 100; merged before the cut, so no operation loses its start. The
            // records themselves are not kept: the interrupted banner (R3) takes what it needs from them here. An operation
            // the Run sheet is running is in progress, not interrupted.
            let running = runningJournalIDs
            self.historyRows = Array(JournalTimeline.rows(journal, running: running).prefix(Self.historyLimit))
            self.interruptedMigrations = Self.interruptedBanner(journal, running: running)
            // A kind the new rows no longer have cannot stay hidden: the menu would not offer it (R4 review M8).
            self.historyHiddenKinds.formIntersection(JournalTimeline.kinds(in: self.historyRows))
            // The bucket views first: the Delete view's access row reads their list.
            updateBucketViews()
            revalidateDetailState()
            updateAccessBanner()
            revalidateOperationAfterScan()
        } while scanGate.scanEnded()
    }

    // MARK: - Run… (R3; the methods are in AppModel+Operations.swift)

    /// The Run sheet, presented while non-nil. One at a time: there is one sheet, and **Run…** is refused while it runs.
    var operationSheet: OperationSheetState?
    /// The migrations the journal shows interrupted, with their recovery commands: the banner on Park, Run externally and
    /// History.
    var interruptedMigrations: [InterruptedMigration] = []
    /// Held while an operation runs, so idle sleep does not interrupt a copy (HIG review §4).
    var awakeActivity: (any NSObjectProtocol)?
    /// The running operation's full log, when the environment keeps one.
    var operationLogFile: OperationLogFile?
    /// The running operation's child processes, which **Stop and Quit** stops (review M1).
    var activeChildren: ChildProcesses?

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

    /// The sidebar's selection. The Overview's **Review** buttons set it through `review(_:)`. Every change — a sidebar
    /// click, **Review**, any other code — records the section left in `history`, so **Back** works like a browser's (R1).
    var section: SidebarSection {
        get { currentSection }
        set {
            history.moved(from: currentSection, to: newValue)
            currentSection = newValue
        }
    }
    private var currentSection: SidebarSection = .overview
    /// The sections left behind, newest last (`NavigationHistory`, in Core and tested).
    private(set) var history = NavigationHistory<SidebarSection>()

    /// Whether the toolbar shows **Back**.
    var canGoBack: Bool { history.canGoBack }

    /// **Back** (⌘[): the section shown before this one. Going back records nothing, so Back again goes further back.
    func goBack() {
        guard let previous = history.back() else { return }
        currentSection = previous
    }

    /// **Review** on an Overview card: that bucket's view. Keeping has no view, so it changes nothing.
    func review(_ bucket: SavingsBucket) {
        if let target = SidebarSection(reviewing: bucket) { section = target }
    }

    /// The Drives screen's rows (`DrivesList.make`): one row per drive, the boot volume group as one, a vault as a badge on
    /// its own volume's row, and a section only for the vaults that are not connected.
    func drivesList(_ report: ScanReport) -> DrivesList { DrivesList.make(volumes: report.volumes, checks: vaultChecks) }

    // MARK: - The Details charts (R2)

    /// The Storage chart's filter: the bucket whose rows the table shows, nil for all of them. Set by a click on a bar
    /// (`clickStorageBar`), cleared by the chip's × or **All** (`clearStorageFilter`).
    var storageBucketFilter: SavingsBucket?
    /// The Storage table's sort order; largest first until the user clicks a column header.
    var storageSortOrder = StorageTable.defaultSortOrder

    /// The Storage table's rows: filtered by `storageBucketFilter`, sorted by `storageSortOrder` (`StorageTable`).
    func storageRows(_ report: ScanReport) -> [StorageRow] {
        StorageTable.sorted(StorageTable.rows(report: report, bucket: storageBucketFilter), using: storageSortOrder)
    }

    /// The Storage chart's bars: every bucket with rows, whatever the filter, so the selected bar stays clickable.
    func storageBars(_ report: ScanReport) -> [StorageTable.BucketBar] { StorageTable.bucketBars(rows: StorageTable.rows(report: report)) }

    /// A click on the Storage chart at the bar `barID` (nil: outside every bar), as `StorageTable.filter(after:clicked:)`.
    func clickStorageBar(_ barID: String?) {
        storageBucketFilter = StorageTable.filter(after: storageBucketFilter, clicked: StorageTable.bucket(forBarID: barID))
    }

    func clearStorageFilter() { storageBucketFilter = nil }

    /// The bucket menu next to **All** (R2 review M5): the chart's filter for keyboard and VoiceOver users.
    func chooseStorageFilter(_ bucket: SavingsBucket?) { storageBucketFilter = bucket }

    /// The row selected in one of the Simulators tables, never one in each (`SimulatorSelection`): set by a click on the
    /// chart (`clickSimulatorBar`) or in a table (`selectRuntimeRow`, `selectDeviceRow`).
    private(set) var simulatorSelection = SimulatorSelection()
    /// Counts the chart clicks that selected a row: the page scrolls to the row only for these, never for a click in a
    /// table, which would move the table under the pointer (R2 review M8).
    private(set) var simulatorScrollRequests = 0

    /// A click in the runtimes table (R2 review I1): that row, and the devices table's selection cleared.
    func selectRuntimeRow(_ id: String?) { simulatorSelection = simulatorSelection.selecting(runtimeID: id) }

    /// A click in the devices table: that row, and the runtimes table's selection cleared.
    func selectDeviceRow(_ id: String?) { simulatorSelection = simulatorSelection.selecting(deviceID: id) }
    var runtimeSortOrder = SimulatorsTable.defaultRuntimeSortOrder
    var deviceSortOrder = SimulatorsTable.defaultDeviceSortOrder

    func simulatorRuntimes(_ report: ScanReport) -> [SimulatorRuntime] {
        SimulatorsTable.sorted(SimulatorsTable.runtimes(report: report), using: runtimeSortOrder)
    }

    func simulatorDevices(_ report: ScanReport) -> [SimulatorDeviceRow] {
        SimulatorsTable.sorted(SimulatorsTable.devices(report: report), using: deviceSortOrder)
    }

    /// A click on the Simulators chart at the bar `barID`: selects its row (`SimulatorSelection.selecting(barID:)`).
    /// Asks the page to scroll to the row when the click selected one.
    func clickSimulatorBar(_ barID: String?) {
        let next = simulatorSelection.selecting(barID: barID)
        guard next != simulatorSelection || barID != nil else { return }
        simulatorSelection = next
        if next.runtimeID != nil || next.deviceID != nil { simulatorScrollRequests += 1 }
    }

    /// After a scan (R2 review M6): a filter whose bucket has no bar any more is cleared, and so is a selected row that is
    /// no longer listed.
    private func revalidateDetailState() {
        guard let report else {
            storageBucketFilter = nil
            simulatorSelection = SimulatorSelection()
            return
        }
        storageBucketFilter = StorageTable.filter(storageBucketFilter, validIn: storageBars(report))
        let runtimeIDs = Set(report.runtimes.map(\.id)), deviceIDs = Set(report.devices.map(\.id))
        simulatorSelection = SimulatorSelection(
            runtimeID: simulatorSelection.runtimeID.flatMap { runtimeIDs.contains($0) ? $0 : nil },
            deviceID: simulatorSelection.deviceID.flatMap { deviceIDs.contains($0) ? $0 : nil })
    }

    /// Where the page scrolls after a selection: the table holding the selected row, and the row's place in it
    /// (`SimulatorsChart.rowAnchor`). Nil when nothing is selected or the row is not in its table.
    func simulatorScrollTarget(_ report: ScanReport) -> (table: SimulatorBar.Kind, anchor: Double)? {
        if let id = simulatorSelection.runtimeID {
            let rows = simulatorRuntimes(report)
            return SimulatorsChart.rowAnchor(index: rows.firstIndex { $0.id == id }, rowCount: rows.count).map { (.runtime, $0) }
        }
        if let id = simulatorSelection.deviceID {
            let rows = simulatorDevices(report)
            return SimulatorsChart.rowAnchor(index: rows.firstIndex { $0.id == id }, rowCount: rows.count).map { (.device, $0) }
        }
        return nil
    }

    /// Whether the Bucket menu next to **All** is enabled: only when the chart has bars to choose from (R2 review N1).
    func storageFilterMenuEnabled(_ report: ScanReport) -> Bool { !storageBars(report).isEmpty }

    // MARK: - Health and History (R4)

    /// Health's cards (`HealthCard.cards`): most severe first, then largest.
    var healthCards: [HealthCard] { HealthCard.cards(findings) }

    /// Health's summary line: a count per severity present, most severe first.
    var healthCounts: [(severity: Finding.Severity, count: Int)] { HealthCard.counts(findings) }

    /// How many operations History lists.
    static let historyLimit = 100
    /// The journal as operations, newest first (`JournalTimeline.rows`), planned once per scan.
    private(set) var historyRows: [JournalTimeline.Row] = []
    /// The kinds History's filter hides; empty shows every kind.
    private(set) var historyHiddenKinds: Set<JournalTimeline.Kind> = []

    /// The kinds the filter offers: those the listed operations have.
    var historyKinds: [JournalTimeline.Kind] { JournalTimeline.kinds(in: historyRows) }

    /// Whether `kind` is shown.
    func historyShows(_ kind: JournalTimeline.Kind) -> Bool { !historyHiddenKinds.contains(kind) }

    /// A kind's toggle in the filter: hidden becomes shown and shown becomes hidden.
    func toggleHistoryKind(_ kind: JournalTimeline.Kind) {
        if historyHiddenKinds.contains(kind) { historyHiddenKinds.remove(kind) } else { historyHiddenKinds.insert(kind) }
    }

    /// **Show all** in the filter.
    func showAllHistoryKinds() { historyHiddenKinds = [] }

    /// History's sections: the shown operations by the day they started (`JournalTimeline.sections`), as of `now`.
    /// The view formats the headers with the same `calendar` (`AppText.historyDay`), so the day grouped is the day shown.
    func historySections(now: Date = Date(), calendar: Calendar = .current) -> [JournalTimeline.DaySection] {
        JournalTimeline.sections(JournalTimeline.filter(historyRows, hiding: historyHiddenKinds), now: now, calendar: calendar)
    }

    /// A drive row's bar (`DiskBar.drive`); nil when the volume's size was not measured.
    func driveBar(_ row: DriveRow, report: ScanReport) -> DiskBar? { DiskBar.drive(row, report: report) }

    /// The Delete screen's notes panel (`DeleteNotes.make`); nil until there is a plan and a list.
    var deleteNotes: DeleteNotes? {
        guard let plan = cleanPlan, let list = deleteList else { return nil }
        return DeleteNotes.make(plan: plan, list: list)
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

    /// **Copy command**: exactly the row's command, never a variant of it. **Run…** (R3) runs the operation through Core
    /// instead, never this string.
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
