import Foundation

/// A mounted volume as seen by `diskutil info -plist`. Identity is the **volume UUID**; the
/// mount point is informational only (MIGRATION_ENGINE.md: never identify by `/Volumes/<name>`).
public struct Volume: Sendable, Codable, Equatable, Identifiable {
    public var id: String { volumeUUID ?? deviceNode }
    public var deviceNode: String            // /dev/disk3s1
    public var volumeName: String
    public var volumeUUID: String?
    public var mountPoint: String?
    public var filesystemPersonality: String // "APFS", "Case-sensitive APFS", "ExFAT", …
    public var filesystemType: String        // apfs / exfat / msdos / ntfs
    public var isInternal: Bool
    public var isRemovableMedia: Bool
    public var isEjectable: Bool
    public var busProtocol: String           // USB / Thunderbolt / PCI-Express / Disk Image / …
    public var isSolidState: Bool?
    public var isWritable: Bool
    public var ownersEnabled: Bool
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var isBootVolume: Bool            // the system or data volume of the running OS
    public var isDiskImage: Bool { busProtocol == "Disk Image" }
    public var isAPFS: Bool { filesystemType.lowercased() == "apfs" }
    public var isExternal: Bool { !isInternal }
}

/// Why a volume can or cannot be used as an XCodeVault destination.
public struct VolumeQualification: Sendable, Codable, Equatable {
    public enum Verdict: String, Sendable, Codable { case suitable, suitableWithWarnings, unsuitable }
    public var verdict: Verdict
    public var blockers: [String]
    public var warnings: [String]

    public static func evaluate(_ v: Volume, minimumFreeBytes: UInt64 = 20 * 1_000_000_000) -> VolumeQualification {
        var blockers: [String] = [], warnings: [String] = []
        if v.isBootVolume { blockers.append("This is the boot/system volume — the thing we are trying to free.") }
        if v.mountPoint == nil { blockers.append("Not mounted.") }
        if !v.isAPFS { blockers.append("Filesystem is \(v.filesystemPersonality); XCodeVault requires APFS (ownership, xattrs, clones, symlinks).") }
        if !v.isWritable { blockers.append("Volume is read-only.") }
        if !v.ownersEnabled { blockers.append("Ownership is ignored on this volume (noowners). Enable it with `diskutil enableOwnership` — CoreSimulator/Xcode data has mixed root/user ownership.") }
        if v.freeBytes < minimumFreeBytes { warnings.append("Only \(ByteCount.format(v.freeBytes)) free; simulator runtimes are 5–25 GB each.") }
        if v.isDiskImage { warnings.append("This is a disk image, not a physical device; fine for experiments, not a durable destination.") }
        if v.busProtocol == "USB" { warnings.append("USB-attached: expect much lower 4K random IOPS than internal storage; DerivedData workloads are IOPS-bound (research F9).") }
        if v.filesystemPersonality.lowercased().contains("case-sensitive") { warnings.append("Case-sensitive APFS: Xcode projects that rely on case-insensitive paths may break.") }
        let verdict: Verdict = blockers.isEmpty ? (warnings.isEmpty ? .suitable : .suitableWithWarnings) : .unsuitable
        return VolumeQualification(verdict: verdict, blockers: blockers, warnings: warnings)
    }
}

public enum VolumeDiscovery {
    /// All mounted volumes (excluding the OS's own hidden system volumes and CoreSimulator's runtime images).
    public static func mountedVolumes(runner: CommandRunning = ProcessCommandRunner()) throws -> [Volume] {
        let list = try runner.check(Tools.diskutil, ["list", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: Data(list.stdout.utf8), format: nil) as? [String: Any],
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for disk in all {
            for part in (disk["Partitions"] as? [[String: Any]]) ?? [] { if let id = part["DeviceIdentifier"] as? String { ids.append(id) } }
            for vol in (disk["APFSVolumes"] as? [[String: Any]]) ?? [] { if let id = vol["DeviceIdentifier"] as? String { ids.append(id) } }
        }
        var out: [Volume] = []
        for id in ids {
            guard let r = try? runner.run(Tools.diskutil, ["info", "-plist", id]), r.succeeded,
                  let v = try? parse(diskutilInfoPlist: Data(r.stdout.utf8)) else { continue }
            guard let mp = v.mountPoint, !mp.isEmpty else { continue }
            if mp.hasPrefix("/System/Volumes/") && mp != "/System/Volumes/Data" { continue }
            if mp.hasPrefix("/Library/Developer/CoreSimulator/Volumes/") { continue }
            if mp.hasPrefix("/private/var/") { continue }
            out.append(v)
        }
        return out
    }

    public static func parse(diskutilInfoPlist data: Data) throws -> Volume {
        guard let d = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CommandError(executable: Tools.diskutil, arguments: ["info", "-plist"], result: nil, underlying: "not a plist")
        }
        func b(_ k: String) -> Bool { d[k] as? Bool ?? false }
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        func u(_ k: String) -> UInt64 { (d[k] as? NSNumber)?.uint64Value ?? 0 }
        let mp = s("MountPoint")
        let role = (d["APFSVolumeRoles"] as? [String]) ?? []
        let isBoot = mp == "/" || mp == "/System/Volumes/Data" || role.contains("Data") && b("Internal") || role.contains("System")
        return Volume(
            deviceNode: s("DeviceNode"), volumeName: s("VolumeName"), volumeUUID: d["VolumeUUID"] as? String,
            mountPoint: mp.isEmpty ? nil : mp,
            filesystemPersonality: s("FilesystemName").isEmpty ? s("FilesystemType") : s("FilesystemName"),
            filesystemType: s("FilesystemType"),
            isInternal: b("Internal"), isRemovableMedia: b("RemovableMedia") || b("Removable"),
            isEjectable: b("Ejectable"), busProtocol: s("BusProtocol"),
            isSolidState: d["SolidState"] as? Bool, isWritable: b("WritableVolume"),
            ownersEnabled: b("GlobalPermissionsEnabled"),
            totalBytes: u("TotalSize"), freeBytes: u("APFSContainerFree") > 0 ? u("APFSContainerFree") : u("FreeSpace"),
            isBootVolume: isBoot)
    }
}
