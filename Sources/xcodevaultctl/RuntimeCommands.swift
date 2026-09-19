import ArgumentParser
import Foundation
import XCodeVaultCore

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
            abstract:
                "EXPERIMENTAL. Delete an installed runtime only if its installer already sits in the Runtime Library (export first if not). "
                + "Two-phase, journaled. The round trip that makes this safe — devices returning when the runtime is re-imported — has been "
                + "observed twice on one configuration and at the same version; see `compatibility`.")
        @Argument(help: "Runtime image identifier (UUID from `runtime list`).") var identifier: String
        @Option(name: .long, help: "Runtime Library directory.") var library: String
        @Flag(name: .long, help: "Confirm deletion.") var yes = false
        func run() throws {
            // Argument parsing and presentation only. Every guard, and all three journal
            // transitions, moved to `RuntimeOperations` on 2026-09-18 (issue #14): they lived here,
            // in an executable target no test can import, guarding the verb that deletes 5-25 GB.
            let (x, h) = try selectedXcode()
            let ops = RuntimeOperations(xcode: x, host: h)
            let plan: RuntimeOperations.OffloadPlan
            let warnings: [String]
            do {
                (plan, warnings) = try ops.preflightOffload(
                    identifier: identifier, library: library, installedRuntimes: try SimulatorDiscovery.runtimes())
            } catch let e as RuntimeOperationError {
                // Preserved as a ValidationError so the CLI's exit code and presentation are what
                // they were before the policy moved.
                throw ValidationError(e.description)
            }
            for w in warnings { print("Note: \(w)") }
            print(
                "Installer readable (hdiutil imageinfo): \(plan.installerFileName) (\(ByteCount.format(plan.installerSizeBytes))). "
                    + "Seal validation happens on import.")
            // The qualifier belongs *here*, where the user decides, and not only after the deletion.
            // `doctor` hedges this same claim ("observed twice on one configuration … a cross-version
            // import has not been tried") while the CLI stated it as flat fact at the one moment the
            // data is still there — the stronger claim made where it costs most. CLAUDE.md rule 10.
            let recoveryCaveat =
                "Recovery evidence: devices returned to Shutdown with their data on macOS 26.6.2 / Xcode 26.5 / Intel, iOS 26.5, "
                + "re-imported at the SAME version (E8/H4, F13). Two runs of one configuration; a cross-version import has never "
                + "been tried."
            guard yes else {
                let size = plan.sizeBytes.map { " (\(ByteCount.format($0)))" } ?? ""
                print("Would delete runtime \(plan.runtimeIdentifier ?? identifier)\(size). Pass --yes to proceed.")
                print(recoveryCaveat)
                return
            }
            let r = try ops.offload(plan, confirmedByUser: .explicitUserIntent(recordedAs: "--yes"))
            // `simctl runtime delete` prints nothing on success, so the old `print(stdout + stderr)`
            // emitted a blank line and the command finished having said only what it checked
            // beforehand — leaving the user to guess whether 10 GB had actually been deleted.
            let tail = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { print(tail) }
            // No parenthetical when the size is unknown: "0 B" answers "how much did this free?"
            // with a confident wrong number. The image size is also a floor, not the total —
            // deleting the runtime drops its MobileAsset copy too.
            let freed = plan.sizeBytes.map { " (at least \(ByteCount.format($0)))" } ?? ""
            print("Deleted runtime \(plan.runtimeIdentifier ?? identifier)\(freed) from the internal volume.")
            // The surprising part, and the reason `doctor` now refuses to suggest deleting them:
            // the devices survive, they just cannot run until the runtime is back.
            print("Devices for this runtime are now Unavailable, NOT deleted — they are expected to return to Shutdown with their data when it is re-imported.")
            print(recoveryCaveat)
            print("Re-install later with: xcodevaultctl runtime import \"\(plan.installerPath)\"")
        }
    }
}
