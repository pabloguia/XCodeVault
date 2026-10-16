import Foundation
import XCodeVaultCore

/// R6 (ADR-0012): external drives — detection, the verdicts, preparation and **Use This Drive** — and the Run sheet's
/// **Destination**. Every decision is Core's (`DriveEvaluation`, `DiskSafety`, `DiskPreparation`, `VaultLayout`) or made
/// here and tested; the views draw it. Preparation is EXPERIMENTAL (rule 10).
extension AppModel {
    // MARK: - Detection

    /// Starts hearing mounts and unmounts (once): each one schedules a debounced re-read of the drives.
    func startObservingDrives() {
        guard driveObservation == nil else { return }
        driveObservation = environment.drives.observe { [weak self] in self?.drivesChanged() }
    }

    /// A mount or unmount: one re-read after the burst settles (`DriveServices.debounce`), not one per event and not a
    /// full scan.
    func drivesChanged() {
        driveRefreshTask?.cancel()
        let delay = environment.drives.debounce
        driveRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshDrives()
        }
    }

    /// Reads the disks off the main actor and re-plans an open drive sheet against what is there now.
    /// Reads that finish out of order are dropped: only the newest request's result is kept (minor 4). An open drive
    /// sheet gets the drive as it is now (its option list, minor 5) and is planned again — never replacing the plan the
    /// user previewed (H1, `previewOperation`).
    func refreshDrives() async {
        driveReadGeneration += 1
        let generation = driveReadGeneration
        let read = environment.drives.snapshot
        let snapshot = await Self.offThePool { read() }
        guard generation == driveReadGeneration else { return }
        driveSnapshot = snapshot
        if let s = operationSheet, s.kind.isDriveKind, s.phase == .review {
            if let id = s.drive?.disk.id, let now = driveAssessments.first(where: { $0.disk.id == id }) { operationSheet?.drive = now }
            operationSheet?.preview = nil
            await previewOperation()
        }
    }

    /// The external drives, judged, ready vaults first (`DriveEvaluation.assessAll`). Empty before the first read.
    var driveAssessments: [DriveAssessment] {
        guard let driveSnapshot else { return [] }
        return DriveEvaluation.assessAll(driveSnapshot, vaults: vaultChecks)
    }

    // MARK: - Opening a drive sheet

    /// **Prepare…** / an option's button: the preparation sheet for `assessment`, on `option` when given, else on the
    /// first option that runs a command (least destructive first). From the Run sheet's review, that sheet is put aside
    /// and comes back when this one closes.
    func openPreparation(_ assessment: DriveAssessment, option: PreparationOption? = nil) {
        guard !isOperationRunning else { return }
        guard let chosen = option ?? assessment.recommendedOption ?? assessment.commandOptions.first, let kind = OperationKind.forOption(chosen)
        else { return }
        var inputs = OperationInputs()
        inputs.diskID = assessment.disk.id
        inputs.driveOption = chosen
        open(kind, inputs: inputs, drive: assessment)
    }

    /// **Use This Drive**: register the drive's qualifying volume and create the standard folders.
    func openUseDrive(_ assessment: DriveAssessment) {
        guard !isOperationRunning, let volume = assessment.registrable else { return }
        var inputs = OperationInputs()
        inputs.diskID = assessment.disk.id
        inputs.driveVolumeUUID = volume.volumeUUID
        open(.useDrive, inputs: inputs, drive: assessment)
    }

    /// **Prepare…** beside a drive in the Destination picker: **Use This Drive** when it can be used as it is, the
    /// preparation sheet otherwise.
    func prepareFromDestination(_ assessment: DriveAssessment) {
        switch assessment.prepareAction {
        case .useDrive: openUseDrive(assessment)
        case .prepare(let option): openPreparation(assessment, option: option)
        case .nothing: break
        }
    }

    /// The drives listed under the Destination picker: those that can be used or need preparation, and a ready drive
    /// whose vault is not the destination's but has a recommended fix (a case-sensitive vault, C1). Ready vaults are in
    /// the picker itself.
    var destinationDrives: [DriveAssessment] {
        driveAssessments.filter { $0.verdict == .canBeUsed || $0.verdict == .needsPreparation || ($0.verdict == .ready && $0.recommendedOption != nil) }
    }

    private func open(_ kind: OperationKind, inputs: OperationInputs, drive: DriveAssessment) {
        if let current = operationSheet, current.phase == .review, !current.kind.isDriveKind { suspendedOperationSheet = current }
        operationSheet = OperationSheetState(row: nil, kind: kind, inputs: inputs, drive: drive)
        Task { await previewOperation() }
    }

    /// A different option in the preparation sheet: its kind, the same volume settings, a new plan. The typed name is
    /// cleared: it confirmed the previous plan, not this one.
    func choosePreparationOption(_ option: PreparationOption) {
        guard var s = operationSheet, s.phase == .review, let kind = OperationKind.forOption(option) else { return }
        s.kind = kind
        s.inputs.driveOption = option
        if kind != .addVolume { s.inputs.volume.quotaGigabytes = nil }
        s.confirmationText = ""
        // The user chose another plan: it is the one previewed next (H1 never applies to a choice the user made).
        s.previewedPlan = nil
        s.preview = nil
        operationSheet = s
        Task { await previewOperation() }
    }

    /// The options the preparation sheet offers: the drive's options that run a command.
    var preparationChoices: [PreparationOption] { operationSheet?.drive?.commandOptions ?? [] }

    /// What the user types to confirm an erase. Never re-plans.
    func updateConfirmationText(_ text: String) {
        guard operationSheet?.phase == .review else { return }
        operationSheet?.confirmationText = text
    }

    /// The name still to be typed before an erase can run; nil when nothing is to be typed or it matches.
    var typedNameNeeded: String? {
        guard let s = operationSheet, case .diskPreparation(let plan, _)? = s.preview?.prepared, let name = plan.confirmationName else { return nil }
        return DiskPreparation.confirmationAccepted(typed: s.confirmationText, plan: plan) ? nil : name
    }

    /// The plan the review shows: the command, what it destroys, the name to type.
    var pendingDiskPlan: DiskPreparationPlan? {
        guard case .diskPreparation(let plan, _)? = operationSheet?.preview?.prepared else { return nil }
        return plan
    }

    // MARK: - Planning (tested)

    /// The review of a drive kind, from the snapshot as last read. Core plans; the run reads the disks again
    /// (`DiskPreparation.execute`), so this can only be wrong about what the sheet shows, never about what runs.
    static func drivePreview(_ kind: OperationKind, _ inputs: OperationInputs, snapshot: DriveSnapshot?, vaults: [VaultVolumeCheck]) -> OperationPreview {
        guard let snapshot else { return OperationPreview(blockers: [.driveGone]) }
        if kind == .useDrive {
            guard let uuid = inputs.driveVolumeUUID, let v = snapshot.volumes.first(where: { $0.volumeUUID == uuid }), let mp = v.mountPoint else {
                return OperationPreview(blockers: [.driveGone])
            }
            let q = VolumeQualification.evaluate(v)
            guard q.verdict != .unsuitable else { return OperationPreview(destination: mp, blockers: q.blockers.map { .core($0) }) }
            return OperationPreview(
                destination: mp + "/" + VaultVolume.directoryName, warnings: q.warnings,
                prepared: .useDrive(v))
        }
        guard let diskID = inputs.diskID, let option = inputs.driveOption, let disk = snapshot.disks.first(where: { $0.id == diskID }) else {
            return OperationPreview(blockers: [.driveGone])
        }
        let assessment = DriveEvaluation.assess(disk, in: snapshot, vaults: vaults)
        do {
            let plan = try DiskPreparation.plan(
                option, configuration: inputs.volume, on: assessment, snapshot: snapshot, registeredVaultUUIDs: Set(vaults.map(\.volume.volumeUUID)))
            let destroyed = plan.destroys.compactMap(\.usedBytes)
            return OperationPreview(
                source: assessment.displayName, bytes: destroyed.isEmpty ? nil : destroyed.reduce(0, +), prepared: .diskPreparation(plan, confirmedName: ""))
        } catch {
            return OperationPreview(source: assessment.displayName, blockers: [.core("\(error)")])
        }
    }

    // MARK: - The Run sheet's Destination

    /// The standard folder of `vault` for `kind` (`VaultLayout`); nil for a kind without one or a vault not mounted.
    static func defaultFolder(_ kind: OperationKind, _ vault: VaultVolumeCheck?) -> String? {
        guard let purpose = kind.layoutPurpose, let vault else { return nil }
        return VaultLayout.path(purpose, in: vault)
    }

    /// The vault's standard folder into `inputs`, with the vault directory it belongs to (I1: only such a folder may be
    /// created by the run); nil clears both.
    static func applyStandardFolder(_ kind: OperationKind, _ vault: VaultVolumeCheck?, to inputs: inout OperationInputs) {
        inputs.folder = defaultFolder(kind, vault)
        inputs.folderIsCustom = false
        inputs.standardFolderOf =
            inputs.folder == nil ? nil : vault.flatMap { v in v.currentMountPoint.map { v.volume.vaultDirectory(atMountPoint: $0) } }
    }

    /// A vault chosen in the Destination picker: the vault, and for a folder kind its standard folder (brief §6). Nil
    /// clears both.
    func chooseDestination(vaultUUID: String?) {
        guard let s = operationSheet, s.phase == .review else { return }
        let vault = usableVaults.first { $0.volume.volumeUUID == vaultUUID }
        updateOperationInputs {
            $0.vaultUUID = vault?.volume.volumeUUID
            if s.kind.needsFolder { Self.applyStandardFolder(s.kind, vault, to: &$0) }
        }
    }

    // MARK: - Ownership (d): nothing runs

    /// Shows the volume in Finder, where **File ▸ Get Info** has "Ignore ownership on this volume".
    func showVolumeForOwnership(_ mountPoint: String) { environment.reveal([mountPoint]) }

    /// Copies `sudo diskutil enableOwnership <volume>` for Terminal: the app never asks for a password.
    func copyOwnershipCommand(_ mountPoint: String) { environment.copy(DiskPreparation.enableOwnershipCommand(mountPoint: mountPoint)) }

    /// **Copy Command** in the preparation review: the exact command the confirmation runs.
    func copyPreparationCommand() {
        guard let plan = pendingDiskPlan else { return }
        environment.copy(plan.command)
    }

    /// The Drives screen's buttons (`ExternalDriveActions`).
    var externalDriveActions: ExternalDriveActions {
        ExternalDriveActions(
            prepare: { [weak self] a, o in self?.openPreparation(a, option: o) }, useDrive: { [weak self] in self?.openUseDrive($0) },
            showInFinder: { [weak self] in self?.showVolumeForOwnership($0) }, copyOwnershipCommand: { [weak self] in self?.copyOwnershipCommand($0) })
    }

    // MARK: - The form

    /// A change in the volume form: stored, and planned again.
    func updateVolumeConfiguration(_ change: (inout VolumeConfiguration) -> Void) {
        guard operationSheet?.phase == .review else { return }
        operationSheet?.previewedPlan = nil
        updateOperationInputs { change(&$0.volume) }
    }

    /// H1: the plan a refresh re-planned is the same disk and the same target as the one previewed.
    static func samePreview(_ previewed: DiskPreparationPlan, _ now: DiskPreparationPlan) -> Bool {
        previewed.identity == now.identity && previewed.action == now.action && previewed.target == now.target
            && previewed.targetUUID == now.targetUUID && previewed.targetName == now.targetName
            && previewed.confirmationName == now.confirmationName
    }

    /// H1, the drive kinds' review: plan again, clear what was typed, and keep the plan the user previewed — or block the
    /// sheet for good when the disk or the target is not the one previewed.
    func previewDriveOperation() {
        guard var s = operationSheet, s.phase == .review, s.kind.isDriveKind else { return }
        var preview = Self.drivePreview(s.kind, s.inputs, snapshot: driveSnapshot, vaults: vaultChecks)
        s.confirmationText = ""
        if case .diskPreparation(let plan, _)? = preview.prepared {
            if s.diskChanged || s.previewedPlan.map({ !Self.samePreview($0, plan) }) == true {
                s.diskChanged = true
                preview = OperationPreview(source: preview.source, blockers: [.diskChanged])
            } else if let previewed = s.previewedPlan {
                preview.prepared = .diskPreparation(previewed, confirmedName: "")
            } else {
                s.previewedPlan = plan
            }
        } else if s.diskChanged || (s.previewedPlan != nil && preview.blockers.contains(.driveGone)) {
            // N4: the previewed drive went away. Whatever appears under its id later is not what was previewed: sticky.
            s.diskChanged = true
            preview = OperationPreview(source: preview.source, blockers: [.diskChanged])
        }
        s.preview = preview
        s.isPreviewing = false
        operationSheet = s
    }

    /// What the erase confirmation adds when the disk can be told apart only by media name and size (M1).
    var previewedDiskIsIndistinguishable: Bool {
        guard let plan = pendingDiskPlan, plan.action.erases else { return false }
        return !plan.identity.isDistinguishable
    }

    /// I2: the registration succeeded but the standard folders were not created; the reason, with `OwnershipAdvice`.
    var registrationFoldersError: String? {
        guard case .driveRegistered(let outcome)? = operationSheet?.result else { return nil }
        return outcome.foldersError
    }
}
