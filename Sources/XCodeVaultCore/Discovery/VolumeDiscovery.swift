import Foundation

/// A mounted volume as seen by `diskutil info -plist`. Identity is the **volume UUID**; the
/// mount point is informational only (MIGRATION_ENGINE.md: never identify by `/Volumes/<name>`).
public struct Volume: Sendable, Codable, Equatable, Identifiable {
    public var id: String { volumeUUID ?? deviceNode }
    public var deviceNode: String  // /dev/disk3s1
    public var volumeName: String
    public var volumeUUID: String?
    public var mountPoint: String?
    public var filesystemPersonality: String  // "APFS", "Case-sensitive APFS", "ExFAT", …
    public var filesystemType: String  // apfs / exfat / msdos / ntfs
    public var isInternal: Bool
    public var isRemovableMedia: Bool
    public var isEjectable: Bool
    public var busProtocol: String  // USB / Thunderbolt / PCI-Express / Disk Image / …
    public var isSolidState: Bool?
    public var isWritable: Bool
    public var ownersEnabled: Bool
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var isBootVolume: Bool  // the system or data volume of the running OS
    /// A System or Data volume of another macOS installation (by its APFS role), not the running one. Never a vault, and
    /// its disk is never prepared; told apart from the boot volume so neither says "the running system" about it.
    public var belongsToMacOSInstall: Bool = false
    public var isDiskImage: Bool { busProtocol == "Disk Image" }
    public var isAPFS: Bool { filesystemType.lowercased() == "apfs" }
    public var isExternal: Bool { !isInternal }
    /// A network file system (R6): SMB, NFS, AFP or WebDAV. Never a destination — it disconnects with the network, and
    /// its ownership and xattrs are the server's.
    public var isNetwork: Bool { Volume.isNetworkFilesystem(filesystemType) }
    public static let networkFilesystemTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"]
    public static func isNetworkFilesystem(_ type: String) -> Bool { networkFilesystemTypes.contains(type.lowercased()) }
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
        if v.belongsToMacOSInstall { blockers.append("This volume belongs to a macOS installation; XCodeVault never uses one as a vault.") }
        if v.mountPoint == nil { blockers.append("Not mounted.") }
        if v.isNetwork {
            blockers.append("This is a network volume (\(v.filesystemType)). XCodeVault needs a local disk: a network share disconnects with the network.")
        }
        if !v.isAPFS { blockers.append("Filesystem is \(v.filesystemPersonality); XCodeVault requires APFS (ownership, xattrs, clones, symlinks).") }
        if !v.isWritable { blockers.append("Volume is read-only.") }
        if !v.ownersEnabled, let mp = v.mountPoint {
            blockers.append(OwnershipAdvice.enableOwnership(mp))
        } else if !v.ownersEnabled {
            blockers.append(
                "Ownership is ignored on this volume (noowners). Enable it with `diskutil enableOwnership` — CoreSimulator/Xcode data has mixed root/user ownership."
            )
        }
        if v.freeBytes < minimumFreeBytes { warnings.append("Only \(ByteCount.english(v.freeBytes)) free; simulator runtimes are 5–25 GB each.") }
        if v.isDiskImage { warnings.append("This is a disk image, not a physical device; fine for experiments, not a durable destination.") }
        if v.busProtocol == "USB" {
            warnings.append("USB-attached: expect much lower 4K random IOPS than internal storage; DerivedData workloads are IOPS-bound (research F9).")
        }
        if v.filesystemPersonality.lowercased().contains("case-sensitive") {
            // Downgraded from a speculative "may break" to what E12 (2026-09-08) actually measured:
            // a full SwiftPM build with its scratch path here — dependency *source* included — and
            // an `xcodebuild -derivedDataPath` build both succeeded. The residual risk is real but
            // narrower than the old wording implied, and it only bites source that lives here.
            warnings.append(
                "Case-sensitive APFS (macOS default is case-insensitive). Build output and SwiftPM checkouts were verified to work on one combination — macOS 26.6.2 / Xcode 26.5 / Intel, E12 — not proven in general. The residual risk is source code that refers to a file by the wrong case: harmless on the internal volume, a build error on this one."
            )
        }
        let verdict: Verdict = blockers.isEmpty ? (warnings.isEmpty ? .suitable : .suitableWithWarnings) : .unsuitable
        return VolumeQualification(verdict: verdict, blockers: blockers, warnings: warnings)
    }
}

/// What one pass over the mounted volumes found: the volumes, and the device identifiers whose `diskutil info` could not
/// be read even on a second try. A volume in `unreadable` may well be mounted — it is unknown, never absent.
public struct VolumeEnumeration: Sendable, Equatable {
    public var volumes: [Volume]
    public var unreadable: [String]
    public init(volumes: [Volume], unreadable: [String] = []) {
        self.volumes = volumes
        self.unreadable = unreadable
    }
}

public enum VolumeDiscovery {
    /// All mounted volumes (excluding the OS's own hidden system volumes and CoreSimulator's runtime images). The volumes
    /// of `enumerate(runner:)`; a caller that must tell "not mounted" from "not read" uses that instead.
    public static func mountedVolumes(runner: CommandRunning = ProcessCommandRunner()) throws -> [Volume] {
        try enumerate(runner: runner).volumes
    }

    /// One `diskutil info` per device. A failed or unparsable one is asked again once, after a moment: on 2026-10-18 a
    /// single failed `info` on the macos-26 CI runner removed a mounted disk image from the list between two commands
    /// seconds apart, and a vault missing from it reads as not connected. One still unreadable is reported, not dropped.
    public static func enumerate(runner: CommandRunning = ProcessCommandRunner(), retryDelay: TimeInterval = 0.25) throws -> VolumeEnumeration {
        let list = try runner.check(Tools.diskutil, ["list", "-plist"])
        // A list that does not parse is an error, not "no volumes": the same collapse `unreadable` exists to prevent (L3).
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(list.stdout.utf8), format: nil) as? [String: Any],
            let all = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            throw CommandError(executable: Tools.diskutil, arguments: ["list", "-plist"], result: nil, underlying: "the volume list did not parse")
        }
        var ids: [String] = []
        for disk in all {
            for part in (disk["Partitions"] as? [[String: Any]]) ?? [] { if let id = part["DeviceIdentifier"] as? String { ids.append(id) } }
            for vol in (disk["APFSVolumes"] as? [[String: Any]]) ?? [] { if let id = vol["DeviceIdentifier"] as? String { ids.append(id) } }
        }
        // Roles come from `apfs list`: macOS 26's `info -plist` no longer carries `APFSVolumeRoles` (measured in R8), so
        // reading them there left every volume role-less. Best effort: without the listing, `parse` falls back to `info`.
        let apfs: [String: APFSVolumeInfo] = {
            guard let r = try? runner.run(Tools.diskutil, ["apfs", "list", "-plist"]), r.succeeded else { return [:] }
            return (try? apfsVolumes(Data(r.stdout.utf8))) ?? [:]
        }()
        func info(_ id: String) -> Volume? {
            guard let r = try? runner.run(Tools.diskutil, ["info", "-plist", id]), r.succeeded else { return nil }
            return try? parse(diskutilInfoPlist: Data(r.stdout.utf8), apfsVolumes: apfs)
        }
        var out: [Volume] = []
        var unreadable: [String] = []
        for id in ids {
            var read = info(id)
            if read == nil {
                if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
                read = info(id)
            }
            guard let v = read else {
                unreadable.append(id)
                continue
            }
            guard let mp = v.mountPoint, !mp.isEmpty else { continue }
            if mp.hasPrefix("/System/Volumes/") && mp != "/System/Volumes/Data" { continue }
            if mp.hasPrefix("/Library/Developer/CoreSimulator/Volumes/") { continue }
            if mp.hasPrefix("/private/var/") { continue }
            out.append(v)
        }
        return VolumeEnumeration(volumes: out, unreadable: unreadable)
    }

    /// Each APFS volume of `diskutil apfs list -plist`, by device identifier (`disk3s1`).
    public static func apfsVolumes(_ apfsList: Data) throws -> [String: APFSVolumeInfo] {
        var out: [String: APFSVolumeInfo] = [:]
        for container in try DiskTopology.parseContainers(apfsList) {
            for volume in container.volumes { out[volume.id] = volume }
        }
        return out
    }

    /// A volume's roles are the union of what `info` says (`APFSVolumeRoles`, absent on macOS 26; whether macOS 15's
    /// `info` carries it is unmeasured here) and what `apfsVolumes` says, so neither source can take a role away: a role
    /// only ever marks a volume as the boot volume's. The listing's entry is used only when its volume UUID is the
    /// volume's, where both have one: the two are read seconds apart, and a device identifier can be reused by another
    /// drive in between (migration-safety review, findings c and d).
    public static func parse(diskutilInfoPlist data: Data, apfsVolumes: [String: APFSVolumeInfo] = [:]) throws -> Volume {
        guard let d = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CommandError(executable: Tools.diskutil, arguments: ["info", "-plist"], result: nil, underlying: "not a plist")
        }
        func b(_ k: String) -> Bool { d[k] as? Bool ?? false }
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        func u(_ k: String) -> UInt64 { (d[k] as? NSNumber)?.uint64Value ?? 0 }
        let mp = s("MountPoint")
        var role = Set((d["APFSVolumeRoles"] as? [String]) ?? [])
        if let listed = apfsVolumes[s("DeviceIdentifier")] {
            // An empty UUID is a missing one (re-review, nit 2).
            let present = { (u: String?) in u.flatMap { $0.isEmpty ? nil : $0.uppercased() } }
            let infoUUID = present(d["VolumeUUID"] as? String), listedUUID = present(listed.uuid)
            if listedUUID == nil || infoUUID == nil || listedUUID == infoUUID { role.formUnion(listed.roles) }
        }
        // The running system by where it is mounted; another installation by its role, on any disk — wider than before
        // (an external install's Data volume was a candidate), so it only ever adds refusals.
        let isBoot = mp == "/" || mp == "/System/Volumes/Data"
        let otherInstall = !isBoot && (role.contains("Data") || role.contains("System"))
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
            isBootVolume: isBoot, belongsToMacOSInstall: otherInstall)
    }
}
