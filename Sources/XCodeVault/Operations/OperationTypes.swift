import Foundation
import XCodeVaultCore

/// What **Run…** does for a plan row (R3, ADR-0011). Six (bucket, category) pairs and no others: simulator devices and
/// the `clean` rows keep **Copy command** only.
enum OperationKind: String, Sendable, Equatable, CaseIterable {
    case externalizeArchives, offloadRuntime, setDerivedData, setArchives, exportRuntime, deleteRuntime
    /// R6 (ADR-0012): preparing an external drive — EXPERIMENTAL (rule 10) — and **Use This Drive**.
    case addVolume, addPartition, eraseVolume, eraseDisk, useDrive

    /// The drive kinds: planned by `AppModel.drivePreview` from the Drives snapshot, never by `OperationServices.preview`.
    var isDriveKind: Bool { [.addVolume, .addPartition, .eraseVolume, .eraseDisk, .useDrive].contains(self) }
    /// The Core action a preparation kind runs.
    var preparationAction: DiskPreparationAction? {
        switch self {
        case .addVolume: .addVolume
        case .addPartition: .addPartition
        case .eraseVolume: .eraseVolume
        case .eraseDisk: .eraseDisk
        default: nil
        }
    }

    /// The kind that runs `option`; nil for ownership, which the app runs nothing for.
    static func forOption(_ option: PreparationOption) -> OperationKind? {
        switch option {
        case .addVolume: .addVolume
        case .addPartition: .addPartition
        case .eraseVolume: .eraseVolume
        case .eraseDisk: .eraseDisk
        case .enableOwnership: nil
        }
    }

    /// Every drive preparation is experimental (rule 10, H17 pending on physical disks): the sheet's badge.
    var isExperimental: Bool { preparationAction != nil }

    /// Whether the sheet shows the **Destination** picker (R6): the kinds that write to a vault or a folder.
    var usesDestination: Bool { needsVault || needsFolder }

    /// The standard vault folder this kind's folder defaults to (`VaultLayout`). Externalize Archives keeps the migration
    /// engine's own path under the vault directory.
    var layoutPurpose: VaultLayout.Purpose? {
        switch self {
        case .setDerivedData: .derivedData
        case .setArchives: .archives
        case .offloadRuntime, .exportRuntime: .runtimes
        default: nil
        }
    }

    /// The row's operation, decided by its bucket and category; nil keeps the row copy-only.
    static func forRow(_ row: SavingsPlanRow) -> OperationKind? {
        switch (row.option.bucket, row.categoryID) {
        case (.parkExternally, "archives"): .externalizeArchives
        case (.parkExternally, "simulatorRuntimeAssets"): .offloadRuntime
        case (.runFromExternal, "derivedData"): .setDerivedData
        case (.runFromExternal, "archives"): .setArchives
        case (.runFromExternal, "runtimeLibrary"): .exportRuntime
        case (.deleteAndRegenerate, "simulatorRuntimeAssets"): .deleteRuntime
        default: nil
        }
    }

    var needsVault: Bool { self == .externalizeArchives }
    var needsFolder: Bool { [.offloadRuntime, .setDerivedData, .setArchives, .exportRuntime].contains(self) }
    var needsRuntime: Bool { [.offloadRuntime, .deleteRuntime].contains(self) }
    var needsPlatform: Bool { self == .exportRuntime }
    /// DerivedData on an external volume breaks `xcodebuild test` (E2): the CLI's `--i-understand-tests-may-fail`.
    var asksTestsAcknowledgement: Bool { self == .setDerivedData }
    /// Deletes data on this Mac when it runs: the confirm button is destructive and not the default (HIG).
    var deletesData: Bool { [.offloadRuntime, .deleteRuntime, .eraseVolume, .eraseDisk].contains(self) }
    /// Whether **Stop and Quit** may terminate this operation's command: the one rule behind `AppModel.quitChoice` and
    /// `LiveOperations.stoppableChildren`. A copy (`ditto`) and an export (`xcodebuild`) are never stopped, and neither is
    /// an offload: its `simctl` only asks CoreSimulatorService to delete, so a stopped client can leave the runtime gone while
    /// the journal says `failed` — which Doctor reads as "the delete did not happen", losing the offload's way back.
    /// A drive preparation (R6) is never stopped: `diskutil` part-way through an erase or a partition change leaves the
    /// disk in a state nobody chose.
    var canBeStopped: Bool { [.deleteRuntime, .setDerivedData, .setArchives].contains(self) }

    /// The stage the sheet shows from the moment the operation starts.
    var runningStage: OperationStage {
        switch self {
        case .externalizeArchives: .copying
        case .offloadRuntime, .deleteRuntime: .deleting
        case .setDerivedData, .setArchives: .applying
        case .exportRuntime: .exporting
        case .addVolume, .addPartition, .eraseVolume, .eraseDisk: .preparing
        case .useDrive: .applying
        }
    }

    /// The Locations key a location operation writes.
    var locationKey: XcodeLocations.Key? {
        switch self {
        case .setDerivedData: .derivedData
        case .setArchives: .archives
        default: nil
        }
    }

    /// The platforms `xcodebuild -downloadPlatform` takes (`RuntimeOperations.preflightExport`).
    static let exportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]

    /// The `-downloadPlatform` name for an installed runtime, read from its identifier's `.SimRuntime.<platform>-`
    /// segment; CoreSimulator calls visionOS `xrOS` there. Nil when the identifier has no such segment.
    static func exportPlatform(for runtime: SimulatorRuntime) -> String? {
        guard let rid = runtime.runtimeIdentifier, let r = rid.range(of: ".SimRuntime.") else { return nil }
        let rest = rid[r.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let name = String(rest[..<dash])
        let platform = name == "xrOS" ? "visionOS" : name
        return exportPlatforms.contains(platform) ? platform : nil
    }
}

/// What the sheet's controls hold: the CLI's flags as choices.
struct OperationInputs: Sendable, Equatable {
    /// `--vault`: a registered vault's volume UUID.
    var vaultUUID: String?
    /// `<dir>`, `--library`, `--to`: always chosen in a folder panel, never typed.
    var folder: String?
    /// `<identifier>`: an installed runtime's image UUID.
    var runtimeID: String?
    var platform = "iOS"
    /// `--build-version`: set only by **Export installer first**, so the export fetches the installed runtime's version.
    var buildVersion: String?
    /// `--i-understand-tests-may-fail`.
    var acknowledgeTests = false
    /// True when the folder was chosen with **Choose Another Folder…** rather than from a vault's standard layout (R6).
    var folderIsCustom = false
    /// I1: set when `folder` is a usable vault's standard folder (`VaultLayout`) — the vault directory it belongs to. Only
    /// then may the run create the folder when it is missing; a folder chosen by hand never is.
    var standardFolderOf: String?
    /// R6: the whole disk a preparation targets, and which option.
    var diskID: String?
    var driveOption: PreparationOption?
    /// R6: the new volume's settings (name, case sensitivity, size limit).
    var volume = VolumeConfiguration()
    /// R6, **Use This Drive**: the volume to register, by UUID.
    var driveVolumeUUID: String?
}

/// Why **Run** is disabled. The app's own reasons are localized; Core's are its English prose, shown as given.
enum OperationBlocker: Sendable, Equatable {
    case chooseVault, chooseFolder, chooseRuntime, acknowledgeTests
    /// Simulator work (a simulator, `simctl`, a test run) is running: offload and delete wait for it (review L3).
    case simulatorWorkRunning
    /// R6: the drive is no longer connected, or the disks could not be read.
    case driveGone
    /// R6: an erase waits for the exact name to be typed.
    case typeName(String)
    /// R6 (H1): the disk at the previewed device id is not the disk that was previewed. Sticky until the sheet closes.
    case diskChanged
    case core(String)
}

/// Exactly what the confirmation runs: the plan the preview made, so the run re-derives nothing the user did not see.
enum PreparedOperation: Sendable {
    case migration(MigrationPlan)
    case offload(RuntimeOperations.OffloadPlan, XcodeInstallation, HostEnvironment)
    case location(XcodeLocations.Change, acknowledgeTests: Bool)
    case export(RuntimeOperations.ExportRequest, XcodeInstallation, HostEnvironment)
    case deleteRuntime(identifier: String, XcodeInstallation, HostEnvironment)
    /// R6: one `diskutil` preparation; `confirmedName` is what the user typed (Core refuses an erase without the exact
    /// name, whatever this layer decided).
    case diskPreparation(DiskPreparationPlan, confirmedName: String)
    /// R6: **Use This Drive** on a mounted volume.
    case useDrive(Volume)
    /// R6 (I1): first create the vault's missing standard `folder` (only that, inside `vaultDirectory`), then run `then`.
    /// N1: `vaultUUID` is the vault whose identity the run verifies at the mount point before the mkdir.
    indirect case creatingFolder(folder: String, vaultDirectory: String, vaultUUID: String, then: PreparedOperation)

    /// The kind this prepared operation runs as.
    var kind: OperationKind {
        switch self {
        case .migration: .externalizeArchives
        case .offload: .offloadRuntime
        case .location(let change, _): change.key == .archives ? .setArchives : .setDerivedData
        case .export: .exportRuntime
        case .deleteRuntime: .deleteRuntime
        case .diskPreparation(let plan, _):
            switch plan.action {
            case .addVolume: .addVolume
            case .addPartition: .addPartition
            case .eraseVolume: .eraseVolume
            case .eraseDisk: .eraseDisk
            }
        case .useDrive: .useDrive
        case .creatingFolder(_, _, _, let then): then.kind
        }
    }

    /// The journal id the operation will use, when it is known before it runs (a migration's plan carries it): the
    /// interrupted banner must not list the operation that is running right now.
    var journalID: String? {
        switch self {
        case .migration(let plan): return plan.operationID
        case .creatingFolder(_, _, _, let then): return then.journalID
        default: return nil
        }
    }
}

/// The preview step: what will happen, and what stops it.
struct OperationPreview: Sendable {
    var source: String?
    var destination: String?
    var bytes: UInt64?
    /// Core's warnings, English prose, shown as given.
    var warnings: [String] = []
    var blockers: [OperationBlocker] = []
    var prepared: PreparedOperation?
    /// Offload only: the library holds no installer for this runtime, so the sheet offers **Export installer first**.
    var installerMissing = false
    /// I1: the vault's standard folder does not exist yet; the run creates it first ("Will create folder …").
    var willCreateFolder: String?
}

/// How a run ended well.
enum OperationResult: Sendable {
    case copied(MigrationOutcome)
    /// `previous`: the folder Xcode used before, read just before the change (the value the journal records as
    /// `previous`); nil when it used its default. **Undo** puts it back.
    case locationApplied(XcodeLocations.Key, previous: String?)
    case offloaded
    case exported
    case runtimeDeleted
    /// R6: the drive was prepared; the new or erased volume is named in the plan.
    case drivePrepared(DiskPreparationPlan)
    /// R6: **Use This Drive** registered the vault and made its standard folders.
    case driveRegistered(DriveRegistration.Outcome)
}

/// The Run sheet's whole state (R3). Presented while `AppModel.operationSheet` is non-nil.
struct OperationSheetState: Sendable {
    /// Where the sheet is. What may follow a success lives inside `.succeeded`, so a second step without a success
    /// cannot be represented (review M11).
    enum Phase: Sendable, Equatable {
        case review
        case running
        case succeeded(SecondStep)
        case failed(String)
    }

    /// What may follow a successful run (rule 4: removing the original is its own step, offered only after a verify).
    enum SecondStep: Sendable, Equatable {
        case none
        case removeOriginal, removingOriginal, originalRemoved
        case removeFailed(String)
        case undo, undoing, undone
        case undoFailed(String)
    }

    let id = UUID()
    /// The plan row **Run…** came from; nil for a drive operation (R6).
    let row: SavingsPlanRow?
    /// R6: the drive a preparation or **Use This Drive** is for, as assessed when the sheet opened.
    var drive: DriveAssessment?
    /// R6: what the user typed to confirm an erase. Not an input: typing does not plan again. Cleared on every re-plan.
    var confirmationText = ""
    /// R6 (H1): the plan the user previewed. A re-plan after a refresh never replaces it: if the disk or the target is no
    /// longer the same, the sheet is blocked (`diskChanged`). Reset only when the user changes the option or the form.
    var previewedPlan: DiskPreparationPlan?
    /// R6 (H1): the disk changed under the open sheet. Sticky: "Close this and preview again."
    var diskChanged = false

    /// The experimental badge in the title (rule 10): the plan row's strategy, or any drive preparation.
    var showsExperimentalBadge: Bool { row?.option.isExperimental == true || kind.isExperimental }
    var kind: OperationKind
    var inputs: OperationInputs
    var preview: OperationPreview?
    var isPreviewing = false
    var phase: Phase = .review
    var stage: OperationStage = .planning
    var log = OperationLog()
    var startedAt: Date?
    var finishedAt: Date?
    /// The last measure of the vault copy while copying.
    var progressBytes: UInt64?
    var result: OperationResult?
    /// The step after a success; `.none` in every other phase, and it can be set only while succeeded.
    var secondStep: SecondStep {
        get {
            if case .succeeded(let step) = phase { return step }
            return .none
        }
        set { if case .succeeded = phase { phase = .succeeded(newValue) } }
    }
    var isSucceeded: Bool {
        if case .succeeded = phase { return true }
        return false
    }
    /// The full log's file, kept after the operation ends so the sheet can still name it (review I5).
    var logFileURL: URL?
    /// "I confirm deleting non-regenerable data (Archives)": unchecked until the user checks it.
    var confirmRemoval = false
    /// Set while an export runs on offload's behalf: offload's choices, restored when the export succeeds.
    var offloadToReturnTo: OperationInputs?
    /// True on offload's review after an export it asked for succeeded.
    var exportedFirst = false
    /// The journal id of the running operation, when known (`PreparedOperation.journalID`).
    var runningJournalID: String?

    init(row: SavingsPlanRow?, kind: OperationKind, inputs: OperationInputs, drive: DriveAssessment? = nil) {
        self.row = row
        self.drive = drive
        self.kind = kind
        self.inputs = inputs
    }
}

/// One line of the interrupted-migration banner: the operation and the exact commands that recover it.
struct InterruptedMigration: Sendable, Equatable, Identifiable {
    let id: String
    let summary: String
    let commands: [String]
}
