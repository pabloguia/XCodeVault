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
    /// True when the mount-state question could not be answered for this path at scan time.
    ///
    /// Separate from `isMountPoint` rather than folded into it, because the two say different
    /// things and a consumer is entitled to both. `isMountPoint` means "a filesystem is mounted
    /// here"; setting it for an unreadable path would make the scan report assert something it
    /// does not know. This flag means "do not rely on `isMountPoint` being `false` here" — and a
    /// planner deciding whether to delete has to treat it exactly as it treats `isMountPoint`.
    ///
    /// Defaulted so that decoding a report written before this field existed keeps working, and
    /// so that the many test fixtures constructing `StorageItem` by hand did not all have to
    /// assert a value for a question they are not about.
    public var mountStateUndetermined: Bool = false
    public var usage: DiskUsage?
    /// Where the bytes physically are (mount point of the filesystem serving the path).
    public var volumeMountPoint: String?
    public var onBootVolume: Bool

    public var allocatedBytes: UInt64 { usage?.allocatedBytes ?? 0 }
}

/// Summary groupings from docs/product/UX_AND_CLI.md.
public struct ScanSummary: Sendable, Codable, Equatable {
    public var internalDeveloperBytes: UInt64 = 0  // everything found on the boot volume
    public var relocatableBytes: UInt64 = 0
    public var cleanableBytes: UInt64 = 0
    public var coldStorageEligibleBytes: UInt64 = 0
    public var appleManagedBytes: UInt64 = 0
    public var mustRemainLocalBytes: UInt64 = 0
    /// Bytes on the boot volume that a recommended cleanup/relocation action would free (each item counted once).
    public var estimatedInternalSavingsBytes: UInt64 = 0
    /// The subset of `estimatedInternalSavingsBytes` whose strategy is verified (not experimental).
    public var verifiedSavingsBytes: UInt64 = 0
    public var runtimeImageBytes: UInt64 = 0  // from simctl sizeBytes
    public var lowerBound: Bool = false  // some paths unreadable
}

extension StorageItem {
    /// The display name of the category this item's bytes are already counted under, when this item
    /// is a breakdown of another category rather than storage in addition to it.
    public func breakdownParentName(in report: ScanReport) -> String? {
        guard let c = report.category(for: self), let parent = c.isBreakdownOf else { return nil }
        return StorageCatalog.category(parent)?.name ?? parent
    }
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
