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

extension VaultLayout {
    /// I1: creates ONE standard folder of a registered vault — `folder` must be exactly `path(purpose, vaultDirectory:)`
    /// for one purpose, the vault directory must exist, and the folder must resolve inside it. Nothing else is ever
    /// created; a folder chosen by hand is never passed here. Ownership failures carry `OwnershipAdvice`.
    public static func createStandardFolder(_ folder: String, vaultDirectory: String, fileManager: FileManager = .default) throws {
        guard Purpose.allCases.contains(where: { path($0, vaultDirectory: vaultDirectory) == folder }) else {
            throw VaultError("\(folder) is not a standard folder of the vault \(vaultDirectory). Nothing was created.")
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: vaultDirectory, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError("The vault directory \(vaultDirectory) does not exist. Nothing was created.")
        }
        let inside: Bool
        do { inside = try PathSafety.isContainedAllowingMissingParents(folder, in: vaultDirectory) } catch {
            throw VaultError("Cannot tell where \(folder) would be created: \(error). Nothing was created.")
        }
        guard inside else { throw VaultError("\(folder) is not inside \(vaultDirectory). Nothing was created.") }
        do {
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            var message = "Cannot create \(folder): \(error.localizedDescription)"
            if VaultDirectoryRefusal.isPermissionRefusal(error) {
                message += "\n" + OwnershipAdvice.createVaultDirectory(mountPoint: vaultDirectory, relativeDirectory: (folder as NSString).lastPathComponent)
            }
            throw VaultError(message)
        }
    }
}

/// **Use This Drive** (R6): register the volume as a vault with the same validations as `vault init`, then create the
/// standard layout.
public enum DriveRegistration {
    /// The vault is registered in both cases; `foldersError` says the standard folders could not all be made (I2) — a
    /// distinct, partial outcome, never reported as "not registered".
    public struct Outcome: Sendable, Equatable {
        public var vault: VaultVolume
        public var folders: [String]
        /// Why the standard folders could not be created, with `OwnershipAdvice` when it was a permission refusal.
        public var foldersError: String?
        public var isComplete: Bool { foldersError == nil }
    }

    public static func useDrive(
        _ volume: Volume, registry: VaultRegistry = VaultRegistry(), journal: Journal = Journal(),
        isMountPoint: @Sendable (String) -> Bool = { MountStatus.isMountPoint($0) },
        volumeUUID: @Sendable (String) -> String? = { MountStatus.volumeUUID(at: $0) }
    ) throws -> Outcome {
        guard !volume.isNetwork else { throw VaultError("\(volume.volumeName) is a network volume; a vault must be a local disk.") }
        let vault = try registry.register(volume, journal: journal, isMountPoint: isMountPoint, volumeUUID: volumeUUID)
        guard let mp = volume.mountPoint else { throw VaultError("Volume has no mount point.") }
        return outcome(vault: vault) { try VaultLayout.createFolders(vaultDirectory: vault.vaultDirectory(atMountPoint: mp)) }
    }

    /// The registered vault and what creating its folders gave: the folders, or the error as a partial outcome.
    public static func outcome(vault: VaultVolume, createFolders: () throws -> [String]) -> Outcome {
        do {
            return Outcome(vault: vault, folders: try createFolders(), foldersError: nil)
        } catch {
            return Outcome(vault: vault, folders: [], foldersError: "\(error)")
        }
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
