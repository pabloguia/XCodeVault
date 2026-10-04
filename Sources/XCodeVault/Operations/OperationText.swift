import Foundation
import XCodeVaultCore

/// The Run sheet's words (R3). Literal keys, so `scripts/l10n.sh check` sees each one. Commands, paths, log lines and
/// Core's prose are never translated.
enum OperationText {
    /// The review's title: a question naming the object (HIG review §4).
    static func title(_ kind: OperationKind) -> String {
        switch kind {
        case .externalizeArchives: L10n.tr("app.run.title.externalizeArchives")
        case .offloadRuntime: L10n.tr("app.run.title.offloadRuntime")
        case .setDerivedData: L10n.tr("app.run.title.setDerivedData")
        case .setArchives: L10n.tr("app.run.title.setArchives")
        case .exportRuntime: L10n.tr("app.run.title.exportRuntime")
        case .deleteRuntime: L10n.tr("app.run.title.deleteRuntime")
        case .addVolume: L10n.tr("app.run.title.addVolume")
        case .addPartition: L10n.tr("app.run.title.addPartition")
        case .eraseVolume: L10n.tr("app.run.title.eraseVolume")
        case .eraseDisk: L10n.tr("app.run.title.eraseDisk")
        case .useDrive: L10n.tr("app.run.title.useDrive")
        }
    }

    /// What undoing it costs, in one line. For a folder change, `current` is the folder Xcode uses now, which **Undo**
    /// puts back; nil means its default (review L4).
    static func undo(_ kind: OperationKind, current: String? = nil) -> String {
        switch kind {
        case .externalizeArchives: L10n.tr("app.run.undo.externalizeArchives")
        case .offloadRuntime: L10n.tr("app.run.undo.offloadRuntime")
        case .setDerivedData, .setArchives: current.map { L10n.tr("app.run.undo.locationRestore", $0) } ?? L10n.tr("app.run.undo.location")
        case .exportRuntime: L10n.tr("app.run.undo.exportRuntime")
        case .deleteRuntime: L10n.tr("app.run.undo.deleteRuntime")
        case .addVolume: L10n.tr("app.run.undo.addVolume")
        case .addPartition: L10n.tr("app.run.undo.addPartition")
        case .eraseVolume, .eraseDisk: L10n.tr("app.run.undo.erase")
        case .useDrive: L10n.tr("app.run.undo.useDrive")
        }
    }

    static func stage(_ stage: OperationStage) -> String {
        switch stage {
        case .planning: L10n.tr("app.run.stage.planning")
        case .copying: L10n.tr("app.run.stage.copying")
        case .verifying: L10n.tr("app.run.stage.verifying")
        case .removing: L10n.tr("app.run.stage.removing")
        case .deleting: L10n.tr("app.run.stage.deleting")
        case .exporting: L10n.tr("app.run.stage.exporting")
        case .applying: L10n.tr("app.run.stage.applying")
        case .preparing: L10n.tr("app.run.stage.preparing")
        case .done: L10n.tr("app.run.stage.done")
        case .failed: L10n.tr("app.run.stage.failed")
        }
    }

    /// The failure's title: what did not happen (review M8).
    static func failedTitle(_ kind: OperationKind) -> String {
        switch kind {
        case .externalizeArchives: L10n.tr("app.run.failed.title.externalizeArchives")
        case .offloadRuntime: L10n.tr("app.run.failed.title.offloadRuntime")
        case .setDerivedData: L10n.tr("app.run.failed.title.setDerivedData")
        case .setArchives: L10n.tr("app.run.failed.title.setArchives")
        case .exportRuntime: L10n.tr("app.run.failed.title.exportRuntime")
        case .deleteRuntime: L10n.tr("app.run.failed.title.deleteRuntime")
        case .addVolume: L10n.tr("app.run.failed.title.addVolume")
        case .addPartition: L10n.tr("app.run.failed.title.addPartition")
        case .eraseVolume: L10n.tr("app.run.failed.title.eraseVolume")
        case .eraseDisk: L10n.tr("app.run.failed.title.eraseDisk")
        case .useDrive: L10n.tr("app.run.failed.title.useDrive")
        }
    }

    /// **Undo**'s title: what it puts back (review L4).
    static func undoAction(restoring previous: String?) -> String {
        previous.map { L10n.tr("app.run.undoAction.restore", $0) } ?? L10n.tr("app.run.undoAction.reset")
    }

    /// After **Undo**.
    static func undone(restored previous: String?) -> String {
        previous.map { L10n.tr("app.run.undone.restored", $0) } ?? L10n.tr("app.run.undone")
    }

    /// The success line for a result.
    static func done(_ result: OperationResult) -> String {
        switch result {
        case .copied(let o) where o.sourceRemoved: L10n.tr("app.run.done.removed")
        case .copied: L10n.tr("app.run.done.copied")
        case .locationApplied: L10n.tr("app.run.done.location")
        case .offloaded: L10n.tr("app.run.done.offloaded")
        case .exported: L10n.tr("app.run.done.exported")
        case .runtimeDeleted: L10n.tr("app.run.done.deleted")
        case .drivePrepared(let plan) where plan.action.erases: L10n.tr("app.run.done.erased", plan.configuration.name)
        case .drivePrepared(let plan): L10n.tr("app.run.done.volumeAdded", plan.configuration.name)
        case .driveRegistered(let o) where !o.isComplete: L10n.tr("app.run.done.registeredPartial")
        case .driveRegistered: L10n.tr("app.run.done.registered")
        }
    }

    /// A runtime as the picker and the button name it: platform and version, never its UUID alone.
    static func runtime(_ r: SimulatorRuntime) -> String {
        let platform = OperationKind.exportPlatform(for: r) ?? r.platformName
        return [platform, r.version, r.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
}

extension AppModel {
    /// The confirm button's title: the exact action, with its size and target (R3 §3).
    var operationConfirmTitle: String {
        guard let s = operationSheet else { return "" }
        // No size or names until the review has them (review M10): VoiceOver reads the disabled button too.
        guard !s.isPreviewing, s.preview?.prepared != nil else { return L10n.tr("app.run.confirm.pending") }
        let p = s.preview
        let size = ByteCount.format(p?.bytes ?? 0)
        let folder = s.inputs.folder ?? ""
        let runtime = runtimesForPicker.first { $0.identifier == s.inputs.runtimeID }.map(OperationText.runtime) ?? ""
        switch s.kind {
        case .externalizeArchives:
            let vault = usableVaults.first { $0.volume.volumeUUID == s.inputs.vaultUUID }?.volume.volumeName ?? ""
            return L10n.tr("app.run.confirm.externalizeArchives", size, vault)
        case .offloadRuntime: return L10n.tr("app.run.confirm.offloadRuntime", runtime, size)
        case .setDerivedData: return L10n.tr("app.run.confirm.setDerivedData", folder)
        case .setArchives: return L10n.tr("app.run.confirm.setArchives", folder)
        case .exportRuntime: return L10n.tr("app.run.confirm.exportRuntime", s.inputs.platform, folder)
        case .deleteRuntime: return L10n.tr("app.run.confirm.deleteRuntime", runtime, size)
        case .addVolume: return L10n.tr("app.run.confirm.addVolume", s.inputs.volume.name)
        case .addPartition: return L10n.tr("app.run.confirm.addPartition", s.inputs.volume.name)
        case .eraseVolume: return L10n.tr("app.run.confirm.eraseVolume", pendingDiskPlan?.confirmationName ?? "")
        case .eraseDisk: return L10n.tr("app.run.confirm.eraseDisk", pendingDiskPlan?.confirmationName ?? "")
        case .useDrive:
            // The volume the review registers: the drive's qualifying one, or the one a preparation just made (R7-A).
            let volume = driveSnapshot?.volumes.first { $0.volumeUUID != nil && $0.volumeUUID == s.inputs.driveVolumeUUID }
            return L10n.tr("app.run.confirm.useDrive", volume?.volumeName ?? s.drive?.registrable?.volumeName ?? "")
        }
    }

    /// The progress line under the bar: copied of total while copying. An export shows only its elapsed time: whether
    /// its folder grows during the download is unmeasured (review M4).
    var operationProgressText: String? {
        guard let s = operationSheet, s.stage == .copying, case .migration(let plan)? = s.preview?.prepared, let done = s.progressBytes else { return nil }
        return L10n.tr("app.run.progress.copied", ByteCount.format(min(done, plan.sourceBytes)), ByteCount.format(plan.sourceBytes))
    }
}

/// The Drives screen's and the preparation sheet's words (R6). Literal keys; commands, names and paths never translated.
enum DriveText {
    static func verdict(_ v: DriveVerdict) -> String {
        switch v {
        case .ready: L10n.tr("app.drives.verdict.ready")
        case .canBeUsed: L10n.tr("app.drives.verdict.canBeUsed")
        case .needsPreparation: L10n.tr("app.drives.verdict.needsPreparation")
        case .cannotBeUsed: L10n.tr("app.drives.verdict.cannotBeUsed")
        }
    }

    /// The verdict's symbol, always beside its words (never color alone).
    static func symbol(_ v: DriveVerdict) -> String {
        switch v {
        case .ready: "checkmark.circle.fill"
        case .canBeUsed: "checkmark.circle"
        case .needsPreparation: "wrench.and.screwdriver"
        case .cannotBeUsed: "minus.circle"
        }
    }

    static func refusal(_ r: DiskRefusal) -> String {
        switch r {
        case .internalDisk: L10n.tr("app.drives.refusal.internalDisk")
        case .bootDisk: L10n.tr("app.drives.refusal.bootDisk")
        case .diskImage: L10n.tr("app.drives.refusal.diskImage")
        case .holdsVault: L10n.tr("app.drives.refusal.holdsVault")
        case .timeMachine: L10n.tr("app.drives.refusal.timeMachine")
        case .readOnlyMedia: L10n.tr("app.drives.refusal.readOnlyMedia")
        case .mightBeTimeMachine: L10n.tr("app.drives.refusal.mightBeTimeMachine")
        }
    }

    /// An option as its button and the sheet's picker name it.
    static func option(_ o: PreparationOption) -> String {
        switch o {
        case .addVolume: L10n.tr("app.prep.option.addVolume")
        case .addPartition(_, let free): L10n.tr("app.prep.option.addPartition", ByteCount.format(free))
        case .eraseVolume(let id, let name): L10n.tr("app.prep.option.eraseVolume", name.isEmpty ? id : name)
        case .eraseDisk: L10n.tr("app.prep.option.eraseDisk")
        case .enableOwnership: L10n.tr("app.prep.option.enableOwnership")
        }
    }

    /// A Drives button: the option, "recommended" when it is, and the ellipsis of an action that opens a sheet.
    static func optionButton(_ o: PreparationOption, recommended: Bool) -> String {
        option(o) + (recommended ? " — " + L10n.tr("app.prep.recommended") : "") + "…"
    }

    /// What a drive's button beside or under the Destination picker does, as its title (R7-A): **Use This Drive…**, or the
    /// preparation it opens — "Add a Case-insensitive Volume…" — never a bare "Prepare…". Nil when there is nothing to do.
    static func prepareTitle(_ action: DriveAssessment.PrepareAction) -> String? {
        switch action {
        case .useDrive: L10n.tr("app.drives.useDrive")
        case .prepare(.addVolume): L10n.tr("app.drives.fix.addVolume")
        case .prepare(.addPartition): L10n.tr("app.drives.fix.addPartition")
        case .prepare(.eraseVolume): L10n.tr("app.drives.fix.eraseVolume")
        case .prepare(.eraseDisk): L10n.tr("app.drives.fix.eraseDisk")
        case .prepare(.enableOwnership), .nothing: nil
        }
    }

    /// A volume an erase destroys, with what it holds when known.
    static func destroyed(_ v: DestroyedVolume) -> String {
        let name = v.name.isEmpty ? v.id : v.name
        return v.usedBytes.map { L10n.tr("app.prep.destroys.row", name, ByteCount.format($0)) } ?? name
    }

    /// The drive's facts in one line: media, bus, size.
    static func facts(_ a: DriveAssessment) -> String {
        [a.disk.mediaName, a.disk.busProtocol, ByteCount.format(a.disk.sizeBytes)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
