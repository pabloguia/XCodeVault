import ArgumentParser
import Foundation
import XCodeVaultCore

struct Vault: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            abstract: HelpText.experimental(L10n.tr("cli.cmd.vault.abstract")), subcommands: [Init.self, Status.self, Forget.self],
            defaultSubcommand: Status.self)
    }
    struct Init: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(
                abstract: HelpText.experimental(L10n.tr("cli.cmd.vault.init.abstract", VaultVolume.directoryName)),
                discussion: """
                    Volume roots are usually root-owned. Until the privileged helper ships, pass --directory <subpath> \
                    to use a folder you can write, or create the default one with the command this prints when it fails.

                    It then creates the standard folders inside the vault directory: DerivedData, Archives and Runtimes \
                    (the destinations the app pre-fills).

                    Note --directory is a client-side choice: the privileged helper can only ever create the default \
                    \(VaultVolume.directoryName), so a custom directory has to be created by you either way.

                    EXAMPLES:
                      xcodevaultctl vault init /Volumes/MyDrive
                      xcodevaultctl vault init /Volumes/MyDrive --directory Developer/Vault
                      xcodevaultctl vault status
                    """)
        }
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
            // The standard layout (R6, `VaultLayout`): the folders the app pre-fills as destinations. The vault is
            // registered either way; a folder that cannot be made is reported with what to do.
            do {
                for folder in try VaultLayout.createFolders(vaultDirectory: vv.vaultDirectory(atMountPoint: mountPoint)) { print("  \(folder)") }
            } catch {
                print("! \(error)")
            }
        }
    }
    struct Status: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(abstract: HelpText.experimental(L10n.tr("cli.cmd.vault.status.abstract")))
        }
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
        static var configuration: CommandConfiguration { CommandConfiguration(abstract: HelpText.experimental(L10n.tr("cli.cmd.vault.forget.abstract"))) }
        @Argument var uuid: String
        func run() throws { try VaultRegistry().forget(uuid: uuid); print("Forgot \(uuid).") }
    }
}
