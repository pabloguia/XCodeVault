import Foundation

/// A resolved catalog path on this machine.
public struct StorageItem: Sendable, Codable, Equatable, Identifiable {
    public var id: String { categoryID + ":" + path }
    public var categoryID: String
    public var path: String
    public var exists: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    public var isMountPoint: Bool
    public var usage: DiskUsage?
    /// Where the bytes physically are (mount point of the filesystem serving the path).
    public var volumeMountPoint: String?
    public var onBootVolume: Bool

    public var allocatedBytes: UInt64 { usage?.allocatedBytes ?? 0 }
}

/// Summary groupings from docs/product/UX_AND_CLI.md.
public struct ScanSummary: Sendable, Codable, Equatable {
    public var internalDeveloperBytes: UInt64 = 0     // everything found on the boot volume
    public var relocatableBytes: UInt64 = 0
    public var cleanableBytes: UInt64 = 0
    public var coldStorageEligibleBytes: UInt64 = 0
    public var appleManagedBytes: UInt64 = 0
    public var mustRemainLocalBytes: UInt64 = 0
    /// Bytes on the boot volume that a recommended cleanup/relocation action would free (each item counted once).
    public var estimatedInternalSavingsBytes: UInt64 = 0
    /// The subset of `estimatedInternalSavingsBytes` whose strategy is verified (not experimental).
    public var verifiedSavingsBytes: UInt64 = 0
    public var runtimeImageBytes: UInt64 = 0          // from simctl sizeBytes
    public var lowerBound: Bool = false               // some paths unreadable
}

public struct ScanReport: Sendable, Codable, Equatable {
    public var generatedAt: Date
    public var toolVersion: String
    public var catalogVersion: String
    public var host: HostEnvironment
    public var xcodes: [XcodeInstallation]
    public var runtimes: [SimulatorRuntime]
    public var devices: [SimulatorDevice]
    public var volumes: [Volume]
    public var items: [StorageItem]
    public var summary: ScanSummary
    public var warnings: [String]

    public func category(for item: StorageItem) -> StorageCategory? { StorageCatalog.category(item.categoryID) }
}

public enum XCodeVaultVersion {
    public static let current = "0.1.0-dev"
}
