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

    /// The runtimes the picker offers, largest first. No default: a runtime to delete is always chosen.
    var runtimesForPicker: [SimulatorRuntime] {
        (report?.runtimes ?? []).sorted { ($0.sizeBytes ?? 0, $1.identifier) > ($1.sizeBytes ?? 0, $0.identifier) }
    }

    // MARK: - Opening and reviewing

    /// **Run…** on a row: opens the sheet on its review step. Refused while an operation runs (one at a time).
    func openRun(_ row: SavingsPlanRow) {
        guard let kind = OperationKind.forRow(row), !isOperationRunning else { return }
        var inputs = OperationInputs()
        if kind.needsVault { inputs.vaultUUID = defaultVaultUUID }
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

    /// Runs the review step for the sheet's current choices, off the main actor. A preview for choices that changed while
    /// it ran is dropped: the next one is coming.
    func previewOperation() async {
        guard let sheet = operationSheet, sheet.phase == .review else { return }
        let missing = Self.inputBlockers(sheet.kind, sheet.inputs)
        guard missing.isEmpty else {
            operationSheet?.preview = OperationPreview(blockers: missing)
            return
        }
        operationSheet?.isPreviewing = true
        let preview = environment.operations.preview
        let (kind, inputs, id) = (sheet.kind, sheet.inputs, sheet.id)
        let result = await Task.detached(priority: .userInitiated) { preview(kind, inputs) }.value
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

    /// **Choose…**: the folder panel (behind `AppEnvironment`), then a new review.
    func chooseOperationFolder() {
        guard let path = environment.operations.chooseFolder(operationSheet?.inputs.folder ?? folderPanelStart) else { return }
        updateOperationInputs { $0.folder = path }
    }

    /// What disables the confirm button: the preview's blockers once it has run.
    var operationBlockers: [OperationBlocker] { operationSheet?.preview?.blockers ?? [] }

    /// Whether the confirm button is enabled: a finished review with something prepared and nothing blocking it.
    var canConfirmOperation: Bool {
        guard let s = operationSheet, s.phase == .review, !s.isPreviewing, let p = s.preview else { return false }
        return p.blockers.isEmpty && p.prepared != nil
    }

    /// A blocker as the sheet says it. Core's own sentences are English prose and are shown as given.
    static func blockerText(_ blocker: OperationBlocker) -> String {
        switch blocker {
        case .chooseVault: L10n.tr("app.run.blocker.chooseVault")
        case .chooseFolder: L10n.tr("app.run.blocker.chooseFolder")
        case .chooseRuntime: L10n.tr("app.run.blocker.chooseRuntime")
        case .acknowledgeTests: L10n.tr("app.run.blocker.acknowledgeTests")
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
        s.inputs = OperationInputs(folder: s.inputs.folder, platform: platform, buildVersion: runtime.version)
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

    /// Quitting asks first while this is true (`AppDelegate.applicationShouldTerminate`).
    var quitNeedsConfirmation: Bool { isOperationRunning }

    /// The journal ids of what runs now, which the History and the banner treat as in progress.
    var runningJournalIDs: Set<String> {
        guard isOperationRunning, let id = operationSheet?.runningJournalID else { return [] }
        return [id]
    }

    /// The confirm button: runs what the review prepared, streaming its log. No cancel (rule 4): Core's copy, verify and
    /// remove are not interruptible from here, and export's cancel was not made clean this round.
    func runOperation() async {
        guard canConfirmOperation, var s = operationSheet, let prepared = s.preview?.prepared else { return }
        s.phase = .running
        s.stage = s.kind.runningStage
        s.startedAt = Date()
        s.finishedAt = nil
        s.progressBytes = nil
        s.progressBaseline = nil
        s.runningJournalID = prepared.journalID
        operationSheet = s
        beginOperationLog(s.kind.rawValue)
        appendLog(LogLine(.stage, s.stage.rawValue))
        let run = environment.operations.run
        let progress: ProgressWatch? =
            switch prepared {
            case .migration(let plan): ProgressWatch(path: plan.destination, mode: .copy)
            case .export(let req, _, _): ProgressWatch(path: req.destination, mode: .added)
            default: nil
            }
        let result = await execute(progress) { observer in try run(prepared, observer) }
        finishOperation(result)
        await refresh()
        if case .success(.exported) = result { returnToOffloadIfAsked() }
    }

    /// What the progress bar measures, and how.
    struct ProgressWatch: Sendable {
        enum Mode: Sendable { case copy, added }
        let path: String
        let mode: Mode
    }

    /// Runs `work` off the main actor with an observer whose lines come back to the main actor in order (one stream),
    /// while the progress watch measures. Returns when the work and every line it sent are done.
    func execute<T: Sendable>(_ progress: ProgressWatch?, _ work: @escaping @Sendable (@escaping LogObserver) throws -> T) async -> Result<T, any Error> {
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "XCodeVault operation")
        let (stream, continuation) = AsyncStream.makeStream(of: LogLine.self)
        let consumer = Task { @MainActor in
            for await line in stream { receive(line) }
        }
        let poller = progress.map { watch(progress: $0) }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<T, any Error> in
            Result { try work { continuation.yield($0) } }
        }.value
        continuation.finish()
        await consumer.value
        poller?.cancel()
        if let a = awakeActivity { ProcessInfo.processInfo.endActivity(a) }
        awakeActivity = nil
        return result
    }

    /// One line from the running operation: into the log, and the stage it implies (`OperationStage.after`).
    func receive(_ line: LogLine) {
        guard let current = operationSheet?.stage else { return }
        appendLog(line)
        let next = OperationStage.after(line, from: current)
        if next != current {
            operationSheet?.stage = next
            appendLog(LogLine(.stage, next.rawValue))
        }
    }

    func appendLog(_ line: LogLine) {
        operationSheet?.log.append(line)
        operationLogFile?.append(line)
    }

    private func beginOperationLog(_ name: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        operationLogFile = environment.operations.logFile?("\(stamp)-\(name)")
    }

    /// Measures every `pollInterval` until cancelled; a copy only while it is still copying.
    private func watch(progress: ProgressWatch) -> Task<Void, Never> {
        let measure = environment.operations.measure
        let interval = environment.operations.pollInterval
        let id = operationSheet?.id
        return Task { @MainActor in
            if progress.mode == .added {
                let baseline = await Task.detached { measure(progress.path) }.value
                guard operationSheet?.id == id else { return }
                operationSheet?.progressBaseline = baseline
            }
            while !Task.isCancelled {
                if progress.mode == .copy && operationSheet?.stage != .copying { return }
                let bytes = await Task.detached { measure(progress.path) }.value
                guard !Task.isCancelled, operationSheet?.id == id else { return }
                operationSheet?.progressBytes = bytes
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The step after a successful run (rule 4): **Remove original…** after a verified externalization that kept its
    /// source, **Undo** after a Locations change; nothing otherwise.
    static func secondStep(after result: OperationResult) -> OperationSheetState.SecondStep {
        switch result {
        case .copied(let outcome): outcome.plan.direction == .externalize && !outcome.sourceRemoved ? .removeOriginal : .none
        case .locationApplied: .undo
        case .offloaded, .exported, .runtimeDeleted: .none
        }
    }

    private func finishOperation(_ result: Result<OperationResult, any Error>) {
        guard var s = operationSheet else { return }
        s.finishedAt = Date()
        switch result {
        case .success(let r):
            s.phase = .succeeded
            s.stage = .done
            s.result = r
            s.secondStep = Self.secondStep(after: r)
        case .failure(let error):
            s.phase = .failed("\(error)")
            s.stage = .failed
            s.log.append(LogLine(.stderr, "\(error)"))
            operationLogFile?.append(LogLine(.stderr, "\(error)"))
        }
        operationSheet = s
        appendLog(LogLine(.stage, s.stage.rawValue))
        operationLogFile = nil
    }

    /// After an export offload asked for: back to offload's review, with its choices, the log kept.
    private func returnToOffloadIfAsked() {
        guard var s = operationSheet, s.phase == .succeeded, let back = s.offloadToReturnTo else { return }
        s.kind = .offloadRuntime
        s.inputs = back
        s.offloadToReturnTo = nil
        s.exportedFirst = true
        s.phase = .review
        s.stage = .planning
        s.result = nil
        s.secondStep = .none
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

    /// An export's bytes so far: the folder's growth since it started.
    var operationDownloadedBytes: UInt64? {
        guard let s = operationSheet, s.stage == .exporting else { return nil }
        return OperationProgress.added(baseline: s.progressBaseline, current: s.progressBytes)
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
        appendLog(LogLine(.stage, OperationStage.removing.rawValue))
        let remove = environment.operations.removeSource
        let result = await execute(nil) { observer in try remove(outcome, confirmed, observer) }
        guard var done = operationSheet else { return }
        switch result {
        case .success(let removed):
            done.result = .copied(removed)
            done.secondStep = .originalRemoved
            done.stage = .done
        case .failure(let error):
            done.secondStep = .removeFailed("\(error)")
            done.stage = .failed
            done.log.append(LogLine(.stderr, "\(error)"))
        }
        operationSheet = done
        appendLog(LogLine(.stage, done.stage.rawValue))
        operationLogFile = nil
        await refresh()
    }

    /// **Undo** after a Locations change: back to Xcode's default through Core's reset path.
    func undoLocation() async {
        guard var s = operationSheet, !isOperationRunning, case .locationApplied(let key)? = s.result else { return }
        switch s.secondStep {
        case .undo, .undoFailed: break
        default: return
        }
        s.secondStep = .undoing
        s.stage = .applying
        operationSheet = s
        appendLog(LogLine(.stage, OperationStage.applying.rawValue))
        let reset = environment.operations.resetLocation
        let result = await execute(nil) { observer in try reset(key, observer) }
        guard var done = operationSheet else { return }
        switch result {
        case .success:
            done.secondStep = .undone
            done.stage = .done
        case .failure(let error):
            done.secondStep = .undoFailed("\(error)")
            done.stage = .failed
            done.log.append(LogLine(.stderr, "\(error)"))
        }
        operationSheet = done
        appendLog(LogLine(.stage, done.stage.rawValue))
        await refresh()
    }

    // MARK: - Closing, the log, History

    /// **Cancel** / **Done**: closes the sheet. Never while something runs.
    func closeOperationSheet() {
        guard !isOperationRunning else { return }
        operationSheet = nil
    }

    /// **Copy Log**: the lines kept in memory, as text.
    func copyOperationLog() {
        guard let text = operationSheet?.log.text else { return }
        environment.copy(text)
    }

    /// **Show in History**: closes the sheet and shows History.
    func showHistoryFromOperation() {
        guard !isOperationRunning else { return }
        operationSheet = nil
        section = .history
    }

    /// The banner's lines (`MigrationRecovery`), oldest first.
    static func interruptedBanner(_ entries: [JournalEntry], running: Set<String>) -> [InterruptedMigration] {
        MigrationRecovery.interrupted(entries, running: running).map { last in
            // The opening record's summary says what the migration was; the last one only names a phase.
            let opening = entries.filter { $0.id == last.id }.min { $0.sequence < $1.sequence }
            return InterruptedMigration(
                id: last.id, summary: opening?.summary ?? last.summary, commands: MigrationRecovery.commands(for: last.id, in: entries))
        }
    }
}
