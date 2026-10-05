// `enableOwnership`'s volume side (R8, ADR-0014): how the helper turns a client's UUID into a volume it may touch.
//
// The client sends a UUID and nothing else. The helper resolves it itself — the mount table and `getattrlist` (the
// same reentrant lookup `createVaultDirectory` uses), then `statfs` on that mount point, then `diskutil info -plist
// <UUID>` — and refuses unless all three agree on the volume's identity: the plist's UUID is the one asked for, its
// mount point is the one the mount table gave, and its device node is the one `statfs` gave. The device node the
// command later runs on is the helper's own reading, never anything that crossed the wire.
//
// **Why this duplicates Core rather than reusing it.** `VolumeQualification` and `DiskSafety` live in `XCodeVaultCore`,
// which the helper targets may not link (`Package.swift`; `scripts/helper-invariants.sh` checks the closure). The
// questions are the same and are answered from the same `diskutil info -plist` keys Core's `VolumeDiscovery.parse`
// reads; `HelperOwnershipTests` holds the two to the same refusals over the same fixtures.

import Foundation
import XCodeVaultHelperProtocol

/// What the helper read about one mounted volume.
struct OwnershipVolumeFacts: Equatable, Sendable {
    var deviceNode: String
    var mountPoint: String
    /// `statfs`'s `f_fstypename`: `apfs`, `hfs`, `smbfs`, …
    var filesystemType: String
    /// `diskutil`'s `Internal`.
    var isInternal: Bool
    /// `diskutil`'s `BusProtocol`: `USB`, `Thunderbolt`, `Disk Image`, …
    var busProtocol: String
    /// `statfs`'s `MNT_LOCAL`.
    var isLocal: Bool
    /// Not `MNT_RDONLY`, and `diskutil`'s `WritableVolume`.
    var isWritable: Bool
    /// `diskutil`'s `GlobalPermissionsEnabled`, and `MNT_IGNORE_OWNERSHIP` clear.
    var ownersEnabled: Bool
    /// `diskutil`'s `APFSVolumeRoles`; `Backup` is Time Machine, `System`/`Data` the running OS's own.
    var roles: [String]
    /// A `Backups.backupdb` or `.timemachine` at the volume's root: an HFS+ backup disk has no role to read.
    var hasTimeMachineMarker: Bool
    /// The volume is the running system's, or lives in the same container / on the same disk as it.
    var sharesTheBootContainer: Bool
}

enum OwnershipVolumeLookup: Equatable, Sendable {
    case found(OwnershipVolumeFacts)
    /// No mounted volume has that UUID.
    case notMounted
    /// It is mounted, and its identity could not be read consistently. A fixed reason.
    case unreadable(String)
}

/// The seam the verb reads volumes through. Tests inject a fake; production uses `OwnershipVolumeReader`.
protocol OwnershipVolumeReading: Sendable {
    func lookup(volumeUUID: UUID) -> OwnershipVolumeLookup
}

enum HelperOwnership {
    static let fileSystemsAllowed: Set<String> = ["apfs", "hfs"]
    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"]

    /// Why the verb must not touch this volume, in fixed words, or nil when it may. Pure, so every refusal is tested.
    /// The messages go to the audit `.public`, so none quotes a name, a path or a device node.
    static func refusal(_ f: OwnershipVolumeFacts) -> String? {
        if !DiskutilInvocation.isVolumeDeviceNode(f.deviceNode) { return "not a volume device node" }
        if f.mountPoint == "/" || f.mountPoint.hasPrefix("/System/Volumes") || f.roles.contains("System") || f.roles.contains("Data") && f.isInternal {
            return "this is the running system's volume"
        }
        if f.sharesTheBootContainer { return "this volume shares a container or disk with the running system" }
        if f.isInternal { return "only an external volume is eligible" }
        if networkFileSystems.contains(f.filesystemType.lowercased()) || !f.isLocal { return "a network volume is not eligible" }
        if !fileSystemsAllowed.contains(f.filesystemType.lowercased()) { return "only APFS and HFS+ volumes are eligible" }
        if f.busProtocol == "Disk Image" { return "a disk image is not eligible" }
        if f.roles.contains("Backup") || f.hasTimeMachineMarker { return "a Time Machine backup is not eligible" }
        if !f.isWritable { return "the volume is read-only" }
        return nil
    }

    /// The fields of `diskutil info -plist` this verb reads, or nil when it is not that plist.
    struct InfoPlist: Equatable, Sendable {
        var volumeUUID: String
        var deviceNode: String
        var mountPoint: String
        var isInternal: Bool
        var busProtocol: String
        var isWritable: Bool
        var ownersEnabled: Bool
        var roles: [String]
        var containerReference: String?
    }

    static func parseInfo(_ data: Data) -> InfoPlist? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        guard let uuid = d["VolumeUUID"] as? String, let node = d["DeviceNode"] as? String, let mp = d["MountPoint"] as? String else { return nil }
        func b(_ k: String) -> Bool { d[k] as? Bool ?? false }
        return InfoPlist(
            volumeUUID: uuid, deviceNode: node, mountPoint: mp, isInternal: b("Internal"), busProtocol: d["BusProtocol"] as? String ?? "",
            isWritable: b("WritableVolume"), ownersEnabled: b("GlobalPermissionsEnabled"), roles: d["APFSVolumeRoles"] as? [String] ?? [],
            containerReference: d["APFSContainerReference"] as? String)
    }

    /// `/dev/disk3s1` → `disk3`, the container (APFS) or whole disk (a partition) the node lives on.
    static func diskOf(_ node: String) -> String? {
        let bare = node.hasPrefix("/dev/") ? String(node.dropFirst(5)) : node
        guard bare.hasPrefix("disk") else { return nil }
        let digits = bare.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : "disk" + digits
    }

    /// Whether `node` (or its container `container`) is where the running system lives: the disk of `/` or of
    /// `/System/Volumes/Data`, as `statfs` reports them.
    static func sharesBoot(node: String, container: String?, bootNodes: [String]) -> Bool {
        let boot = Set(bootNodes.compactMap(diskOf))
        guard !boot.isEmpty else { return true }  // cannot tell where the system is: treat everything as its own
        if let d = diskOf(node), boot.contains(d) { return true }
        if let container, boot.contains(container) { return true }
        return false
    }

    /// Facts from the three readings, refusing when they do not describe the same volume.
    static func facts(
        wanted: UUID, mountPoint: String, statfsNode: String, statfsType: String, statfsFlags: UInt32, info: InfoPlist,
        bootNodes: [String], hasTimeMachineMarker: Bool
    ) -> OwnershipVolumeLookup {
        guard UUID(uuidString: info.volumeUUID) == wanted else { return .unreadable("diskutil described a different volume") }
        guard info.mountPoint == mountPoint else { return .unreadable("diskutil and the mount table disagree on the mount point") }
        guard info.deviceNode == statfsNode else { return .unreadable("diskutil and statfs disagree on the device node") }
        let readOnly = statfsFlags & UInt32(MNT_RDONLY) != 0
        let ignoresOwnership = statfsFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        return .found(
            OwnershipVolumeFacts(
                deviceNode: info.deviceNode, mountPoint: mountPoint, filesystemType: statfsType, isInternal: info.isInternal,
                busProtocol: info.busProtocol, isLocal: statfsFlags & UInt32(MNT_LOCAL) != 0, isWritable: !readOnly && info.isWritable,
                ownersEnabled: info.ownersEnabled && !ignoresOwnership, roles: info.roles, hasTimeMachineMarker: hasTimeMachineMarker,
                sharesTheBootContainer: sharesBoot(node: info.deviceNode, container: info.containerReference, bootNodes: bootNodes)))
    }
}

/// The live reader: the mount table, `statfs`, and `diskutil info -plist` through `runner`. Never run by a test with
/// the live runner: it reads this Mac's volumes.
struct OwnershipVolumeReader: OwnershipVolumeReading {
    let runner: any DiskutilRunning

    func lookup(volumeUUID wanted: UUID) -> OwnershipVolumeLookup {
        guard let mp = HelperService.mountPoint(forVolumeUUID: wanted.uuidString) else { return .notMounted }
        guard let fs = Self.statfsOf(mp) else { return .unreadable("statfs failed") }
        let output = runner.run(.infoPlist(volumeUUID: wanted))
        guard output.succeeded, let info = HelperOwnership.parseInfo(output.stdout) else { return .unreadable("diskutil info failed") }
        let bootNodes = ["/", "/System/Volumes/Data"].compactMap { Self.statfsOf($0)?.node }
        let marker = ["Backups.backupdb", ".timemachine"].contains { name in
            // Present, or not known to be absent: a root that cannot be looked at may hold a backup, and refuses.
            var st = stat()
            return lstat(mp + "/" + name, &st) == 0 || errno != ENOENT
        }
        return HelperOwnership.facts(
            wanted: wanted, mountPoint: mp, statfsNode: fs.node, statfsType: fs.type, statfsFlags: fs.flags, info: info, bootNodes: bootNodes,
            hasTimeMachineMarker: marker)
    }

    static func statfsOf(_ path: String) -> (node: String, type: String, flags: UInt32)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let node = withUnsafePointer(to: &s.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let type = withUnsafePointer(to: &s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        return (node, type, s.f_flags)
    }
}
