import Foundation
import XCodeVaultCore

/// What **Run…** does for a plan row (R3, ADR-0011). Six (bucket, category) pairs and no others: simulator devices and
/// the `clean` rows keep **Copy command** only.
enum OperationKind: String, Sendable, Equatable, CaseIterable {
    case externalizeArchives, offloadRuntime, setDerivedData, setArchives, exportRuntime, deleteRuntime

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
    var deletesData: Bool { self == .offloadRuntime || self == .deleteRuntime }

    /// The stage the sheet shows from the moment the operation starts.
    var runningStage: OperationStage {
        switch self {
        case .externalizeArchives: .copying
        case .offloadRuntime, .deleteRuntime: .deleting
        case .setDerivedData, .setArchives: .applying
        case .exportRuntime: .exporting
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
}

/// Why **Run** is disabled. The app's own reasons are localized; Core's are its English prose, shown as given.
enum OperationBlocker: Sendable, Equatable {
    case chooseVault, chooseFolder, chooseRuntime, acknowledgeTests
    /// Simulator work (a simulator, `simctl`, a test run) is running: offload and delete wait for it (review L3).
    case simulatorWorkRunning
    case core(String)
}

/// Exactly what the confirmation runs: the plan the preview made, so the run re-derives nothing the user did not see.
enum PreparedOperation: Sendable {
    case migration(MigrationPlan)
    case offload(RuntimeOperations.OffloadPlan, XcodeInstallation, HostEnvironment)
    case location(XcodeLocations.Change, acknowledgeTests: Bool)
    case export(RuntimeOperations.ExportRequest, XcodeInstallation, HostEnvironment)
    case deleteRuntime(identifier: String, XcodeInstallation, HostEnvironment)

    /// The journal id the operation will use, when it is known before it runs (a migration's plan carries it): the
    /// interrupted banner must not list the operation that is running right now.
    var journalID: String? {
        if case .migration(let plan) = self { return plan.operationID }
        return nil
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
    let row: SavingsPlanRow
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

    init(row: SavingsPlanRow, kind: OperationKind, inputs: OperationInputs) {
        self.row = row
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
