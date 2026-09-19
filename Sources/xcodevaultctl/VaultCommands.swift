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
        @Option(
            name: .long,
            help:
                "Vault directory relative to the volume root (default: \(VaultVolume.directoryName)). Not creatable by the privileged helper — see the discussion."
        ) var directory: String = VaultVolume.directoryName
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
