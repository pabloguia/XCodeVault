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
        // One window (R5, HIG review N3): one model, so `Window`, not a group that could open a second. Its minimum is the
        // one `ScreenFitTests` proves every screen fits; it opens larger.
        Window(AppText.productName, id: "main") {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    model.startObservingDrives()
                    await model.refresh()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Deliberately empty — an empty replacement is how AppKit's File > New item is
                // removed. XCodeVault has no document model, so "New" would have nothing to make.
            }
            // View ▸ Show/Hide Sidebar and the toolbar's commands, where Mac apps have them (HIG review N4).
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .sidebar) {
                Divider()
                Button(L10n.tr("app.action.rescan")) { Task { await model.refresh() } }.keyboardShortcut("r")
                    .disabled(model.isScanning || model.isOperationRunning)
                Divider()
                // ⌘1…⌘4 for the Save Space views, as Mail and Music number their sidebars.
                ForEach(Array(SidebarSection.saveSpace.enumerated()), id: \.offset) { index, section in
                    Button(section.title) { model.section = section }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
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
            case .clean: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.clean")
            case .diskPreparation: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.diskPreparation")
            case .vaultRegistration: alert.informativeText = L10n.tr("app.quit.keepRunningOnly.vaultRegistration")
            }
            alert.runModal()
            model.relaunchRequested = false
            return .terminateCancel
        case .stopThenQuit:
            alert.informativeText = L10n.tr("app.quit.message")
            alert.addButton(withTitle: L10n.tr("app.quit.stopAndQuit")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else {
                model.relaunchRequested = false
                return .terminateCancel
            }
            Task { @MainActor in
                let stopped = await model.stopOperationForQuit()
                sender.reply(toApplicationShouldTerminate: stopped)
                guard !stopped else { return }
                model.relaunchRequested = false
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

    /// **Relaunch XCodeVault** (R5 review I1): the new instance starts only here, once quitting was approved, so two
    /// instances never run side by side.
    func applicationWillTerminate(_ notification: Notification) {
        if model.relaunchRequested { model.environment.launchNewInstance() }
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
    /// The error alert's content (R5, HIG review N10): what failed as the title, why and what to do as the message.
    var lastError: AppError?
    var lastCleanResult: CleanResult?
    /// The last action's result, shown inline above the screen until the next action or its × (R5, HIG review N11),
    /// instead of a modal "Done" alert.
    var feedback: AppFeedback?
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
        openedFullDiskAccessSettings = true
        environment.registerForFullDiskAccess()
        environment.open(url)
        // The guide beside the pane (R5, the user's real-window feedback): where XCodeVault is in the list, and its icon
        // to drag in if it is not.
        if !showsAccessGuide {
            showsAccessGuide = true
            environment.showAccessGuide { [weak self] in self?.closeAccessGuide() }
        }
    }

    /// Whether the Full Disk Access guide panel is up: shown when the pane opens, closed by its Done or once the grant is seen.
    private(set) var showsAccessGuide = false

    /// The guide's **Done**, and the grant seen on coming back.
    func closeAccessGuide() {
        guard showsAccessGuide else { return }
        showsAccessGuide = false
        environment.closeAccessGuide()
    }

    /// Set once the user opened the Full Disk Access pane from the app; it stays set, unlike `returningFromSettings`,
    /// which one activation consumes. The hint next to the button shows only after it (R5, HIG review A2).
    private(set) var openedFullDiskAccessSettings = false

    /// Whether `row` offers **Relaunch XCodeVault** (`AccessChecklist.offersRelaunch`): never while something runs that
    /// the quit guard would keep (R5 review I1).
    func offersRelaunch(_ row: AccessChecklist.Row) -> Bool {
        AccessChecklist.offersRelaunch(row, openedSettings: openedFullDiskAccessSettings, busy: quitNeedsConfirmation)
    }

    /// Set by **Relaunch XCodeVault** once quitting needs no confirmation; the app delegate starts the new instance in
    /// `applicationWillTerminate`, after the quit was approved, and a cancelled quit clears it.
    var relaunchRequested = false

    /// **Relaunch XCodeVault** (R5 review I1, safety LOW-2): quits only when the quit guard would not ask — nothing runs —
    /// and the new instance starts after the quit was approved. While something runs it opens and quits nothing, and says
    /// why.
    func relaunch() {
        guard !quitNeedsConfirmation else {
            lastError = AppError(title: L10n.tr("app.error.relaunch.title"), message: L10n.tr("app.error.relaunch.message"))
            return
        }
        relaunchRequested = true
        environment.terminate()
    }

    /// Whether `row` shows its hint (`AccessChecklist.showsHint`).
    func showsAccessHint(_ row: AccessChecklist.Row) -> Bool { AccessChecklist.showsHint(row, openedSettings: openedFullDiskAccessSettings) }

    /// Every activation re-checks the permissions, so the Access row, the banner and the Overview follow what the user did
    /// in System Settings. A rescan follows only when Full Disk Access became granted, and only after a scan or a trip to
    /// the pane (`AccessChecklist.rescansOnActivation`): the launch's own scan is not doubled, and coming back without
    /// granting it scans nothing.
    func appDidBecomeActive() async {
        let before = fullDiskAccess
        let returning = returningFromSettings
        returningFromSettings = false
        refreshPermissions()
        if fullDiskAccess == .granted { closeAccessGuide() }
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
        await refreshDrives()
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

    // MARK: - Drives (R6; the methods are in AppModel+Drives.swift)

    /// The disks and mounted volumes as last read; nil before the first read or when they could not be read.
    var driveSnapshot: DriveSnapshot?
    /// The Run sheet put aside while **Prepare…** runs a drive preparation from its Destination picker; it comes back when
    /// the preparation sheet closes.
    var suspendedOperationSheet: OperationSheetState?
    /// The pending debounced refresh after a mount or unmount.
    var driveRefreshTask: Task<Void, Never>?
    /// Keeps the mount observation alive.
    var driveObservation: AnyObject?
    /// Minor 4: each drive read takes a number; a read that finishes after a newer one started is dropped.
    var driveReadGeneration = 0

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
        feedback = nil
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
            let title = L10n.tr("app.error.helper.title")
            switch outcome {
            case .enabled:
                if let action { await perform(action) }
            case .notAvailableInThisBuild:
                lastError = AppError(title: title, message: L10n.tr("app.error.helper.unavailable"))
            case .timedOut:
                lastError = AppError(title: title, message: L10n.tr("app.helper.error.timedOut"))
            case .cancelled:
                break
            case .failed(let why):
                lastError = AppError(title: title, message: why)
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

    /// **Open System Settings** in the helper sheet's waiting state: the Login Items & Extensions pane again, where the
    /// switch is (`PrivilegedHelper.openApprovalSettings`).
    func openHelperApprovalSettings() { environment.helper.openApprovalSettings() }

    /// The helper sheet is up while a root action waits for the user's choice (`showsHelperSheet`) and, after **Install
    /// Helper…**, while the approval is awaited (`helperProgress`): the wait is the sheet's second state, never a floating
    /// overlay (R5, HIG review N12).
    var helperSheetIsPresented: Bool { showsHelperSheet || helperProgress != nil }

    /// The sheet closed by **Cancel**, **Stop Waiting** or Escape: no action stays pending, and a wait stops.
    func dismissHelperSheet() {
        showsHelperSheet = false
        pendingPrivilegedAction = nil
        if helperProgress != nil { stopWaitingForApproval() }
    }

    func perform(_ action: PrivilegedAction) async {
        feedback = nil
        switch await environment.runner(environment.helper).run(action) {
        case .done(let reply):
            lastPrivilegedResult = [reply.message, action.afterSuccess(in: L10n.locale)].compactMap { $0 }.joined(separator: "\n\n")
            // A step left to the user (the vault folder's `vault init`) makes it a notice, not a plain success.
            let next = action.afterSuccess(in: L10n.locale)
            feedback = AppFeedback(
                kind: next == nil ? .success : .notice, title: AppText.privilegedDone(action), detail: [reply.message, next].compactMap { $0 })
        case .refused(let why), .failed(let why):
            lastError = AppError(title: AppText.privilegedFailed(action), message: why)
        }
        await refresh()
    }

    func uninstallHelper() async {
        do { try await environment.helper.unregister() } catch { lastError = AppError(title: L10n.tr("app.error.uninstall.title"), error: error) }
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

    /// Whether **Back** is enabled; it is always shown, disabled when there is nowhere to go (R5, HIG review N1).
    var canGoBack: Bool { history.canGoBack }
    /// Whether **Forward** is enabled.
    var canGoForward: Bool { history.canGoForward }

    /// **Back** (⌘[): the section shown before this one. Going back records nothing, so Back again goes further back;
    /// the section left is kept for **Forward**.
    func goBack() {
        guard let previous = history.back(from: currentSection) else { return }
        currentSection = previous
    }

    /// **Forward** (⌘]): the section **Back** left. A new move forgets it, as in a browser.
    func goForward() {
        guard let next = history.forward(from: currentSection) else { return }
        currentSection = next
    }

    /// The window's subtitle (R5, HIG review N2): the scan in progress, else the Mac and its internal disk. Quiet, on every
    /// screen, instead of a headline on the Overview.
    var windowSubtitle: String {
        if isScanning { return L10n.tr("app.scanning.title") }
        guard let host = report?.host else { return "" }
        return L10n.tr(
            "app.overview.host", host.macOSVersion, host.architecture, ByteCount.format(host.dataVolumeFreeBytes), ByteCount.format(host.dataVolumeTotalBytes))
    }

    /// **Review** on an Overview card: that bucket's view. Keeping has no view, so it changes nothing.
    func review(_ bucket: SavingsBucket) {
        if let target = SidebarSection(reviewing: bucket) { section = target }
    }

    /// The Drives screen's rows (`DrivesList.make`): one row per drive, the boot volume group as one, a vault as a badge on
    /// its own volume's row, and a section only for the vaults that are not connected.
    func drivesList(_ report: ScanReport) -> DrivesList { DrivesList.make(volumes: report.volumes, checks: vaultChecks) }

    // MARK: - The Details charts (R2; one filter model, search and selection since R5)

    /// The Storage filter: the buckets whose rows the table shows, every bucket when empty (R5: several at once). A bar
    /// click shows only its bucket and ⌘-click adds or removes it (`clickStorageBar`); a legend chip toggles its bucket
    /// (`toggleStorageBucket`); **Show All** clears it and the search (`clearStorageFilter`).
    var storageBucketFilter: Set<SavingsBucket> = []
    /// The Storage search: a category name or a path (`StorageTable.matches`).
    var storageQuery = ""
    /// The Storage table's selection, by row id: Show in Finder and Copy Path act on it.
    var storageSelection = Set<String>()
    /// The Storage table's sort order; largest first until the user clicks a column header.
    var storageSortOrder = StorageTable.defaultSortOrder

    /// The Storage table's rows: filtered by the buckets and the search, sorted by `storageSortOrder` (`StorageTable`).
    func storageRows(_ report: ScanReport) -> [StorageRow] {
        StorageTable.sorted(StorageTable.rows(report: report, buckets: storageBucketFilter, query: storageQuery), using: storageSortOrder)
    }

    /// The Storage chart's bars: every bucket with rows, whatever the filter, so every bar stays clickable.
    func storageBars(_ report: ScanReport) -> [StorageTable.BucketBar] { StorageTable.bucketBars(rows: StorageTable.rows(report: report)) }

    /// A click on the Storage chart at the bar `barID` (nil: outside every bar); `extending` when ⌘ was held
    /// (`StorageTable.filter(after:clicked:extending:)`).
    func clickStorageBar(_ barID: String?, extending: Bool = false) {
        storageBucketFilter = StorageTable.filter(after: storageBucketFilter, clicked: StorageTable.bucket(forBarID: barID), extending: extending)
    }

    /// A legend chip: its bucket in or out of the filter.
    func toggleStorageBucket(_ bucket: SavingsBucket) { storageBucketFilter = StorageTable.toggled(storageBucketFilter, bucket) }

    /// **Show All** and the summary's ×: every bucket, no search.
    func clearStorageFilter() {
        storageBucketFilter = []
        storageQuery = ""
    }

    /// Whether the Storage table is narrowed: **Show All** and the summary show exactly then.
    var storageIsFiltered: Bool { StorageTable.isFiltered(buckets: storageBucketFilter, query: storageQuery) }

    /// The filter's buckets in the chart's order, for the summary "Filtering: Delete, Park".
    var storageFilterBuckets: [SavingsBucket] { DiskBar.bucketOrder.filter(storageBucketFilter.contains) }

    /// The paths of the selected Storage rows, for Show in Finder and Copy Path (a row's id is not its path).
    func storagePaths(_ ids: Set<String>, report: ScanReport) -> Set<String> {
        Set(StorageTable.rows(report: report).filter { ids.contains($0.id) }.map(\.item.path))
    }

    /// The Simulators table's selection, by row id (`SimulatorListRow.id`, the same as its bar's). Cleared by
    /// **Clear Selection**, by a click in an empty part of the table, or by a rescan that no longer lists the row.
    var simulatorSelection = Set<String>()
    /// The Simulators search: a name, a runtime or a path.
    var simulatorQuery = ""
    /// Counts the chart clicks that selected a row: the table scrolls to it only for these, never for a click in the
    /// table, which would move the table under the pointer (R2 review M8).
    private(set) var simulatorScrollRequests = 0
    var simulatorSortOrder = SimulatorsTable.defaultListSortOrder

    /// One section of the Simulators table: the runtimes or the devices, searched and sorted.
    func simulatorRows(_ report: ScanReport, kind: SimulatorBar.Kind) -> [SimulatorListRow] {
        SimulatorsTable.listRows(report: report, kind: kind, query: simulatorQuery, using: simulatorSortOrder)
    }

    /// A click on the Simulators chart at the bar `barID`: selects its row (`SimulatorsChart.selection`), and asks the
    /// table to scroll to it.
    func clickSimulatorBar(_ barID: String?) {
        guard barID != nil else { return }
        simulatorSelection = SimulatorsChart.selection(after: simulatorSelection, clicked: barID)
        // The row must be in the table to scroll to: a search that hides it is cleared.
        if let report, let id = simulatorSelection.first,
            !SimulatorBar.Kind.allCases.flatMap({ simulatorRows(report, kind: $0) }).contains(where: { $0.id == id })
        {
            simulatorQuery = ""
        }
        simulatorScrollRequests += 1
    }

    /// **Clear Selection** under the Simulators chart.
    func clearSimulatorSelection() { simulatorSelection = [] }

    /// The row the table scrolls to after a chart click: the selected one, when it is listed.
    func simulatorScrollTarget(_ report: ScanReport) -> String? {
        guard simulatorSelection.count == 1, let id = simulatorSelection.first else { return nil }
        return SimulatorBar.Kind.allCases.flatMap { simulatorRows(report, kind: $0) }.contains { $0.id == id } ? id : nil
    }

    /// After a scan (R2 review M6): buckets with no bar any more leave the filter, and rows no longer listed leave the
    /// selections.
    private func revalidateDetailState() {
        guard let report else {
            storageBucketFilter = []
            storageSelection = []
            simulatorSelection = []
            return
        }
        storageBucketFilter = StorageTable.filter(storageBucketFilter, validIn: storageBars(report))
        storageSelection.formIntersection(StorageTable.rows(report: report).map(\.id))
        let listed = SimulatorBar.Kind.allCases.flatMap { SimulatorsTable.listRows(report: report, kind: $0) }.map(\.id)
        simulatorSelection.formIntersection(listed)
    }

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

    /// **Show All** in the filter.
    func showAllHistoryKinds() { historyHiddenKinds = [] }

    /// **Copy Summary** on History's selection: each operation's summary, and how it ended, in the table's order.
    func copyHistorySummaries(_ ids: Set<String>) {
        let lines = historyRows.filter { ids.contains($0.id) }.map { [$0.summary, $0.endSummary].compactMap { $0 }.joined(separator: " — ") }
        guard !lines.isEmpty else { return }
        environment.copy(lines.joined(separator: "\n"))
    }

    /// The kinds menu's title says the filter's state (R5, HIG review HI3): "All Kinds", or how many are shown.
    var historyFilterTitle: String {
        let kinds = historyKinds
        let shown = kinds.filter(historyShows).count
        return shown == kinds.count ? L10n.tr("app.history.filter.allKinds") : L10n.tr("app.history.filter.someKinds", shown, kinds.count)
    }

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

    func applyClean(actions: [CleanAction], useTrash: Bool) async {
        // One clean at a time: a second one finishing first would clear `isCleaning` while this one still deletes, and the
        // quit guard and Relaunch would open in the middle of a clean (R5 re-review NEW-1).
        guard !isCleaning, let plan = cleanPlan else { return }
        feedback = nil
        let selected = CleanPlan(actions: actions, skipped: plan.skipped, warnings: plan.warnings)
        let clean = environment.clean
        // The quit guard keeps the app open while it runs (`quitChoice`), and Relaunch is not offered.
        isCleaning = true
        defer { isCleaning = false }
        do {
            let result = try await Task.detached { try clean(selected, useTrash) }.value
            lastCleanResult = result
            feedback = AppText.cleanFeedback(result, useTrash: useTrash)
            if let failure = AppText.cleanFailures(result) { lastError = failure }
            await refresh()
        } catch {
            lastError = AppError(title: useTrash ? L10n.tr("app.error.clean.trash.title") : L10n.tr("app.error.clean.delete.title"), error: error)
        }
    }

    /// Whether a Delete view clean runs: the quit guard offers only Keep Running (R5, safety review's pre-existing gap).
    private(set) var isCleaning = false

    /// What the Delete view's context menu and ⌘⌫ confirm (R5 safety LOW-3): the rows they act on when **Delete
    /// Selected…** would delete any of them (`DeleteList.deletable`), nil when it would delete none and no confirmation
    /// opens. The confirmation's count is still `deletable(selected:)` of the selection this returns.
    func deletionToConfirm(_ paths: Set<String>) -> Set<String>? {
        guard !isCleaning, let list = deleteList, !list.deletable(selected: paths).isEmpty else { return nil }
        return paths
    }

    /// The inline result's ×.
    func dismissFeedback() { feedback = nil }

    /// **Show in Finder** on a table's selection (R5, HIG review D1, ST3): the paths selected in Finder. Reads nothing.
    func showInFinder(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        environment.reveal(paths.sorted())
    }

    /// **Copy Path**: the selected paths, one per line, in path order.
    func copyPaths(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        environment.copy(paths.sorted().joined(separator: "\n"))
    }
}

/// An alert's content (R5, HIG review N10): the title says what failed, the message why and what to do. The raw text of
/// an error that has no description of its own is the message's last resort, never the title.
struct AppError: Equatable {
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// A thrown error under `title`: its description and recovery suggestion when it is a `LocalizedError`, else its text.
    init(title: String, error: any Error) {
        self.title = title
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = [description, localized.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
        } else {
            message = "\(error)"
        }
    }
}

/// An action's result shown inline (R5, HIG review N11): a symbol, one line, and its details under it.
struct AppFeedback: Equatable {
    enum Kind: Equatable {
        case success
        /// Done, with something the user should read (part of it failed, or a step is left).
        case notice
    }

    let kind: Kind
    let title: String
    var detail: [String] = []
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
        // Title case, in the app's own words (HIG review X5); `PrivilegedAction.title` stays the journal's record.
        switch state.actionControl {
        case .run: Button(AppText.privilegedButton(action), action: perform)
        case .requestHelper: Button(AppText.privilegedButton(action) + "…", action: perform)
        // What to do instead, never a bare "not available" (spec §6.3): the same guidance as the Access checklist.
        case .notAvailableInThisBuild:
            if showsGuidance {
                // One line; the manual route is its tooltip (HIG review X6).
                InlineCodeText(L10n.tr("app.access.helper.action.signedReleaseOrCLI")).font(.caption).foregroundStyle(.secondary)
                    .help(L10n.tr("app.access.helper.action.manualRoute"))
            }
        }
    }
}

/// Spec §3, with the HIG review's S1, S2 and N12 (R5): the request — what will happen, one sentence of why, **Cancel**
/// (Escape) and **Install Helper…** (Return) — and then, in the same sheet, the wait for the user's approval in System
/// Settings, with **Open System Settings** and **Stop Waiting** (Escape).
struct HelperRequestSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                if let progress = model.helperProgress { waiting(progress) } else { request }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
    }

    @ViewBuilder
    private var request: some View {
        Text(verbatim: L10n.tr("app.helper.sheet.installTitle")).font(.headline)
        if let action = model.pendingPrivilegedAction {
            Text(verbatim: action.title(in: L10n.locale)).font(.callout).foregroundStyle(.secondary)
        }
        Text(verbatim: AppText.requirementWhy(model.pendingPrivilegedAction?.requirement ?? PrivilegeRequirement.helper))
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(L10n.tr("app.action.cancel"), role: .cancel) { model.dismissHelperSheet() }.keyboardShortcut(.cancelAction)
            Button(L10n.tr("app.helper.sheet.allow")) { model.installHelper(then: model.pendingPrivilegedAction) }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func waiting(_ progress: String) -> some View {
        Text(verbatim: L10n.tr("app.helper.sheet.waitingTitle")).font(.headline)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: progress).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button(L10n.tr("app.helper.stopWaiting")) { model.dismissHelperSheet() }.keyboardShortcut(.cancelAction)
            Button(L10n.tr("app.helper.openSettings")) { model.openHelperApprovalSettings() }
        }
    }
}
