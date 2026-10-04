import Foundation

/// The standard folders inside a vault (R6, ADR-0012), defined once and used everywhere: the app's default destination
/// folders, `vault init`, **Use This Drive** and the docs.
///
///     <volume>/XCodeVault/              the vault directory (`VaultVolume.relativeDirectory`)
///     <volume>/XCodeVault/DerivedData   Xcode's DerivedData location
///     <volume>/XCodeVault/Archives      Xcode's Archives location
///     <volume>/XCodeVault/Runtimes      simulator runtime installers (offload, export)
///
/// **Externalize Archives** (a migration) keeps the engine's own path under the vault directory, not these.
public enum VaultLayout {
    public enum Purpose: String, Sendable, CaseIterable, Codable {
        case derivedData = "DerivedData"
        case archives = "Archives"
        case runtimes = "Runtimes"

        public var folderName: String { rawValue }
    }

    /// `<vaultDirectory>/<folder>`.
    public static func path(_ purpose: Purpose, vaultDirectory: String) -> String {
        (vaultDirectory.hasSuffix("/") ? String(vaultDirectory.dropLast()) : vaultDirectory) + "/" + purpose.folderName
    }

    /// The vault's standard folder for `purpose`, at its current mount point; nil when it is not mounted.
    public static func path(_ purpose: Purpose, in vault: VaultVolumeCheck) -> String? {
        guard vault.isUsable, let mp = vault.currentMountPoint else { return nil }
        return path(purpose, vaultDirectory: vault.volume.vaultDirectory(atMountPoint: mp))
    }

    /// Creates every standard folder under `vaultDirectory` (each one only if missing) and returns their paths. A folder
    /// that cannot be created for lack of permission is reported with `OwnershipAdvice`, the same advice `vault init`
    /// gives for the vault directory itself.
    @discardableResult
    public static func createFolders(vaultDirectory: String, fileManager: FileManager = .default) throws -> [String] {
        var created: [String] = []
        for purpose in Purpose.allCases {
            let dir = path(purpose, vaultDirectory: vaultDirectory)
            // Inside the vault directory, never through a symlink out of it.
            let inside: Bool
            do { inside = try PathSafety.isContainedAllowingMissingParents(dir, in: vaultDirectory) } catch {
                throw VaultError("Cannot tell where \(dir) would be created: \(error). Nothing more was written.")
            }
            guard inside else { throw VaultError("\(dir) is not inside \(vaultDirectory). Nothing more was written.") }
            do {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                var message = "Cannot create \(dir): \(error.localizedDescription)"
                if VaultDirectoryRefusal.isPermissionRefusal(error) {
                    message += "\n" + OwnershipAdvice.createVaultDirectory(mountPoint: vaultDirectory, relativeDirectory: purpose.folderName)
                }
                throw VaultError(message)
            }
            created.append(dir)
        }
        return created
    }
}

/// **Use This Drive** (R6): register the volume as a vault with the same validations as `vault init`, then create the
/// standard layout.
public enum DriveRegistration {
    public struct Outcome: Sendable, Equatable {
        public var vault: VaultVolume
        public var folders: [String]
    }

    public static func useDrive(
        _ volume: Volume, registry: VaultRegistry = VaultRegistry(), journal: Journal = Journal(),
        isMountPoint: @Sendable (String) -> Bool = { MountStatus.isMountPoint($0) },
        volumeUUID: @Sendable (String) -> String? = { MountStatus.volumeUUID(at: $0) }
    ) throws -> Outcome {
        guard !volume.isNetwork else { throw VaultError("\(volume.volumeName) is a network volume; a vault must be a local disk.") }
        let vault = try registry.register(volume, journal: journal, isMountPoint: isMountPoint, volumeUUID: volumeUUID)
        guard let mp = volume.mountPoint else { throw VaultError("Volume has no mount point.") }
        let folders = try VaultLayout.createFolders(vaultDirectory: vault.vaultDirectory(atMountPoint: mp))
        return Outcome(vault: vault, folders: folders)
    }
}

/// A destination folder chosen by hand (R6's **Choose Another Folder…**): refused on a network file system.
public enum DestinationFolder {
    /// English prose when the folder is on a network file system; nil otherwise or when it cannot be read.
    public static func networkRefusal(_ fs: MountStatus.FilesystemInfo?) -> String? {
        guard let fs else { return nil }
        guard Volume.isNetworkFilesystem(fs.typeName) || !fs.isLocal else { return nil }
        return "\(fs.mountPoint) is a network volume (\(fs.typeName)). Choose a folder on a local disk: a network share disconnects with the network."
    }
}
