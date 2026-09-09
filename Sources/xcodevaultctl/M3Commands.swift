import ArgumentParser
import Foundation
import XCodeVaultCore

struct Vault: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Experimental. Register and verify external vault volumes (identified by UUID + sentinel, never by name).",
        subcommands: [Init.self, Status.self, Forget.self], defaultSubcommand: Status.self)
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register a mounted external APFS volume as a vault (creates <mount>/\(VaultVolume.directoryName) and a sentinel).",
            discussion: """
                Volume roots are usually root-owned. Until the privileged helper ships, pass --directory <subpath> \
                to use a folder you can write, or create the default one with the command this prints when it fails.

                Note --directory is a client-side choice: the privileged helper can only ever create the default \
                \(VaultVolume.directoryName), so a custom directory has to be created by you either way.
                """)
        @Argument(help: "Mount point, e.g. /Volumes/MyDrive") var mountPoint: String
        @Option(name: .long, help: "Vault directory relative to the volume root (default: \(VaultVolume.directoryName)). Not creatable by the privileged helper — see the discussion.") var directory: String = VaultVolume.directoryName
        func run() throws {
            let vols = try VolumeDiscovery.mountedVolumes()
            guard let v = vols.first(where: { $0.mountPoint == mountPoint }) else {
                throw ValidationError("No mounted volume at \(mountPoint). See `xcodevaultctl volumes`.")
            }
            let q = VolumeQualification.evaluate(v)
            for w in q.warnings { print("! \(w)") }
            if directory.hasPrefix(".TemporaryItems") { print("! .TemporaryItems is purged by macOS — fine for experiments, not for durable storage.") }
            let vv = try VaultRegistry().register(v, relativeDirectory: directory)
            print("Registered \(vv.volumeName) (\(vv.volumeUUID)) at \(vv.lastVaultDirectory).")
        }
    }
    struct Status: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let checks = try VaultVerifier().checkAll()
            try emit(checks, json: global.json) {
                if checks.isEmpty { return "No vault volumes registered. `xcodevaultctl vault init /Volumes/<name>`\n" }
                return checks.map { "\($0.state.rawValue.uppercased())  \($0.volume.volumeName)  \($0.volume.volumeUUID)\n    \($0.detail)\n" }.joined()
            }
        }
    }
    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a volume from the registry (data on the volume is untouched).")
        @Argument var uuid: String
        func run() throws { try VaultRegistry().forget(uuid: uuid); print("Forgot \(uuid).") }
    }
}

struct Externalize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Copy a cold-storage category (Archives) to a verified vault volume with deep verification. The source is kept unless --remove-source-after-verify is given.",
        discussion:
            "Experimental: labeled so until the Definition of Done is met. Never merges into existing vault data; never removes a source without re-verification."
    )
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Category id (currently: archives).") var category: String = "archives"
    @Option(name: .long, help: "Vault volume: UUID, name or mount point (see `vault status`).") var vault: String
    @Option(name: .long, help: "Source directory (defaults to the category's standard path).") var source: String?
    @Flag(name: .long, help: "Perform the copy (default is a plan only).") var apply = false
    @Flag(name: .long, help: "After a successful, re-verified copy, delete the original.") var removeSourceAfterVerify = false
    @Flag(name: .customLong("i-confirm-deleting-non-regenerable-data"), help: "Required with --remove-source-after-verify for Archives.")
    var confirmNonRegenerable = false
    struct Out: Encodable { let plan: MigrationPlan; let outcome: MigrationOutcome? }
    func run() throws {
        guard let c = StorageCatalog.category(category) else { throw ValidationError("Unknown category \(category).") }
        let src = source ?? c.pathTemplates.first!.expandingTilde()
        let engine = MigrationEngine()
        let plan = try engine.planExternalize(categoryID: category, source: src, vaultRef: vault)
        for w in plan.warnings { print("! \(w)") }
        if !apply {
            try emit(Out(plan: plan, outcome: nil), json: global.json) {
                "Plan: copy \(ByteCount.format(plan.sourceBytes)) (\(plan.sourceFiles) files) \(plan.source) → \(plan.destination), deep verify. Re-run with --apply.\n"
            }
            return
        }
        print("Copying \(ByteCount.format(plan.sourceBytes)) → \(plan.destination) …")
        var outcome = try engine.copyAndVerify(plan)
        print(
            "Verified: \(outcome.verification.sourceFiles) files, \(outcome.verification.hashedFiles) hashed, \(ByteCount.format(outcome.verification.destinationBytes)). Source intact."
        )
        if removeSourceAfterVerify {
            outcome = try engine.removeSource(outcome, confirmNonRegenerable: confirmNonRegenerable)
            print(
                "Source removed after re-verification. Restore with: xcodevaultctl restore --category \(category) --vault \(vault) --name \"\((plan.source as NSString).lastPathComponent)\" --to \"\(plan.source)\""
            )
        }
        if global.json { print(try JSONOutput.encode(Out(plan: plan, outcome: outcome))) }
    }
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Experimental. Copy a vault entry back to its original location with deep verification. Never overwrites; destination must be under the category's standard path."
    )
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var category: String = "archives"
    @Option(name: .long, help: "Vault volume: UUID, name or mount point.") var vault: String
    @Option(name: .long, help: "Entry name inside <vault>/\(VaultVolume.directoryName)/<category>/.") var name: String
    @Option(name: .long, help: "Destination path (defaults to the category's standard path).") var to: String?
    @Flag(name: .long) var apply = false
    func run() throws {
        guard let c = StorageCatalog.category(category) else { throw ValidationError("Unknown category \(category).") }
        let dest = to ?? c.pathTemplates.first!.expandingTilde()
        let engine = MigrationEngine()
        let plan = try engine.planRestore(categoryID: category, vaultRef: vault, name: name, to: dest)
        if !apply { print("Plan: copy \(ByteCount.format(plan.sourceBytes)) \(plan.source) → \(plan.destination), deep verify. Re-run with --apply."); return }
        let outcome = try engine.copyAndVerify(plan)
        print(
            "Restored and verified: \(outcome.verification.sourceFiles) files, \(ByteCount.format(outcome.verification.destinationBytes)). The vault copy is kept."
        )
        if global.json { print(try JSONOutput.encode(outcome)) }
    }
}

struct Migration: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Experimental. Inspect, abort (pre-verification) or resume (post-verification) interrupted migrations.",
        subcommands: [Status.self, Abort.self, Resume.self], defaultSubcommand: Status.self)
    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Finish a cleanup interrupted after verification: re-verify the renamed-aside original against the vault copy, then remove it (or restore it if they differ)."
        )
        @Argument var operationID: String
        @Flag(name: .customLong("i-confirm-deleting-non-regenerable-data"), help: "Required for Archives.") var confirmNonRegenerable = false
        func run() throws { print(try MigrationEngine().resume(operationID: operationID, confirmNonRegenerable: confirmNonRegenerable)) }
    }
    struct Status: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let interrupted = try Journal().interrupted().filter { $0.kind == .migration }
            let leftovers = try MigrationEngine().leftoverPartialCopies()
            struct Out: Encodable { let interrupted: [JournalEntry]; let leftoverPartialCopies: [JournalEntry] }
            try emit(Out(interrupted: interrupted, leftoverPartialCopies: leftovers), json: global.json) {
                var o = interrupted.isEmpty
                    ? "No interrupted migrations.\n"
                    : interrupted.map { "INTERRUPTED \($0.id)  \($0.summary)  paths: \($0.paths.joined(separator: " → "))\n" }.joined()
                for l in leftovers {
                    o += "LEFTOVER PARTIAL COPY \(l.id)  \(l.paths[1])  (failed before verification; `migration abort \(l.id)` removes it)\n"
                }
                return o
            }
        }
    }
    struct Abort: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove the partial destination copy of a migration interrupted before verification; refuses after verification; the source is never touched.")
        @Argument var operationID: String
        func run() throws {
            try MigrationEngine().abort(operationID: operationID);
            print("Aborted \(operationID). See `journal` for what was removed; the source was not touched.")
        }
    }
}
