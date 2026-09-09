import ArgumentParser
import Foundation
import XCodeVaultCore

// MARK: - clean

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Plan (default) or apply deletion of regenerable developer data. Never touches Archives or anything non-regenerable.",
        discussion: """
            Without --apply this only prints the plan. Deletions are journaled to \
            ~/Library/Application Support/XCodeVault/journal.jsonl. Root-owned categories are listed \
            but require the privileged helper (not shipped yet). Every category here is labeled \
            experimental until its functional probes are recorded in the compatibility matrix.
            """)
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Restrict to these category ids (see `compatibility`).")
    var category: [String] = []
    @Flag(name: .long, help: "Actually delete. Without it, only the plan is shown.")
    var apply = false
    @Flag(name: .long, help: "Move to Trash instead of deleting (space is freed only when the Trash is emptied).")
    var trash = false
    @Flag(name: .long, help: "Proceed even if Xcode.app is running.")
    var force = false
    @Flag(name: .long, help: "One action per category instead of per project / OS build.")
    var coarse = false

    struct Output: Encodable { let plan: CleanPlan; let result: CleanResult? }

    func run() throws {
        let report = XCodeVaultCore.Scanner().scan()
        let plan = CleanPlanner().plan(report: report, categories: Set(category), granular: !coarse)
        var result: CleanResult? = nil
        if apply {
            result = try CleanExecutor(useTrash: trash).execute(plan, force: force)
        }
        if global.json { print(try JSONOutput.encode(Output(plan: plan, result: result))); return }
        print("Cleanup plan (\(plan.actions.count) action(s), \(ByteCount.format(plan.totalBytes))):")
        for a in plan.actions {
            print(
                "  \(TextRendererPad.pad(ByteCount.format(a.bytes), 10)) \(TextRendererPad.pad(a.categoryName, 34)) \(a.requiresRoot ? "[root — helper needed] " : "")\(a.isExperimental ? "(exp.) " : "")\(a.path)"
            )
        }
        for s in plan.skipped { print("  skipped: \(s)") }
        for w in plan.warnings { print("  ! \(w)") }
        if let result {
            print("\nDeleted \(result.deleted.count) path(s), freed \(ByteCount.format(result.bytesFreed)).")
            for f in result.failedPairs { print("  FAILED \(f.path): \(f.error)") }
        } else if !plan.userActions.isEmpty {
            print("\nDry run. Re-run with --apply to delete the \(plan.userActions.count) user-level action(s) above.")
        }
    }
}

enum TextRendererPad { static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) } }

// MARK: - runtime (extended)

extension Runtime {
    static var extendedSubcommands: [ParsableCommand.Type] { [List.self, Delete.self, Export.self, Import.self, Library.self, Offload.self] }

    static func selectedXcode() throws -> (XcodeInstallation, HostEnvironment) {
        let xcodes = XcodeDiscovery.discover()
        guard let x = xcodes.first(where: \.isSelected) ?? xcodes.first else { throw ValidationError("No Xcode found.") }
        return (x, HostEnvironment.discover())
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an installed runtime via `simctl runtime delete` (the only supported way; frees the MobileAsset store).")
        @Argument(help: "Runtime image identifier (UUID from `runtime list`), or 'all'.") var identifier: String
        @Flag(name: .long, help: "Keep the MobileAsset (only the mounted image is removed).") var keepAsset = false
        @Flag(name: .long, help: "Ask simctl what would be deleted without deleting.") var dryRun = false
        @Flag(name: .long, help: "Confirm deletion.") var yes = false
        func run() throws {
            let (x, h) = try selectedXcode()
            if !dryRun && !yes {
                throw ValidationError("Deleting a runtime removes 5–25 GB that must be re-downloaded or re-imported. Pass --yes to confirm, or --dry-run.")
            }
            let r = try RuntimeOperations(xcode: x, host: h).delete(identifier: identifier, keepAsset: keepAsset, dryRun: dryRun)
            print(r.stdout + r.stderr)
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a runtime installer to a Runtime Library directory (`xcodebuild -downloadPlatform … -exportPath`).")
        @Argument(help: "iOS | watchOS | tvOS | visionOS") var platform: String
        @Option(name: .long, help: "Destination directory (your Runtime Library, e.g. on an external APFS volume).") var to: String
        @Option(name: .long, help: "OS version, e.g. 26.5 (feature-detected; omit for the matching runtime).") var buildVersion: String?
        @Option(name: .long, help: "universal | arm64 (Apple Silicon only).") var arch: String?
        @Flag(name: .long, help: "Only run the preflight checks.") var preflight = false
        func run() throws {
            let (x, h) = try selectedXcode()
            let ops = RuntimeOperations(xcode: x, host: h)
            let req = RuntimeOperations.ExportRequest(platform: platform, buildVersion: buildVersion, architectureVariant: arch, destination: to)
            let warnings = try ops.preflightExport(
                req, freeBytesAtDestination: MountStatus.space(at: to)?.free,
                installedRuntimes: (try? SimulatorDiscovery.runtimes(developerDir: x.developerDirectory)) ?? [])
            for w in warnings { print("! \(w)") }
            if preflight { print("preflight OK"); return }
            print("Downloading \(platform) runtime installer to \(to) … (this can take a long time; output appears when xcodebuild finishes)")
            let r = try ops.export(req)
            print(r.stdout.suffix(2000))
            print("Done. Installers now in \(to):")
            for i in try RuntimeOperations.library(at: to) { print("  \(ByteCount.format(i.sizeBytes))  \(i.fileName)") }
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install a runtime from a Runtime Library installer (`xcodebuild -importPlatform`).")
        @Argument(help: "Path to the .dmg installer.") var dmg: String
        @Flag(name: .long, help: "Only run the preflight checks (staging space, capability).") var preflight = false
        func run() throws {
            let (x, h) = try selectedXcode()
            let ops = RuntimeOperations(xcode: x, host: h)
            for w in try ops.preflightImport(dmg: dmg) { print("! \(w)") }
            if preflight { print("preflight OK"); return }
            print("Importing \(dmg) … (installation stages on the internal volume)")
            let r = try ops.importRuntime(dmg: dmg)
            print(r.stdout.suffix(2000))
        }
    }

    struct Library: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List runtime installers in a Runtime Library directory and whether each installed runtime has one.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Runtime Library directory.") var dir: String
        struct Row: Encodable { let installer: RuntimeInstaller?; let runtime: SimulatorRuntime? }
        func run() throws {
            let lib = try RuntimeOperations.library(at: dir)
            let rts = (try? SimulatorDiscovery.runtimes()) ?? []
            var rows: [Row] = lib.map { Row(installer: $0, runtime: nil) }
            for r in rts { rows.append(Row(installer: RuntimeOperations.installer(for: r, in: lib), runtime: r)) }
            try emit(rows, json: global.json) {
                var o = "Installers in \(dir):\n"
                if lib.isEmpty { o += "  (none)\n" }
                for i in lib {
                    o +=
                        "  \(TextRendererPad.pad(ByteCount.format(i.sizeBytes), 10)) \(TextRendererPad.pad(i.platform ?? "?", 9)) \(TextRendererPad.pad(i.version ?? "?", 7)) \(i.fileName)\n"
                }
                o += "\nInstalled runtimes:\n"
                for r in rts {
                    let m = RuntimeOperations.installer(for: r, in: lib)
                    o +=
                        "  \(TextRendererPad.pad(r.platformName, 9)) \(TextRendererPad.pad(r.version ?? "?", 7)) \(ByteCount.format(r.sizeBytes ?? 0))  \(m != nil ? "installer in library ✓ (can be offloaded)" : "NO installer in library — export first")\n"
                }
                return o
            }
        }
    }

    struct Offload: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an installed runtime only if its installer already sits in the Runtime Library (export first if not). Two-phase, journaled.")
        @Argument(help: "Runtime image identifier (UUID from `runtime list`).") var identifier: String
        @Option(name: .long, help: "Runtime Library directory.") var library: String
        @Flag(name: .long, help: "Confirm deletion.") var yes = false
        func run() throws {
            let (x, h) = try selectedXcode()
            let rts = try SimulatorDiscovery.runtimes()
            guard let rt = rts.first(where: { $0.identifier == identifier }) else {
                throw ValidationError("No installed runtime with identifier \(identifier).")
            }
            // The same rule-6 check `export` does, and it matters more here: this is the verb that
            // deletes 5–25 GB. With the volume absent and a stale installer sitting in a leftover
            // /Volumes directory on the internal disk, `library(at:)` lists it, `hdiutil imageinfo`
            // reads it, and the installed runtime is deleted — a source removed against a copy that
            // is not where the user believes it is, on a disk that just lost the space twice over.
            guard !RuntimeOperations.isNotOnAMountedVolume(destination: library) else {
                throw ValidationError(
                    "\(library) is under /Volumes but no volume is mounted there — most likely a mount-point directory left behind by an unclean eject. "
                        + "The runtime is NOT deleted. Reconnect the drive and check `xcodevaultctl volumes`.")
            }
            let lib = try RuntimeOperations.library(at: library)
            guard let inst = RuntimeOperations.installer(for: rt, in: lib) else {
                throw ValidationError(
                    "No installer for \(rt.platformName) \(rt.version ?? "?") in \(library). Run `xcodevaultctl runtime export \(rt.platformName == "iphone" ? "iOS" : rt.platformName) --to \(library)` first — the runtime is NOT deleted."
                )
            }
            // Verify the installer is a readable disk image before deleting anything.
            let info = try ProcessCommandRunner().run(Tools.hdiutil, ["imageinfo", inst.path])
            guard info.succeeded else { throw ValidationError("hdiutil cannot read \(inst.path); refusing to delete the installed runtime.") }
            print("Installer readable (hdiutil imageinfo): \(inst.fileName) (\(ByteCount.format(inst.sizeBytes))). Seal validation happens on import.")
            guard yes else {
                print("Would delete runtime \(rt.runtimeIdentifier ?? identifier) (\(ByteCount.format(rt.sizeBytes ?? 0))). Pass --yes to proceed."); return
            }
            let ops = RuntimeOperations(xcode: x, host: h)
            let op = UUID().uuidString
            // `detail` carries the runtime's identity, not just the image UUID. `doctor` has to decide
            // whether an unavailable *device* is recoverable, and devices are keyed by
            // runtimeIdentifier — without this the only link is the installer's filename, which for a
            // `.exportedBundle` is `…/Restore/WatchOSSimulatorRuntime_Cryptex.dmg` and carries neither
            // platform nor version.
            let identity = [
                "runtimeIdentifier": rt.runtimeIdentifier ?? "", "version": rt.version ?? "", "build": rt.build ?? "",
                "installer": inst.path,
            ].filter { !$0.value.isEmpty }
            try ops.journal.record(
                id: op, kind: .runtimeOffload, state: .started, summary: "offload \(identifier) (installer \(inst.path))", paths: [inst.path],
                detail: identity)
            let r: CommandResult
            do { r = try ops.delete(identifier: identifier) } catch {
                try ops.journal.record(id: op, kind: .runtimeOffload, state: .failed, summary: "offload \(identifier) failed: \(error)", paths: [inst.path]);
                throw error
            }
            try ops.journal.record(
                id: op, kind: .runtimeOffload, state: .completed, summary: "offloaded \(identifier)", paths: [inst.path], detail: identity)
            // `simctl runtime delete` prints nothing on success, so the old `print(stdout + stderr)`
            // emitted a blank line and the command finished having said only what it checked
            // beforehand — leaving the user to guess whether 10 GB had actually been deleted.
            let tail = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { print(tail) }
            // No parenthetical when the size is unknown: "0 B" answers "how much did this free?" with
            // a confident wrong number. The image size is also a floor, not the total — deleting the
            // runtime drops its MobileAsset copy too.
            let freed = rt.sizeBytes.map { " (at least \(ByteCount.format($0)))" } ?? ""
            print("Deleted runtime \(rt.runtimeIdentifier ?? identifier)\(freed) from the internal volume.")
            // The surprising part, and the reason `doctor` now refuses to suggest deleting them:
            // the devices survive, they just cannot run until the runtime is back.
            print("Devices for this runtime are now Unavailable, NOT deleted — they return to Shutdown with their data when it is re-imported (E11).")
            print("Re-install later with: xcodevaultctl runtime import \"\(inst.path)\"")
        }
    }
}

// MARK: - locations

struct Locations: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Xcode ▸ Settings ▸ Locations (DerivedData, Archives) — Apple's supported relocation.",
        subcommands: [
            Show.self, SetDerivedData.self, ResetDerivedData.self, SetArchives.self, ResetArchives.self, SetCompilationCache.self, ResetCompilationCache.self,
        ], defaultSubcommand: Show.self)
    struct Show: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let l = XcodeLocations.read()
            try emit(l, json: global.json) {
                "DerivedData:          \(l.derivedData ?? "(default: ~/Library/Developer/Xcode/DerivedData)")\nBuild location style: \(l.buildLocationStyle ?? "(default: Unique)")\nArchives:             \(l.archives ?? "(default: ~/Library/Developer/Xcode/Archives)")\nCompilation cache:    \(l.compilationCache ?? "(default: <DerivedData>/CompilationCache.noindex)")\n"
            }
        }
    }
    struct SetDerivedData: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-derived-data",
            abstract:
                "Point DerivedData at a directory (IDECustomDerivedDataLocation; reproduced on Xcode 26.5, E8b). Experimental until the matrix is complete.")
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        @Flag(
            name: .customLong("i-understand-tests-may-fail"),
            help: "Acknowledge that xcodebuild test cannot load test bundles from a physical external volume (E2).") var acknowledge = false
        func run() throws {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            let warnings = try XcodeLocations.preflightDerivedData(
                path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: acknowledge)
            for w in warnings { print("! \(w)") }
            try XcodeLocations.apply(.init(key: XcodeLocations.derivedDataKey, newValue: path))
            print("IDECustomDerivedDataLocation = \(path). Existing DerivedData was not moved (it is regenerable; `clean --category derivedData` reclaims it).")
        }
    }
    struct SetArchives: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-archives",
            abstract:
                "Point new Archives at a directory (IDECustomDistributionArchivesLocation; reproduced on Xcode 26.5, status: probable/experimental). Existing archives are not moved — use `externalize --category archives`."
        )
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        func run() throws {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            for w in try XcodeLocations.preflightArchives(path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning()) { print("! \(w)") }
            try XcodeLocations.apply(.init(key: XcodeLocations.archivesKey, newValue: path))
            print("IDECustomDistributionArchivesLocation = \(path). Xcode adds YYYY-MM-DD/<Scheme>.xcarchive folders under it.")
        }
    }
    struct ResetArchives: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset-archives", abstract: "Restore Xcode's default Archives location.")
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: XcodeLocations.archivesKey, newValue: nil)); print("Archives location reset to the default.")
        }
    }
    struct SetCompilationCache: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-compilation-cache",
            abstract: "Point the Xcode 26 compilation cache at a directory (IDECustomCompilationCacheLocation). Experimental.")
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        @Flag(name: .customLong("i-understand-tests-may-fail"), help: "Acknowledge the E2 external-volume caveat (build products may be served from here).")
        var acknowledge = false
        func run() throws {
            let xcodes = XcodeDiscovery.discover(detectCapabilities: false)
            guard let x = xcodes.first(where: \.isSelected) ?? xcodes.first, x.majorVersion >= 26 else {
                throw ValidationError("The compilation cache location setting exists in Xcode 26+; selected Xcode is older.")
            }
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            for w in try XcodeLocations.preflightDerivedData(
                path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: acknowledge)
            { print("! \(w)") }
            try XcodeLocations.apply(.init(key: XcodeLocations.compilationCacheKey, newValue: path))
            print("IDECustomCompilationCacheLocation = \(path).")
        }
    }
    struct ResetCompilationCache: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset-compilation-cache", abstract: "Restore the default compilation cache location.")
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: XcodeLocations.compilationCacheKey, newValue: nil)); print("Compilation cache location reset to the default.")
        }
    }
    struct ResetDerivedData: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset-derived-data", abstract: "Restore Xcode's default DerivedData location.")
        func run() throws {
            _ = try XcodeLocations.preflightDerivedData(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: true)
            try XcodeLocations.apply(.init(key: XcodeLocations.derivedDataKey, newValue: nil))
            print("DerivedData location reset to the default.")
        }
    }
}

// MARK: - journal

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal", abstract: "Show the operation journal (every change XCodeVault made, and any interrupted operation).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Show only the last N entries.") var last: Int = 50
    func run() throws {
        let j = Journal()
        let entries = try j.entries().suffix(last)
        let interrupted = try j.interrupted()
        struct Out: Encodable { let entries: [JournalEntry]; let interrupted: [JournalEntry] }
        try emit(Out(entries: Array(entries), interrupted: interrupted), json: global.json) {
            var o = "Journal: \(j.url.path)\n"
            let f = ISO8601DateFormatter()
            for e in entries {
                o +=
                    "  \(e.sequence)  \(f.string(from: e.timestamp))  \(TextRendererPad.pad(e.kind.rawValue, 19)) \(TextRendererPad.pad(e.state.rawValue, 10)) \(e.summary)\n"
            }
            if !interrupted.isEmpty {
                o += "\n! Interrupted operations (started, never completed):\n"; for e in interrupted { o += "  \(e.id)  \(e.kind.rawValue)  \(e.summary)\n" }
            }
            return o
        }
    }
}
