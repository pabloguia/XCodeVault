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
        }
    }

    /// The progress line under the bar: copied of total while copying. An export shows only its elapsed time: whether
    /// its folder grows during the download is unmeasured (review M4).
    var operationProgressText: String? {
        guard let s = operationSheet, s.stage == .copying, case .migration(let plan)? = s.preview?.prepared, let done = s.progressBytes else { return nil }
        return L10n.tr("app.run.progress.copied", ByteCount.format(min(done, plan.sourceBytes)), ByteCount.format(plan.sourceBytes))
    }
}
