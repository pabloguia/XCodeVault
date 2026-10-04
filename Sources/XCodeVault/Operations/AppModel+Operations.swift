import Foundation
import XCodeVaultCore

/// **Run…** (R3, ADR-0011): every decision the Run sheet shows is made here or in Core, and tested. The sheet renders it.
extension AppModel {
    // MARK: - Which rows, which defaults

    /// Whether a plan row gets **Run…** (`OperationKind.forRow`).
    func canRun(_ row: SavingsPlanRow) -> Bool { OperationKind.forRow(row) != nil }

    /// The vaults the sheet's picker offers: the registered ones that are usable now.
    var usableVaults: [VaultVolumeCheck] { vaultChecks.filter(\.isUsable) }

    /// The picker's default: the one usable vault when there is exactly one; otherwise the user chooses.
    var defaultVaultUUID: String? { usableVaults.count == 1 ? usableVaults.first?.volume.volumeUUID : nil }

    /// Where the folder panel opens: the usable vault's mount point when there is one.
    var folderPanelStart: String? { usableVaults.first?.currentMountPoint }

    /// What a plan row suggests for its `<dir>` (R7-A, the user's "faltou colocar a sugestão"): the command filled with
    /// the usable vault's standard folder (`VaultLayout`), or that there is no usable vault yet, so the row points to
    /// Drives. With several usable vaults, the first one's (the Run sheet's picker chooses among them).
    enum CommandSuggestion: Equatable {
        /// The row's command takes no `<dir>`.
        case none
        case filled(command: String, folder: String)
        case noVault
    }

    func commandSuggestion(_ row: SavingsPlanRow) -> CommandSuggestion {
        guard let purpose = row.folderPurpose else { return .none }
        guard let folder = usableVaults.lazy.compactMap({ VaultLayout.path(purpose, in: $0) }).first, let command = row.command(filling: folder)
        else { return .noVault }
        return .filled(command: command, folder: folder)
    }

    /// **Copy Command** on a plan row: the command filled with the vault's folder when there is one, else as listed.
    func copyCommand(_ row: SavingsPlanRow) {
        if case .filled(let command, _) = commandSuggestion(row) { environment.copy(command) } else { environment.copy(row.command) }
    }

    /// The runtimes the picker offers, largest first. No default: a runtime to delete is always chosen.
    var runtimesForPicker: [SimulatorRuntime] {
        (report?.runtimes ?? []).sorted { ($0.sizeBytes ?? 0, $1.identifier) > ($1.sizeBytes ?? 0, $0.identifier) }
    }

    // MARK: - Opening and reviewing

    /// **Run…** on a row: opens the sheet on its review step. Refused while an operation runs (one at a time).
    func openRun(_ row: SavingsPlanRow) {
        guard let kind = OperationKind.forRow(row), !isOperationRunning else { return }
        var inputs = OperationInputs()
        // R6: the destination starts at the only usable vault, and a folder at that vault's standard folder (`VaultLayout`).
        if kind.usesDestination, let uuid = defaultVaultUUID {
            inputs.vaultUUID = uuid
            if kind.needsFolder { Self.applyStandardFolder(kind, usableVaults.first { $0.volume.volumeUUID == uuid }, to: &inputs) }
        }
        operationSheet = OperationSheetState(row: row, kind: kind, inputs: inputs)
        Task { await previewOperation() }
    }

    /// The choices that are missing, in the order the sheet asks for them. Core is not called until there are none.
    static func inputBlockers(_ kind: OperationKind, _ inputs: OperationInputs) -> [OperationBlocker] {
        var out: [OperationBlocker] = []
        if kind.needsVault && inputs.vaultUUID == nil { out.append(.chooseVault) }
        if kind.needsRuntime && inputs.runtimeID == nil { out.append(.chooseRuntime) }
        if kind.needsFolder && inputs.folder == nil { out.append(.chooseFolder) }
        return out
    }

    /// Runs the review step for the sheet's current choices, off the cooperative pool. A preview for choices that changed
    /// while it ran is dropped: the next one is coming.
    func previewOperation() async {
        guard let sheet = operationSheet, sheet.phase == .review else { return }
        if sheet.kind.isDriveKind {
            // R6: planned from the Drives snapshot, on this actor — pure Core; the run reads the disks again (H1 inside).
            previewDriveOperation()
            return
        }
        let missing = Self.inputBlockers(sheet.kind, sheet.inputs)
        guard missing.isEmpty else {
            operationSheet?.preview = OperationPreview(blockers: missing)
            // A preview still in flight for the earlier choices is dropped when it returns; nothing else would clear
            // this (review I2).
            operationSheet?.isPreviewing = false
            return
        }
        operationSheet?.isPreviewing = true
        let preview = environment.operations.preview
        let (kind, inputs, id) = (sheet.kind, sheet.inputs, sheet.id)
        let result = await Self.offThePool { preview(kind, inputs) }
        guard operationSheet?.id == id, operationSheet?.kind == kind, operationSheet?.inputs == inputs, operationSheet?.phase == .review else { return }
        operationSheet?.preview = result
        operationSheet?.isPreviewing = false
    }

    /// A choice changed in the sheet: store it and review again.
    func updateOperationInputs(_ change: (inout OperationInputs) -> Void) {
        guard var sheet = operationSheet, sheet.phase == .review else { return }
        change(&sheet.inputs)
        sheet.preview = nil
        operationSheet = sheet
        Task { await previewOperation() }
    }

    /// **Check Again** (review I3): the same choices, reviewed again — Xcode quit, the vault came back, space was freed.
    func checkOperationAgain() {
        guard operationSheet?.phase == .review else { return }
        operationSheet?.preview = nil
        // R6: a drive sheet reads the disks again first — the drive may have been reconnected.
        if operationSheet?.kind.isDriveKind == true {
            Task { await refreshDrives() }
            return
        }
        Task { await previewOperation() }
    }

    /// After a scan, while the sheet reviews (review I3): a vault no longer usable is no longer chosen, and the review
    /// runs again on what the scan found.
    func revalidateOperationAfterScan() {
        guard let s = operationSheet, s.phase == .review else { return }
        if let uuid = s.inputs.vaultUUID, !usableVaults.contains(where: { $0.volume.volumeUUID == uuid }) {
            let kind = s.kind
            updateOperationInputs {
                $0.vaultUUID = nil
                // A standard folder of the vault that went away goes with it; a folder the user chose stays.
                if kind.needsFolder && !$0.folderIsCustom {
                    $0.folder = nil
                    $0.standardFolderOf = nil
                }
            }
        } else {
            checkOperationAgain()
        }
    }

    /// **Choose…**: the folder panel (behind `AppEnvironment`), then a new review.
    func chooseOperationFolder() async {
        guard let path = await environment.operations.chooseFolder(operationSheet?.inputs.folder ?? folderPanelStart) else { return }
        updateOperationInputs {
            $0.folder = path
            // **Choose Another Folder…** overrides the vault's standard folder (R6): the picker says "Other folder".
            $0.folderIsCustom = true
            $0.standardFolderOf = nil
            $0.vaultUUID = nil
        }
    }

    /// What disables the confirm button: the preview's blockers once it has run.
    var operationBlockers: [OperationBlocker] {
        let blockers = operationSheet?.preview?.blockers ?? []
        guard blockers.isEmpty, let name = typedNameNeeded else { return blockers }
        return [.typeName(name)]
    }

    /// Whether the confirm button is enabled: a finished review with something prepared and nothing blocking it.
    var canConfirmOperation: Bool {
        guard let s = operationSheet, s.phase == .review, !s.isPreviewing, let p = s.preview else { return false }
        return p.blockers.isEmpty && p.prepared != nil && typedNameNeeded == nil
    }

    /// The footer's leading text (R7-B, §3.7, ruling B-3): while the review cannot be confirmed, why — the first blocker in
    /// words, visible, never only a tooltip. Nil otherwise.
    var operationFooterReason: String? {
        guard let s = operationSheet, s.phase == .review, !canConfirmOperation, let first = operationBlockers.first else { return nil }
        return Self.blockerText(first)
    }

    /// **Check Again** in the footer, beside that reason: only while the review is blocked by something the world can
    /// change (review I3).
    var offersCheckAgain: Bool {
        guard let s = operationSheet, s.phase == .review, let p = s.preview else { return false }
        return !p.blockers.isEmpty
    }

    /// Why **Remove Original…** is disabled, in visible text (ruling B-3): the confirmation checkbox is not checked. Nil
    /// when it is enabled, or when it is disabled for a reason the sheet already shows (running, removed).
    var removeOriginalDisabledReason: String? {
        guard let s = operationSheet, !canRemoveOriginal, !isOperationRunning, case .copied(let outcome)? = s.result, !outcome.sourceRemoved else {
            return nil
        }
        switch s.secondStep {
        case .removeOriginal, .removeFailed: return removalNeedsConfirmation && !s.confirmRemoval ? L10n.tr("app.run.removeOriginal.needsConfirm") : nil
        default: return nil
        }
    }

    /// A blocker as the sheet says it. Core's own sentences are English prose and are shown as given.
    static func blockerText(_ blocker: OperationBlocker) -> String {
        switch blocker {
        case .chooseVault: L10n.tr("app.run.blocker.chooseVault")
        case .chooseFolder: L10n.tr("app.run.blocker.chooseFolder")
        case .chooseRuntime: L10n.tr("app.run.blocker.chooseRuntime")
        case .acknowledgeTests: L10n.tr("app.run.blocker.acknowledgeTests")
        case .simulatorWorkRunning: L10n.tr("app.run.blocker.simulatorWork")
        case .driveGone: L10n.tr("app.run.blocker.driveGone")
        case .typeName(let name): L10n.tr("app.run.blocker.typeName", name)
        case .diskChanged: L10n.tr("app.run.blocker.diskChanged")
        case .core(let why): why
        }
    }

    /// **Export installer first** (offload's preview found no installer): the export, in this sheet, for the runtime's
    /// platform and version into the chosen library. Offload's choices come back when it succeeds.
    func exportInstallerFirst() {
        guard var s = operationSheet, s.kind == .offloadRuntime, s.phase == .review, s.preview?.installerMissing == true,
            let runtime = runtimesForPicker.first(where: { $0.identifier == s.inputs.runtimeID }), let platform = OperationKind.exportPlatform(for: runtime)
        else { return }
        s.offloadToReturnTo = s.inputs
        s.kind = .exportRuntime
        s.inputs = OperationInputs(
            folder: s.inputs.folder, platform: platform, buildVersion: runtime.version, folderIsCustom: s.inputs.folderIsCustom,
            standardFolderOf: s.inputs.standardFolderOf)
        s.preview = nil
        operationSheet = s
        Task { await previewOperation() }
    }

    /// Whether **Back to Offload** is offered: an export offload asked for failed (review M9).
    var offersBackToOffload: Bool {
        guard let s = operationSheet, s.offloadToReturnTo != nil, case .failed = s.phase else { return false }
        return true
    }

    /// **Back to Offload**: offload's review again, with its choices; the log is kept.
    func backToOffload() {
        guard offersBackToOffload, var s = operationSheet, let back = s.offloadToReturnTo else { return }
        s.kind = .offloadRuntime
        s.inputs = back
        s.offloadToReturnTo = nil
        s.phase = .review
        s.stage = .planning
        s.result = nil
        s.preview = nil
        operationSheet = s
        Task { await previewOperation() }
    }

    // MARK: - Running

    /// Whether something is running: the operation, or its second step. What the quit guard asks about.
    var isOperationRunning: Bool {
        guard let s = operationSheet else { return false }
        return s.phase == .running || s.secondStep == .removingOriginal || s.secondStep == .undoing
    }

    /// The journal ids of what runs now, which the History and the banner treat as in progress. Only a migration's is
    /// known before it starts; scans wait while anything runs (`refresh`), so the others never show as interrupted.
    var runningJournalIDs: Set<String> {
        guard isOperationRunning, let id = operationSheet?.runningJournalID else { return [] }
        return [id]
    }

    /// What **Quit** may do now (review M1).
    enum QuitChoice: Equatable {
        case quitNow
        /// Only **Keep Running**: the operation's command cannot be stopped cleanly.
        case keepRunningOnly(QuitReason)
        /// **Stop and Quit**: terminate the running command, wait for the operation to record how it ended, then quit.
        case stopThenQuit
    }

    enum QuitReason: Equatable {
        /// Copy, verify or remove: stopping leaves a copy half-written that the journal calls interrupted.
        case migration
        /// `xcodebuild -downloadPlatform`: stopping it part-way has not been tested.
        case export
        /// Offload's `simctl runtime delete`: the service may finish the delete after the client is stopped, and the journal
        /// would then say `failed` for a runtime that is gone — Doctor would no longer offer the offload's way back.
        case offload
        /// A Delete view clean (`CleanExecutor`), which deletes or trashes item by item: stopping it part-way is untested
        /// (R5 safety review, pre-existing gap).
        case clean
        /// R6: `diskutil` erasing or partitioning a drive, or registering one: stopping part-way leaves the disk in a state
        /// nobody chose.
        case diskPreparation
        /// R6: **Use This Drive** writing the registry, the sentinel and the folders: no diskutil, but not stopped half-way.
        case vaultRegistration
    }

    /// The decision per stage and kind. Copying, verifying and removing an original keep running; so do an export and an
    /// offload. Deleting a runtime and applying a folder can be stopped: their commands are short, and a stopped one is
    /// recorded as failed.
    static func quitChoice(running: Bool, stage: OperationStage, kind: OperationKind) -> QuitChoice {
        guard running else { return .quitNow }
        if !kind.canBeStopped {
            switch kind {
            case .exportRuntime: return .keepRunningOnly(.export)
            case .offloadRuntime: return .keepRunningOnly(.offload)
            case .addVolume, .addPartition, .eraseVolume, .eraseDisk: return .keepRunningOnly(.diskPreparation)
            case .useDrive: return .keepRunningOnly(.vaultRegistration)
            default: return .keepRunningOnly(.migration)
            }
        }
        switch stage {
        case .copying, .verifying, .removing: return .keepRunningOnly(.migration)
        case .preparing: return .keepRunningOnly(.diskPreparation)
        case .exporting: return .keepRunningOnly(.export)
        case .planning, .deleting, .applying, .done, .failed: return .stopThenQuit
        }
    }

    var quitChoice: QuitChoice {
        // Running implies a sheet (`isOperationRunning`), so a kind always reaches the rule; without one, nothing runs.
        let operation = operationSheet.map { Self.quitChoice(running: isOperationRunning, stage: $0.stage, kind: $0.kind) } ?? .quitNow
        // A clean running beside it keeps the app open whatever the operation allows: it cannot be stopped (R5).
        return Self.quitChoice(operation: operation, cleaning: isCleaning)
    }

    /// The operation's choice, with a running clean on top (R5): a clean only ever keeps running, so it overrides quitting
    /// now and Stop and Quit, which would leave the clean half done; an operation that keeps running keeps its own reason.
    static func quitChoice(operation: QuitChoice, cleaning: Bool) -> QuitChoice {
        guard cleaning else { return operation }
        if case .keepRunningOnly = operation { return operation }
        return .keepRunningOnly(.clean)
    }

    /// Kept for the guard's callers: whether quitting asks first.
    var quitNeedsConfirmation: Bool { quitChoice != .quitNow }

    /// **Stop and Quit**: stops the running command — SIGTERM, then SIGKILL if it is still there — then waits for the
    /// operation to end and journal how it ended. True only when nothing runs any more: the app never quits with a child
    /// alive (R3 re-review L-B).
    func stopOperationForQuit(timeout: Duration = .seconds(30), termWait: TimeInterval = 20, killWait: TimeInterval = 10) async -> Bool {
        guard quitChoice == .stopThenQuit else { return !isOperationRunning }
        if let children = activeChildren {
            let gone = await Self.offThePool { children.stopAndWait(timeout: termWait) || children.killAndWait(timeout: killWait) }
            guard gone else { return false }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isOperationRunning && clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return !isOperationRunning
    }

    /// The confirm button: runs what the review prepared, streaming its log. No cancel (rule 4): Core's copy, verify and
    /// remove are not interruptible from here, and export's cancel was not made clean this round.
    func runOperation() async {
        guard canConfirmOperation, var s = operationSheet, var prepared = s.preview?.prepared else { return }
        // R6: the name as typed goes to Core, which refuses an erase without the exact name whatever was decided here.
        // H1: always the plan the user previewed, never one derived after the preview.
        if case .diskPreparation(let plan, _) = prepared { prepared = .diskPreparation(s.previewedPlan ?? plan, confirmedName: s.confirmationText) }
        s.phase = .running
        s.stage = s.kind.runningStage
        s.startedAt = Date()
        s.finishedAt = nil
        s.progressBytes = nil
        s.runningJournalID = prepared.journalID
        operationSheet = s
        beginOperationLog(s.kind.rawValue)
        appendLog([LogLine(.stage, s.stage.rawValue)])
        let run = environment.operations.run
        // Copy progress only: an export's folder may not grow until the end (review M4), so it shows elapsed time alone.
        let progress: String? = if case .migration(let plan) = prepared { plan.destination } else { nil }
        let toRun = prepared
        let result = await execute(progress) { children, observer in try run(toRun, children, observer) }
        finishOperation(result)
        await refresh()
        if s.kind.isDriveKind { await refreshDrives() }
        if case .success(.exported) = result { returnToOffloadIfAsked() }
    }

    /// Runs `work` on a GCD thread (minutes of `waitUntilExit` must not hold a cooperative-pool thread, review M15) with
    /// an observer whose lines reach the main actor in order, a batch per turn (review M1, minor), while the copy is
    /// measured. Returns when the work and every line it sent are done.
    func execute<T: Sendable>(
        _ copyDestination: String?, _ work: @escaping @Sendable (ChildProcesses, @escaping LogObserver) throws -> T
    ) async -> Result<T, any Error> {
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "XCodeVault operation")
        let children = ChildProcesses()
        activeChildren = children
        let buffer = LineBuffer()
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await _ in ticks { appendLog(buffer.drain()) }
            appendLog(buffer.drain())
        }
        let poller = copyDestination.map { watch(copyTo: $0) }
        let observer: LogObserver = { line in
            buffer.add(line)
            tick.yield()
        }
        let result = await Self.offThePool { () -> Result<T, any Error> in Result { try work(children, observer) } }
        tick.finish()
        await consumer.value
        poller?.cancel()
        await poller?.value
        activeChildren = nil
        if let a = awakeActivity { ProcessInfo.processInfo.endActivity(a) }
        awakeActivity = nil
        return result
    }

    /// Long synchronous work on a GCD thread, bridged back with a continuation.
    static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    /// Lines from the running operation, in one mutation: into the log, and the stage they imply (`OperationStage.after`).
    func appendLog(_ lines: [LogLine]) {
        guard !lines.isEmpty, var s = operationSheet else { return }
        for line in lines {
            s.log.append(line)
            operationLogFile?.append(line)
            let next = OperationStage.after(line, from: s.stage)
            if next != s.stage {
                s.stage = next
                let stageLine = LogLine(.stage, next.rawValue)
                s.log.append(stageLine)
                operationLogFile?.append(stageLine)
            }
        }
        operationSheet = s
    }

    private func beginOperationLog(_ name: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        operationLogFile = environment.operations.logFile?("\(stamp)-\(name)")
        if let url = operationLogFile?.url { operationSheet?.logFileURL = url }
    }

    /// Measures the vault copy while it is copying, no more often than `pollInterval` and never more than half the time
    /// (a measure that takes a second waits two before the next, review M5).
    private func watch(copyTo path: String) -> Task<Void, Never> {
        let measure = environment.operations.measure
        let interval = environment.operations.pollInterval
        let id = operationSheet?.id
        return Task { @MainActor in
            let clock = ContinuousClock()
            while !Task.isCancelled, operationSheet?.id == id, operationSheet?.stage == .copying {
                let started = clock.now
                let bytes = await Self.offThePool { measure(path) }
                guard !Task.isCancelled, operationSheet?.id == id else { return }
                operationSheet?.progressBytes = bytes
                try? await Task.sleep(for: max(interval, (clock.now - started) * 2))
            }
        }
    }

    /// The step after a successful run (rule 4): **Remove original…** after a verified externalization that kept its
    /// source, **Undo** after a Locations change; nothing otherwise.
    static func secondStep(after result: OperationResult) -> OperationSheetState.SecondStep {
        switch result {
        case .copied(let outcome): outcome.plan.direction == .externalize && !outcome.sourceRemoved ? .removeOriginal : .none
        case .locationApplied: .undo
        case .offloaded, .exported, .runtimeDeleted, .drivePrepared, .driveRegistered: .none
        }
    }

    private func finishOperation(_ result: Result<OperationResult, any Error>) {
        guard var s = operationSheet else { return }
        s.finishedAt = Date()
        switch result {
        case .success(let r):
            s.phase = .succeeded(Self.secondStep(after: r))
            s.stage = .done
            s.result = r
        case .failure:
            s.phase = .failed(Self.failureText(result))
            s.stage = .failed
        }
        operationSheet = s
        if case .failure(let error) = result { appendLog([LogLine(.stderr, "\(error)")]) }
        appendLog([LogLine(.stage, s.stage.rawValue)])
        operationLogFile = nil
        environment.operations.notifyFinished()
    }

    private static func failureText(_ result: Result<OperationResult, any Error>) -> String {
        if case .failure(let error) = result { return "\(error)" }
        return ""
    }

    /// After an export offload asked for: back to offload's review, with its choices, the log kept.
    private func returnToOffloadIfAsked() {
        guard var s = operationSheet, s.isSucceeded, let back = s.offloadToReturnTo else { return }
        s.kind = .offloadRuntime
        s.inputs = back
        s.offloadToReturnTo = nil
        s.exportedFirst = true
        s.phase = .review
        s.stage = .planning
        s.result = nil
        s.preview = nil
        operationSheet = s
        Task { await previewOperation() }
    }

    // MARK: - Progress, as the sheet shows it

    /// The bar's fraction: the vault copy against the plan's size while copying; nil (indeterminate) otherwise.
    var operationProgressFraction: Double? {
        guard let s = operationSheet, s.stage == .copying, case .migration(let plan)? = s.preview?.prepared else { return nil }
        return OperationProgress.fraction(done: s.progressBytes, total: plan.sourceBytes)
    }

    /// The migration id whose partial copy a failed copy may have left on the vault, when the scanned journal says one may
    /// be there (review I4): what `xcodevaultctl migration abort <id>` removes.
    var failedCopyLeftoverID: String? {
        guard let s = operationSheet, case .failed = s.phase, s.kind == .externalizeArchives, let id = s.runningJournalID,
            interruptedMigrations.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    // MARK: - The second steps

    /// Whether removing the original needs the non-regenerable checkbox: the category's own regenerability.
    var removalNeedsConfirmation: Bool {
        guard case .copied(let outcome)? = operationSheet?.result else { return false }
        return StorageCatalog.category(outcome.plan.categoryID)?.regenerability == .nonRegenerable
    }

    /// **Remove original…** is enabled: a verified copy whose source is kept, nothing running, and the checkbox checked
    /// when the data is non-regenerable. After a failed removal it is offered again: Core re-verifies every time.
    var canRemoveOriginal: Bool {
        guard let s = operationSheet, !isOperationRunning, case .copied(let outcome)? = s.result, !outcome.sourceRemoved else { return false }
        switch s.secondStep {
        case .removeOriginal, .removeFailed: return !removalNeedsConfirmation || s.confirmRemoval
        default: return false
        }
    }

    /// The second step of an externalization: `removeSource`, with the checkbox's value as its confirmation — Core
    /// refuses non-regenerable data without it, whatever this layer decided.
    func removeOriginal() async {
        guard canRemoveOriginal, var s = operationSheet, case .copied(let outcome)? = s.result else { return }
        let confirmed = s.confirmRemoval
        s.secondStep = .removingOriginal
        s.stage = .removing
        s.runningJournalID = outcome.plan.operationID
        operationSheet = s
        beginOperationLog("remove-original")
        appendLog([LogLine(.stage, OperationStage.removing.rawValue)])
        let remove = environment.operations.removeSource
        let result = await execute(nil) { _, observer in try remove(outcome, confirmed, observer) }
        guard var done = operationSheet else { return }
        switch result {
        case .success(let removed):
            done.result = .copied(removed)
            done.secondStep = .originalRemoved
            done.stage = .done
        case .failure(let error):
            done.secondStep = .removeFailed("\(error)")
            done.stage = .failed
        }
        operationSheet = done
        if case .failure(let error) = result { appendLog([LogLine(.stderr, "\(error)")]) }
        appendLog([LogLine(.stage, done.stage.rawValue)])
        operationLogFile = nil
        environment.operations.notifyFinished()
        await refresh()
    }

    /// What **Undo** puts back: the folder Xcode used before the change, or nil for its default (review L4).
    var undoRestores: String?? {
        guard case .locationApplied(_, let previous)? = operationSheet?.result else { return nil }
        return .some(previous)
    }

    /// **Undo** after a Locations change: the previous folder put back, or Xcode's default when it had none.
    func undoLocation() async {
        guard var s = operationSheet, !isOperationRunning, case .locationApplied(let key, let previous)? = s.result else { return }
        switch s.secondStep {
        case .undo, .undoFailed: break
        default: return
        }
        s.secondStep = .undoing
        s.stage = .applying
        operationSheet = s
        beginOperationLog("undo")
        appendLog([LogLine(.stage, OperationStage.applying.rawValue)])
        let restore = environment.operations.restoreLocation
        let result = await execute(nil) { children, observer in try restore(key, previous, children, observer) }
        guard var done = operationSheet else { return }
        switch result {
        case .success:
            done.secondStep = .undone
            done.stage = .done
        case .failure(let error):
            done.secondStep = .undoFailed("\(error)")
            done.stage = .failed
        }
        operationSheet = done
        if case .failure(let error) = result { appendLog([LogLine(.stderr, "\(error)")]) }
        appendLog([LogLine(.stage, done.stage.rawValue)])
        operationLogFile = nil
        await refresh()
    }

    // MARK: - Closing, the log, History

    /// **Cancel** / **Done**: closes the sheet. Never while something runs.
    func closeOperationSheet() {
        guard !isOperationRunning else { return }
        operationSheet = nil
        // R6: back to the Run sheet **Prepare…** came from, its destination reviewed against the drives as they are now.
        if var back = suspendedOperationSheet {
            suspendedOperationSheet = nil
            // Minor 3: a vault the preparation just made, when it is the only usable one, becomes the destination.
            if back.inputs.vaultUUID == nil, !back.inputs.folderIsCustom, back.kind.usesDestination, let uuid = defaultVaultUUID {
                back.inputs.vaultUUID = uuid
                if back.kind.needsFolder { Self.applyStandardFolder(back.kind, usableVaults.first { $0.volume.volumeUUID == uuid }, to: &back.inputs) }
                back.preview = nil
            }
            operationSheet = back
            revalidateOperationAfterScan()
        }
    }

    /// **Copy Log**: the lines kept in memory, as text, naming the full log's file when lines were dropped.
    func copyOperationLog() {
        guard let s = operationSheet else { return }
        environment.copy(s.log.text(fullLogAt: s.logFileURL?.path))
    }

    /// **Show in History**: closes the sheet and shows History.
    func showHistoryFromOperation() {
        guard !isOperationRunning else { return }
        operationSheet = nil
        suspendedOperationSheet = nil
        section = .history
    }

    /// The banner's lines (`MigrationRecovery`), oldest first: interrupted migrations, then failed ones whose partial copy
    /// may still be on disk (review I4), each once.
    static func interruptedBanner(
        _ entries: [JournalEntry], running: Set<String>, mayBePresent: (String) -> Bool = { MigrationEngine.presence(of: $0).mayBePresent }
    ) -> [InterruptedMigration] {
        let interrupted = MigrationRecovery.interrupted(entries, running: running)
        var items = interrupted.map { last in
            // The opening record's summary says what the migration was; the last one only names a phase.
            let opening = entries.filter { $0.id == last.id }.min { $0.sequence < $1.sequence }
            return InterruptedMigration(
                id: last.id, summary: opening?.summary ?? last.summary, commands: MigrationRecovery.commands(for: last.id, in: entries))
        }
        let listed = Set(items.map(\.id))
        for plan in MigrationRecovery.leftoverPartialCopies(entries, mayBePresent: mayBePresent)
        where !listed.contains(plan.id) && !running.contains(plan.id) {
            items.append(
                InterruptedMigration(
                    id: plan.id, summary: plan.summary,
                    commands: ["xcodevaultctl migration status", "xcodevaultctl migration abort \(plan.id)"]))
        }
        return items
    }
}

/// Lines the operation produced, waiting for the main actor: appended from any thread, taken in order in one batch.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []

    func add(_ line: LogLine) { lock.withLock { lines.append(line) } }

    func drain() -> [LogLine] {
        lock.withLock {
            defer { lines.removeAll(keepingCapacity: true) }
            return lines
        }
    }
}
