import AppKit
import Foundation
import XCodeVaultCore

/// Everything the Run sheet reaches outside the process (R3), as closures: `.live` calls Core, a test supplies fakes that
/// emit scripted lines. A test never copies, moves or deletes data, never runs ditto, simctl, xcodebuild or defaults,
/// and never opens a panel. `.inert`, the default, refuses everything.
struct OperationServices: Sendable {
    /// The review step: Core's preflight or plan for `kind` with `inputs`. Called off the main actor, only once the
    /// inputs are complete (`AppModel.inputBlockers`).
    var preview: @Sendable (OperationKind, OperationInputs) -> OperationPreview
    /// Runs what the preview prepared, every command's lines going to the observer, every command registered in the
    /// `ChildProcesses` so quitting can stop it.
    var run: @Sendable (PreparedOperation, ChildProcesses, @escaping LogObserver) throws -> OperationResult
    /// The second step of an externalization: `MigrationEngine.removeSource`, which re-verifies first.
    var removeSource: @Sendable (MigrationOutcome, _ confirmNonRegenerable: Bool, @escaping LogObserver) throws -> MigrationOutcome
    /// **Undo** after a Locations change: the previous folder put back when there was one, else Core's reset path
    /// (`xcodevaultctl locations reset-*`).
    var restoreLocation: @Sendable (XcodeLocations.Key, _ previous: String?, ChildProcesses, @escaping LogObserver) throws -> Void
    /// Allocated bytes under a path, for the progress bar; nil when it cannot be measured.
    var measure: @Sendable (String) -> UInt64?
    /// The folder panel, opened at `startingAt` as a sheet on the key window; nil when the user cancels.
    var chooseFolder: @MainActor @Sendable (_ startingAt: String?) async -> String?
    /// How often the progress bar measures.
    var pollInterval: Duration = .seconds(1)
    /// Keeps the full log of an operation (the sheet keeps the newest lines only); nil keeps none.
    var logFile: (@Sendable (_ name: String) -> OperationLogFile?)?
    /// An operation finished while the app was not frontmost: the Dock icon asks for attention (HIG review §4).
    var notifyFinished: @MainActor @Sendable () -> Void = {}

    static let inert = OperationServices(
        preview: { _, _ in OperationPreview(blockers: [.core("No operations in this environment.")]) },
        run: { _, _, _ in throw RuntimeOperationError("No operations in this environment.") },
        removeSource: { _, _, _ in throw RuntimeOperationError("No operations in this environment.") },
        restoreLocation: { _, _, _, _ in throw RuntimeOperationError("No operations in this environment.") },
        measure: { _ in nil },
        chooseFolder: { _ in nil },
        logFile: nil)

    static let live = OperationServices(
        preview: { LiveOperations.preview($0, $1) },
        run: { try LiveOperations.run($0, children: $1, observer: $2) },
        removeSource: { outcome, confirm, observer in
            try MigrationEngine(runner: StreamingCommandRunner(observer: observer)).removeSource(outcome, confirmNonRegenerable: confirm)
        },
        restoreLocation: { try LiveOperations.restoreLocation($0, previous: $1, children: $2, observer: $3) },
        measure: { DiskUsage.measure($0)?.allocatedBytes },
        chooseFolder: { start in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if let start { panel.directoryURL = URL(fileURLWithPath: start) }
            // A sheet on the Run sheet's window (review M13); app-modal only when there is no window to attach to.
            guard let window = NSApp.keyWindow else { return panel.runModal() == .OK ? panel.url?.path : nil }
            let response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            return response == .OK ? panel.url?.path : nil
        },
        logFile: { OperationLogFile.create(name: $0) },
        notifyFinished: {
            guard !NSApp.isActive else { return }
            NSApp.requestUserAttention(.informationalRequest)
        })
}

/// An operation's whole log, appended line by line to a file in the temporary folder.
final class OperationLogFile: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    private init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }

    static func create(
        name: String, in dir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("XCodeVault-logs", isDirectory: true)
    ) -> OperationLogFile? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return OperationLogFile(url: url, handle: handle)
    }

    func append(_ line: LogLine) {
        lock.withLock { try? handle.write(contentsOf: Data((line.rendered + "\n").utf8)) }
    }

    deinit { try? handle.close() }
}

/// The live previews and runs: what `xcodevaultctl` does for each command, with the flags replaced by the sheet's choices.
/// The decisions that are not Core's own are the two static functions at the end, which take Core as closures and are
/// tested.
enum LiveOperations {
    static func preview(_ kind: OperationKind, _ inputs: OperationInputs) -> OperationPreview {
        // R6: a folder chosen by hand on a network share is refused before anything else is asked.
        if kind.needsFolder, let folder = inputs.folder, let why = DestinationFolder.networkRefusal(MountStatus.filesystem(containing: folder)) {
            return OperationPreview(destination: folder, blockers: [.core(why)])
        }
        do {
            switch kind {
            case .externalizeArchives: return try externalizePreview(inputs)
            case .offloadRuntime: return try offloadPreview(inputs)
            case .setDerivedData, .setArchives: return locationPreview(kind, inputs)
            case .exportRuntime: return try exportPreview(inputs)
            case .deleteRuntime: return try deletePreview(inputs)
            // Planned by `AppModel.drivePreview` from the Drives snapshot; never asked here.
            case .addVolume, .addPartition, .eraseVolume, .eraseDisk, .useDrive: return OperationPreview(blockers: [.driveGone])
            }
        } catch {
            return OperationPreview(blockers: [.core("\(error)")])
        }
    }

    /// The selected Xcode, and only it (ADR-0009): the same refusal as the CLI's when none is selected.
    static func selectedXcode() throws -> (XcodeInstallation, HostEnvironment) {
        let xcodes = XcodeDiscovery.discover()
        guard let x = xcodes.first(where: \.isSelected) else {
            throw RuntimeOperationError(
                xcodes.isEmpty
                    ? "No Xcode found."
                    : "No Xcode is selected: `xcode-select -p` names none of the Xcodes found. Select one with `sudo xcode-select -s <path to Xcode.app>`.")
        }
        return (x, HostEnvironment.discover())
    }

    static func externalizePreview(_ inputs: OperationInputs) throws -> OperationPreview {
        let categoryID = "archives"
        guard let vault = inputs.vaultUUID, let c = StorageCatalog.category(categoryID) else { return OperationPreview(blockers: [.chooseVault]) }
        guard let source = c.singleStandardPath() else { throw MigrationError("\(c.name) has no single standard path.") }
        let plan = try MigrationEngine().planExternalize(categoryID: categoryID, source: source, vaultRef: vault)
        return OperationPreview(
            source: plan.source, destination: plan.destination, bytes: plan.sourceBytes, warnings: plan.warnings, prepared: .migration(plan))
    }

    static func offloadPreview(_ inputs: OperationInputs) throws -> OperationPreview {
        guard let id = inputs.runtimeID, let library = inputs.folder else { return OperationPreview() }
        let (x, h) = try selectedXcode()
        let runtimes = try SimulatorDiscovery.runtimes(developerDir: x.developerDirectory)
        let ops = RuntimeOperations(xcode: x, host: h)
        let busy = simulatorWorkBlockers(CleanExecutor.simulatorWorkIsRunning())
        do {
            let (plan, warnings) = try ops.preflightOffload(identifier: id, library: library, installedRuntimes: runtimes)
            guard busy.isEmpty else {
                return OperationPreview(
                    source: runtimes.first { $0.identifier == id }?.path, destination: plan.installerPath, bytes: plan.sizeBytes, warnings: warnings,
                    blockers: busy)
            }
            return OperationPreview(
                source: runtimes.first { $0.identifier == id }?.path, destination: plan.installerPath, bytes: plan.sizeBytes, warnings: warnings,
                prepared: .offload(plan, x, h))
        } catch {
            let runtime = runtimes.first { $0.identifier == id }
            return OperationPreview(
                source: runtime?.path, destination: library, bytes: runtime?.sizeBytes, blockers: [.core("\(error)")],
                installerMissing: installerMissing(runtime: runtime, library: try? RuntimeOperations.library(at: library)))
        }
    }

    static func locationPreview(_ kind: OperationKind, _ inputs: OperationInputs) -> OperationPreview {
        guard let key = kind.locationKey, let folder = inputs.folder else { return OperationPreview() }
        let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
        let xcodeRunning = CleanExecutor.xcodeIsRunning()
        let current = XcodeLocations.read()
        let (warnings, blockers) = locationPreflight(acknowledged: inputs.acknowledgeTests) { ack in
            kind == .setDerivedData
                ? try XcodeLocations.preflightDerivedData(path: folder, volumes: volumes, xcodeRunning: xcodeRunning, acknowledgeExternalTests: ack)
                : try XcodeLocations.preflightArchives(path: folder, volumes: volumes, xcodeRunning: xcodeRunning)
        }
        // `source` is nil when Xcode uses its default (`XcodeLocations.read` returns nil for an unset key), so the review's
        // undo line and **Undo**'s title, which reads the same key just before the change, both say "default" (N4).
        return OperationPreview(
            source: key == .derivedData ? current.derivedData : current.archives, destination: folder, warnings: warnings, blockers: blockers,
            prepared: blockers.isEmpty ? .location(XcodeLocations.Change(key: key, newValue: folder), acknowledgeTests: inputs.acknowledgeTests) : nil)
    }

    static func exportPreview(_ inputs: OperationInputs) throws -> OperationPreview {
        guard let folder = inputs.folder else { return OperationPreview() }
        let (x, h) = try selectedXcode()
        let req = RuntimeOperations.ExportRequest(
            platform: inputs.platform, buildVersion: x.capabilities.buildVersion ? inputs.buildVersion : nil, destination: folder)
        let warnings = try RuntimeOperations(xcode: x, host: h).preflightExport(
            req, freeBytesAtDestination: MountStatus.space(at: folder)?.free,
            installedRuntimes: (try? SimulatorDiscovery.runtimes(developerDir: x.developerDirectory)) ?? [])
        return OperationPreview(destination: folder, warnings: warnings, prepared: .export(req, x, h))
    }

    static func deletePreview(_ inputs: OperationInputs) throws -> OperationPreview {
        guard let id = inputs.runtimeID else { return OperationPreview() }
        let (x, h) = try selectedXcode()
        guard x.capabilities.simctlRuntimeDelete else { throw RuntimeOperationError("This Xcode's simctl has no `runtime delete` verb.") }
        let runtime = try SimulatorDiscovery.runtimes(developerDir: x.developerDirectory).first { $0.identifier == id }
        guard let runtime else { throw RuntimeOperationError("No installed runtime with identifier \(id).") }
        let busy = simulatorWorkBlockers(CleanExecutor.simulatorWorkIsRunning())
        return OperationPreview(
            source: runtime.path, bytes: runtime.sizeBytes, blockers: busy, prepared: busy.isEmpty ? .deleteRuntime(identifier: id, x, h) : nil)
    }

    static func run(_ prepared: PreparedOperation, children: ChildProcesses, observer: @escaping LogObserver) throws -> OperationResult {
        let runner = StreamingCommandRunner(observer: observer, children: stoppableChildren(for: prepared, children))
        switch prepared {
        case .migration(let plan):
            return .copied(try MigrationEngine(runner: runner).copyAndVerify(plan))
        case .offload(let plan, let x, let h):
            // Again at the moment of use, like the preview (review L3): the user runs test rigs on these simulators.
            try refuseIfSimulatorWork(CleanExecutor.simulatorWorkIsRunning())
            try RuntimeOperations(runner: runner, xcode: x, host: h).offload(
                plan, confirmedByUser: .explicitUserIntent(recordedAs: "app: Run sheet confirmation"))
            return .offloaded
        case .location(let change, let ack):
            // Again at the moment of use: Xcode may have been opened while the sheet was on screen.
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            let running = CleanExecutor.xcodeIsRunning()
            if change.key == .derivedData {
                _ = try XcodeLocations.preflightDerivedData(path: change.newValue, volumes: volumes, xcodeRunning: running, acknowledgeExternalTests: ack)
            } else {
                _ = try XcodeLocations.preflightArchives(path: change.newValue, volumes: volumes, xcodeRunning: running)
            }
            // The value the journal records as `previous`, read the same way, just before the change: what **Undo** restores.
            let read = try? ProcessCommandRunner().run(Tools.defaults, ["read", XcodeLocations.domain, change.key.defaultsKey])
            let previous = read.flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }.flatMap { $0.isEmpty ? nil : $0 }
            try XcodeLocations.apply(change, runner: runner)
            return .locationApplied(change.key, previous: previous)
        case .export(let req, let x, let h):
            let ops = RuntimeOperations(runner: runner, xcode: x, host: h)
            _ = try ops.preflightExport(req, freeBytesAtDestination: MountStatus.space(at: req.destination)?.free)
            try ops.export(req)
            return .exported
        case .deleteRuntime(let id, let x, let h):
            // The preview's checks again at the moment of use (review L3).
            guard x.capabilities.simctlRuntimeDelete else { throw RuntimeOperationError("This Xcode's simctl has no `runtime delete` verb.") }
            try refuseIfSimulatorWork(CleanExecutor.simulatorWorkIsRunning())
            try RuntimeOperations(runner: runner, xcode: x, host: h).delete(identifier: id)
            return .runtimeDeleted
        case .diskPreparation(let plan, let typed):
            // EXPERIMENTAL (rule 10, H17). Core reads the disks again, re-checks the disk's identity and `DiskSafety`, runs
            // ONE diskutil command with no sudo, and journals it. The registry is read here, at the moment of use: a vault
            // registered since the preview forbids an erase. An unreadable registry refuses (fails closed).
            let outcome = try DiskPreparation.execute(
                plan, confirmedName: typed, runner: runner, journal: Journal(),
                registeredVaultUUIDs: { Set(try VaultRegistry().volumes().map(\.volumeUUID)) }, snapshot: { try DriveSnapshot.read() })
            return .drivePrepared(outcome.plan)
        case .useDrive(let volume):
            observer(LogLine(.command, "register \(volume.mountPoint ?? volume.deviceNode) as a vault"))
            let outcome = try DriveRegistration.useDrive(volume)
            for folder in outcome.folders { observer(LogLine(.stdout, folder)) }
            return .driveRegistered(outcome)
        }
    }

    /// **Undo** (review L4): the previous folder, through the same preflight a change gets, when there was one;
    /// otherwise the CLI's reset — the preflight with no path (it refuses while Xcode runs), then `defaults delete`.
    static func restoreLocation(_ key: XcodeLocations.Key, previous: String?, children: ChildProcesses, observer: @escaping LogObserver) throws {
        let running = CleanExecutor.xcodeIsRunning()
        if let previous {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            if key == .derivedData {
                // The user had this folder before; the tests risk was theirs to accept then.
                _ = try XcodeLocations.preflightDerivedData(path: previous, volumes: volumes, xcodeRunning: running, acknowledgeExternalTests: true)
            } else {
                _ = try XcodeLocations.preflightArchives(path: previous, volumes: volumes, xcodeRunning: running)
            }
        } else {
            _ = try XcodeLocations.preflightDerivedData(path: nil, volumes: [], xcodeRunning: running, acknowledgeExternalTests: true)
        }
        try XcodeLocations.apply(
            XcodeLocations.Change(key: key, newValue: previous), runner: StreamingCommandRunner(observer: observer, children: children))
    }

    // MARK: - Decisions, tested

    /// The preflight's warnings and blockers. When it refuses only because the tests risk was not acknowledged — it
    /// passes with the acknowledgement — the blocker is the checkbox, not Core's sentence naming the CLI's flag.
    static func locationPreflight(acknowledged: Bool, _ preflight: (Bool) throws -> [String]) -> (warnings: [String], blockers: [OperationBlocker]) {
        do {
            return (try preflight(acknowledged), [])
        } catch {
            if !acknowledged, let warnings = try? preflight(true) { return (warnings, [.acknowledgeTests]) }
            return ([], [.core("\(error)")])
        }
    }

    /// The operations whose commands **Stop and Quit** may terminate (`AppModel.quitChoice`): deleting a runtime and changing
    /// a folder. A copy (`ditto`), an export (`xcodebuild`) and an offload get a runner nothing can stop. Offload is out because
    /// `simctl` only asks CoreSimulatorService to delete: a stopped client can leave the runtime deleted while the journal says
    /// `failed`, which Doctor reads as "the delete did not happen" and so would lose the offload's recovery route (R3 safety check).
    static func stoppableChildren(for prepared: PreparedOperation, _ children: ChildProcesses) -> ChildProcesses? {
        prepared.kind.canBeStopped ? children : nil
    }

    /// Offload and delete wait while simulator work runs (review L3).
    static func simulatorWorkBlockers(_ running: Bool) -> [OperationBlocker] { running ? [.simulatorWorkRunning] : [] }

    static func refuseIfSimulatorWork(_ running: Bool) throws {
        guard running else { return }
        throw RuntimeOperationError(
            "A simulator, simctl or a test run is running; deleting a runtime under it could break it. Nothing was deleted — run this again when it ends.")
    }

    /// Whether offload's refusal is the missing installer, which **Export installer first** fixes: the runtime is known
    /// and the library was read and has no installer for it. A library that cannot be read is not "missing an installer".
    static func installerMissing(runtime: SimulatorRuntime?, library: [RuntimeInstaller]?) -> Bool {
        guard let runtime, let library else { return false }
        return RuntimeOperations.installer(for: runtime, in: library) == nil
    }
}
