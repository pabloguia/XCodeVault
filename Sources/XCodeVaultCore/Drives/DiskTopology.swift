import Foundation

// R6 (ADR-0012): what is on each physical disk — its partition map, partitions, APFS containers and volumes, and the
// space no partition uses — read from `diskutil list -plist`, `diskutil apfs list -plist` and one
// `diskutil info -plist <disk>` per whole disk. Everything here is parsing and arithmetic; reading runs through a
// `CommandRunning` so a test never reads this Mac's disks.

/// One partition of a physical disk's map.
public struct DiskPartition: Sendable, Equatable, Codable {
    /// `disk2s1`.
    public var id: String
    /// The partition type: `EFI`, `Apple_APFS`, `Microsoft Basic Data`, `Windows_NTFS`, `DOS_FAT_32`, …
    public var content: String
    public var sizeBytes: UInt64
    /// The partition's own UUID (GPT); the stable part of a disk's identity (`DiskIdentity`).
    public var diskUUID: String?
    public var volumeName: String?
    public var volumeUUID: String?
    public var mountPoint: String?

    public init(
        id: String, content: String, sizeBytes: UInt64, diskUUID: String? = nil, volumeName: String? = nil, volumeUUID: String? = nil,
        mountPoint: String? = nil
    ) {
        self.id = id; self.content = content; self.sizeBytes = sizeBytes; self.diskUUID = diskUUID
        self.volumeName = volumeName; self.volumeUUID = volumeUUID; self.mountPoint = mountPoint
    }

    /// An APFS container's physical store: its volumes are listed under the container, not here.
    public var isAPFSStore: Bool { content == "Apple_APFS" }
    /// Partitions that are not user volumes and are never offered for erasing on their own.
    public var isSystemPartition: Bool {
        ["EFI", "Apple_Boot", "Apple_APFS_Recovery", "Apple_APFS_ISC", "Apple_KernelCoreDump", "Apple_partition_map", "Apple_Free"].contains(content)
    }
}

/// One volume of an APFS container (`diskutil apfs list -plist`).
public struct APFSVolumeInfo: Sendable, Equatable, Codable {
    /// `disk3s1`.
    public var id: String
    public var name: String
    public var uuid: String?
    /// `Data`, `System`, `Backup` (Time Machine), `Preboot`, `Recovery`, `VM`, …
    public var roles: [String]
    public var usedBytes: UInt64
    public var quotaBytes: UInt64

    public init(id: String, name: String, uuid: String? = nil, roles: [String] = [], usedBytes: UInt64 = 0, quotaBytes: UInt64 = 0) {
        self.id = id; self.name = name; self.uuid = uuid; self.roles = roles; self.usedBytes = usedBytes; self.quotaBytes = quotaBytes
    }

    /// Time Machine's role for an APFS backup volume.
    public var isTimeMachine: Bool { roles.contains("Backup") }
}

/// An APFS container (`diskutil apfs list -plist`): a synthesized disk whose physical store is a partition.
public struct APFSContainerInfo: Sendable, Equatable, Codable {
    /// `disk3`: the synthesized disk the container's volumes are numbered under.
    public var reference: String
    public var uuid: String?
    /// The partitions holding it, `disk2s1`.
    public var physicalStores: [String]
    public var capacityBytes: UInt64
    public var freeBytes: UInt64
    public var volumes: [APFSVolumeInfo]

    public init(
        reference: String, uuid: String? = nil, physicalStores: [String], capacityBytes: UInt64 = 0, freeBytes: UInt64 = 0, volumes: [APFSVolumeInfo] = []
    ) {
        self.reference = reference; self.uuid = uuid; self.physicalStores = physicalStores; self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes; self.volumes = volumes
    }
}

/// What makes "the disk I previewed" the same disk at the moment a preparation runs: a device id can be reused by
/// another disk plugged in after the first was ejected. Size and media name come from the disk; the partition UUIDs
/// are written in its map and change whenever the map is rewritten.
public struct DiskIdentity: Sendable, Equatable, Codable {
    public var wholeDisk: String
    public var mediaName: String
    public var sizeBytes: UInt64
    /// Every partition's UUID, sorted. Empty for a disk without a partition map.
    public var partitionUUIDs: [String]

    public init(wholeDisk: String, mediaName: String, sizeBytes: UInt64, partitionUUIDs: [String]) {
        self.wholeDisk = wholeDisk; self.mediaName = mediaName; self.sizeBytes = sizeBytes; self.partitionUUIDs = partitionUUIDs.sorted()
    }
}

/// A whole physical (or disk-image) disk and what is on it. Synthesized APFS container disks are never a
/// `PhysicalDisk`: they are the `containers` of the disk that stores them.
public struct PhysicalDisk: Sendable, Equatable, Codable, Identifiable {
    /// `disk2`.
    public var id: String
    public var mediaName: String
    public var sizeBytes: UInt64
    /// `USB`, `Thunderbolt`, `PCI-Express`, `SATA`, `Disk Image`, …
    public var busProtocol: String
    public var isInternal: Bool
    /// `VirtualOrPhysical == Virtual`: a disk image or a RAM disk.
    public var isVirtual: Bool
    public var isWritable: Bool
    /// `GUID_partition_scheme`, `FDisk_partition_scheme` (MBR), `Apple_partition_scheme`; nil when the disk has no map
    /// (a whole-disk file system, or a blank disk).
    public var partitionScheme: String?
    public var partitions: [DiskPartition]
    /// The APFS containers stored on this disk's partitions.
    public var containers: [APFSContainerInfo]

    public init(
        id: String, mediaName: String, sizeBytes: UInt64, busProtocol: String, isInternal: Bool, isVirtual: Bool, isWritable: Bool = true,
        partitionScheme: String?, partitions: [DiskPartition], containers: [APFSContainerInfo] = []
    ) {
        self.id = id; self.mediaName = mediaName; self.sizeBytes = sizeBytes; self.busProtocol = busProtocol; self.isInternal = isInternal
        self.isVirtual = isVirtual; self.isWritable = isWritable; self.partitionScheme = partitionScheme; self.partitions = partitions
        self.containers = containers
    }

    public var isDiskImage: Bool { isVirtual || busProtocol == "Disk Image" }
    public var isGPT: Bool { partitionScheme == "GUID_partition_scheme" }
    public var identity: DiskIdentity {
        DiskIdentity(wholeDisk: id, mediaName: mediaName, sizeBytes: sizeBytes, partitionUUIDs: partitions.compactMap(\.diskUUID))
    }

    /// GPT keeps its primary and backup tables and the alignment between partitions out of every partition; `diskutil`
    /// leaves at least this much unaccounted on a full disk (2 GB image: 40 KiB; this Mac's disks: under 1 MiB).
    public static let mapOverheadBytes: UInt64 = 16 * 1_048_576

    /// Space in the partition map that no partition uses, after the map's own overhead. Zero without a map.
    public var unpartitionedBytes: UInt64 {
        guard partitionScheme != nil else { return 0 }
        let used = partitions.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        return sizeBytes > used + Self.mapOverheadBytes ? sizeBytes - used - Self.mapOverheadBytes : 0
    }

    /// Every volume device id on the disk: non-APFS partitions that carry a file system, and every APFS volume of its
    /// containers. What "every volume this disk holds" means to the safety guard (`DiskSafety`).
    public var volumeIDs: [String] {
        partitions.filter { !$0.isAPFSStore && !$0.isSystemPartition }.map(\.id) + containers.flatMap { $0.volumes.map(\.id) }
    }

    /// Whether `id` (a partition, a container reference or an APFS volume) is on this disk.
    public func contains(_ id: String) -> Bool {
        id == self.id || partitions.contains { $0.id == id } || containers.contains { $0.reference == id || $0.volumes.contains { $0.id == id } }
    }

    /// The APFS container holding `volumeID`, if it is an APFS volume of this disk.
    public func container(holding volumeID: String) -> APFSContainerInfo? {
        containers.first { $0.volumes.contains { $0.id == volumeID } }
    }
}

public enum DiskTopology {
    /// The whole disks that are not synthesized APFS containers, in `diskutil`'s order: the disks to read `info` for.
    public static func physicalDiskIDs(list: Data) throws -> [String] {
        let all = try entries(list)
        return all.filter { $0["APFSPhysicalStores"] == nil }.compactMap { $0["DeviceIdentifier"] as? String }
    }

    /// Assembles the physical disks from the three outputs. `wholeDiskInfo` is `diskutil info -plist <id>` per id of
    /// `physicalDiskIDs`; a disk whose info is missing or unreadable is left out rather than guessed at.
    public static func parse(list: Data, apfs: Data, wholeDiskInfo: [String: Data]) throws -> [PhysicalDisk] {
        let containers = try parseContainers(apfs)
        var disks: [PhysicalDisk] = []
        for entry in try entries(list) where entry["APFSPhysicalStores"] == nil {
            guard let id = entry["DeviceIdentifier"] as? String, let infoData = wholeDiskInfo[id],
                let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
            else { continue }
            let parts = ((entry["Partitions"] as? [[String: Any]]) ?? []).compactMap { p -> DiskPartition? in
                guard let pid = p["DeviceIdentifier"] as? String else { return nil }
                return DiskPartition(
                    id: pid, content: p["Content"] as? String ?? "", sizeBytes: uint(p["Size"]), diskUUID: p["DiskUUID"] as? String,
                    volumeName: p["VolumeName"] as? String, volumeUUID: p["VolumeUUID"] as? String, mountPoint: p["MountPoint"] as? String)
            }
            let content = entry["Content"] as? String ?? info["Content"] as? String ?? ""
            // A disk whose content is a file system (no map) reports the file system's name here, never a scheme.
            let scheme = content.hasSuffix("_partition_scheme") ? content : nil
            let ids = Set(parts.map(\.id))
            disks.append(
                PhysicalDisk(
                    id: id, mediaName: info["MediaName"] as? String ?? "", sizeBytes: uint(info["Size"] ?? entry["Size"]),
                    busProtocol: info["BusProtocol"] as? String ?? "", isInternal: info["Internal"] as? Bool ?? true,
                    isVirtual: (info["VirtualOrPhysical"] as? String) == "Virtual", isWritable: info["WritableMedia"] as? Bool ?? false,
                    partitionScheme: scheme, partitions: parts, containers: containers.filter { $0.physicalStores.contains(where: ids.contains) }))
        }
        return disks
    }

    public static func parseContainers(_ apfs: Data) throws -> [APFSContainerInfo] {
        guard let root = try PropertyListSerialization.propertyList(from: apfs, format: nil) as? [String: Any] else {
            throw CommandError(executable: Tools.diskutil, arguments: ["apfs", "list", "-plist"], result: nil, underlying: "not a plist")
        }
        return ((root["Containers"] as? [[String: Any]]) ?? []).compactMap { c -> APFSContainerInfo? in
            guard let ref = c["ContainerReference"] as? String else { return nil }
            let stores = ((c["PhysicalStores"] as? [[String: Any]]) ?? []).compactMap { $0["DeviceIdentifier"] as? String }
            let volumes = ((c["Volumes"] as? [[String: Any]]) ?? []).compactMap { v -> APFSVolumeInfo? in
                guard let vid = v["DeviceIdentifier"] as? String else { return nil }
                return APFSVolumeInfo(
                    id: vid, name: v["Name"] as? String ?? "", uuid: v["APFSVolumeUUID"] as? String, roles: v["Roles"] as? [String] ?? [],
                    usedBytes: uint(v["CapacityInUse"]), quotaBytes: uint(v["CapacityQuota"]))
            }
            let designated = c["DesignatedPhysicalStore"] as? String
            return APFSContainerInfo(
                reference: ref, uuid: c["APFSContainerUUID"] as? String, physicalStores: stores.isEmpty ? [designated].compactMap { $0 } : stores,
                capacityBytes: uint(c["CapacityCeiling"]), freeBytes: uint(c["CapacityFree"]), volumes: volumes)
        }
    }

    /// Reads every physical disk through `runner`: `diskutil list -plist`, `diskutil apfs list -plist`, then
    /// `diskutil info -plist` per whole disk. Read-only verbs only.
    public static func read(runner: CommandRunning) throws -> [PhysicalDisk] {
        let list = Data(try runner.check(Tools.diskutil, ["list", "-plist"]).stdout.utf8)
        let apfs = Data(try runner.check(Tools.diskutil, ["apfs", "list", "-plist"]).stdout.utf8)
        var info: [String: Data] = [:]
        for id in try physicalDiskIDs(list: list) {
            guard let r = try? runner.run(Tools.diskutil, ["info", "-plist", id]), r.succeeded else { continue }
            info[id] = Data(r.stdout.utf8)
        }
        return try parse(list: list, apfs: apfs, wholeDiskInfo: info)
    }

    static func entries(_ list: Data) throws -> [[String: Any]] {
        guard let root = try PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any] else {
            throw CommandError(executable: Tools.diskutil, arguments: ["list", "-plist"], result: nil, underlying: "not a plist")
        }
        return (root["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
    }

    static func uint(_ value: Any?) -> UInt64 { (value as? NSNumber)?.uint64Value ?? 0 }
}

/// Everything R6 decides from: the physical disks and the mounted volumes, read together.
public struct DriveSnapshot: Sendable, Equatable {
    public var disks: [PhysicalDisk]
    public var volumes: [Volume]
    /// Volumes (by device id) whose root holds a Time Machine marker (`Backups.backupdb`, `.timemachine`): an HFS+ or
    /// older backup disk has no APFS `Backup` role to read.
    public var timeMachineMarkedVolumeIDs: Set<String>

    public init(disks: [PhysicalDisk], volumes: [Volume], timeMachineMarkedVolumeIDs: Set<String> = []) {
        self.disks = disks; self.volumes = volumes; self.timeMachineMarkedVolumeIDs = timeMachineMarkedVolumeIDs
    }

    /// The Time Machine markers at a volume's root.
    public static let timeMachineMarkers = ["Backups.backupdb", ".timemachine"]

    /// Reads the disks and the mounted volumes through `runner`, and looks for a Time Machine marker at each mounted
    /// volume's root through `fileExists`.
    public static func read(
        runner: CommandRunning = ProcessCommandRunner(), fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> DriveSnapshot {
        let disks = try DiskTopology.read(runner: runner)
        let volumes = try VolumeDiscovery.mountedVolumes(runner: runner)
        var marked = Set<String>()
        for v in volumes {
            guard let mp = v.mountPoint, mp != "/" else { continue }
            if timeMachineMarkers.contains(where: { fileExists(mp + "/" + $0) }) { marked.insert(deviceID(v.deviceNode)) }
        }
        return DriveSnapshot(disks: disks, volumes: volumes, timeMachineMarkedVolumeIDs: marked)
    }

    /// `/dev/disk3s1` → `disk3s1`.
    public static func deviceID(_ node: String) -> String { node.hasPrefix("/dev/") ? String(node.dropFirst(5)) : node }

    /// The disk that holds `id` — a partition, a container, an APFS volume, or the disk itself.
    public func disk(holding id: String) -> PhysicalDisk? {
        let bare = Self.deviceID(id)
        return disks.first { $0.contains(bare) }
    }

    /// The mounted volumes on `disk`.
    public func volumes(on disk: PhysicalDisk) -> [Volume] {
        volumes.filter { disk.contains(Self.deviceID($0.deviceNode)) }
    }

    /// The disks that hold the running system: the store of every container with a boot volume, and any disk holding a
    /// boot volume directly.
    public var bootDiskIDs: Set<String> {
        Set(volumes.filter(\.isBootVolume).compactMap { disk(holding: $0.deviceNode)?.id })
    }
}
