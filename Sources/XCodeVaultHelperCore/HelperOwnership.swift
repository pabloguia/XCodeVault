// `enableOwnership`'s volume side (R8, ADR-0014): how the helper turns a client's UUID into a volume it may touch.
//
// The client sends a UUID and nothing else. The helper resolves it itself, **without touching a single file on the
// volume** (fix round 6): a root launchd daemon is refused access to a removable volume by TCC — measured as
// [LIKELY] in the H18 re-test, where the daemon's `getattrlist`/`open` on the mount point failed while the same
// code as the user found the volume. So identity comes only from sources TCC does not gate:
//
//   - `diskutil info -plist <UUID>` (DiskArbitration): the volume's device node, mount point and facts;
//   - the mount table (`getmntinfo_r_np`, reading statfs entries, not files): exactly one entry at that mount point,
//     exactly one with that device node, and they are the same entry; its `f_fsid`, type and flags are pinned;
//   - `diskutil list -plist`: the UUID is carried by exactly one volume or partition on this Mac;
//   - `diskutil apfs list -plist`: the volume's APFS roles, which must be present and empty (fix round 7, H1: `info`
//     carries no roles on macOS 26.7.1).
//
// The mount entry must be `nosuid` and `nodev` (fix round 7, M1). Immediately before the command all of it is read again
// and must still agree with the pin, the mount table last. No descriptor is held:
// the window is the device-node reassignment the reviews already accepted (ADR-0014, SECURITY_MODEL).
// `scripts/helper-invariants.sh` forbids every file-access call in this file and in the verb.
//
// **Why this duplicates Core rather than reusing it.** `VolumeQualification` and `DiskSafety` live in `XCodeVaultCore`,
// which the helper targets may not link (`Package.swift`; `scripts/helper-invariants.sh` checks the closure). The
// questions are the same and are answered from the same `diskutil info -plist` keys Core's `VolumeDiscovery.parse`
// reads; `R8HelperOwnershipTests` holds the two to the same refusals over the same facts. Unlike Core, the helper
// fails closed on a missing key (fix round 1, M2): a plist without `Internal`, `BusProtocol` or `WritableVolume` is not
// one it can judge.

import Foundation
import XCodeVaultHelperProtocol

/// What the helper read about one mounted volume.
struct OwnershipVolumeFacts: Equatable, Sendable {
    var deviceNode: String
    var mountPoint: String
    /// The mount entry's `f_fstypename`: `apfs`, `hfs`, `smbfs`, …
    var filesystemType: String
    /// `diskutil`'s `Internal`.
    var isInternal: Bool
    /// `diskutil`'s `BusProtocol`: `USB`, `Thunderbolt`, `Disk Image`, …
    var busProtocol: String
    /// The mount entry's `MNT_LOCAL`.
    var isLocal: Bool
    /// Not `MNT_RDONLY`, and `diskutil`'s `WritableVolume`.
    var isWritable: Bool
    /// `diskutil`'s `GlobalPermissionsEnabled`, and `MNT_IGNORE_OWNERSHIP` clear.
    var ownersEnabled: Bool
    /// The volume's APFS roles from `diskutil apfs list -plist` (fix round 7, H1: `info -plist` has no roles key on
    /// macOS 26.7.1), or nil when they could not be read — which refuses. Only an empty set is eligible: an external data
    /// volume has none; `Backup` is Time Machine, `System`/`Data` the running OS's own.
    var roles: [String]?
    /// The volume is the running system's, or lives in the same container / on the same disk as it.
    var sharesTheBootContainer: Bool
    /// A disk image, or virtual: a key naming a disk image, or `VirtualOrPhysical` = `Virtual`.
    var isDiskImageOrVirtual: Bool = false
}

enum OwnershipVolumeLookup: Equatable, Sendable {
    case found(OwnershipVolumeFacts)
    /// No mounted volume has that UUID.
    case notMounted
    /// It is mounted, and its identity could not be read consistently. A fixed reason.
    case unreadable(String)
}

/// One entry of the mount table, as `getmntinfo_r_np` gives it. Reading the table reads no file: TCC does not gate it.
struct MountEntry: Equatable, Sendable {
    let mountedOn: String
    let from: String
    let type: String
    let flags: UInt32
    let fsid: [Int32]
}

/// The volume as identified before anything is decided (fix round 6): the one mount-table entry that diskutil's mount
/// point and device node both name, and the UUID diskutil was asked about. Nothing is held open.
struct MountPin: Equatable, Sendable {
    let mountPoint: String
    let deviceNode: String
    let fsid: [Int32]
    let flags: UInt32
    let fileSystemType: String
    /// The validated identifier of `deviceNode`; `diskutil enableOwnership` is given its `/dev/` path (fix rounds 2 and 7).
    let disk: DiskIdentifier
    /// The volume UUID the pin was made for.
    let uuid: UUID
}

/// The seam the verb reads volumes through. Tests inject a fake; production uses `OwnershipVolumeReader`.
protocol OwnershipVolumeReading: Sendable {
    /// The volume with that UUID, identified from diskutil and the mount table, or nil when there is none, or not
    /// exactly one.
    func pin(volumeUUID: UUID) -> MountPin?
    /// The volume's facts: the pinned mount entry (still at its mount point, with the same device node and `f_fsid`)
    /// and diskutil's plist. Its flags are read anew, so a change in `MNT_IGNORE_OWNERSHIP` shows.
    func lookup(volumeUUID: UUID, pin: MountPin) -> OwnershipVolumeLookup
    /// Whether the mount table, diskutil and the UUID's uniqueness all still say what they said when the pin was made.
    func isUnchanged(_ pin: MountPin) -> Bool
}

enum HelperOwnership {
    /// APFS only (fix round 6): Time Machine is detected by the APFS `Backup` role, which an HFS+ volume does not
    /// carry, and the helper no longer looks for a marker file on the volume.
    static let fileSystemsAllowed: Set<String> = ["apfs"]
    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"]

    /// Why the verb must not touch this volume, in fixed words, or nil when it may. Pure, so every refusal is tested.
    /// The messages go to the audit `.public`, so none quotes a name, a path or a device node.
    static func refusal(_ f: OwnershipVolumeFacts) -> String? {
        if !isVolumeDeviceNode(f.deviceNode) { return "not a volume device node" }
        let knownRoles = f.roles ?? []
        if f.mountPoint == "/" || f.mountPoint.hasPrefix("/System/Volumes") || knownRoles.contains("System") || knownRoles.contains("Data") && f.isInternal {
            return "this is the running system's volume"
        }
        if f.sharesTheBootContainer { return "this volume shares a container or disk with the running system" }
        if f.isInternal { return "only an external volume is eligible" }
        if networkFileSystems.contains(f.filesystemType.lowercased()) || !f.isLocal { return "a network volume is not eligible" }
        if !fileSystemsAllowed.contains(f.filesystemType.lowercased()) { return "only an APFS volume is eligible" }
        if f.busProtocol == "Disk Image" || f.isDiskImageOrVirtual { return "a disk image is not eligible" }
        guard let roles = f.roles else { return "the volume's APFS roles could not be read" }
        if roles.contains("Backup") { return "a Time Machine backup is not eligible" }
        if !roles.isEmpty { return "a volume with an APFS role is not eligible" }
        if !f.isWritable { return "the volume is read-only" }
        return nil
    }

    /// `/dev/disk<N>s<M>`, ASCII digits only, nothing else: the shape of a volume's device node. Checked on bytes — a
    /// grapheme-level check can be fooled by a combining mark, the kernel cannot. No whole disk (`/dev/disk4`), no
    /// snapshot (`/dev/disk3s1s1`), no raw node. The command takes the pinned mount's disk identifier (`DiskIdentifier`,
    /// fix round 2, N2); this is the same shape asked of a device node, for the eligibility refusal.
    static func isVolumeDeviceNode(_ node: String) -> Bool { diskIdentifier(ofDeviceNode: node) != nil }

    /// `/dev/disk5s1` → `disk5s1`, validated; nil for anything else.
    static func diskIdentifier(ofDeviceNode node: String) -> DiskIdentifier? {
        guard node.hasPrefix("/dev/") else { return nil }
        return DiskIdentifier(String(node.dropFirst(5)))
    }

    /// How many volumes and partitions `diskutil list -plist` lists with this UUID, or nil when the output is not that
    /// plist. Whole disks, partitions and APFS volumes are all counted, mounted or not: two that carry one UUID (a
    /// cloned volume, an attached image of one) leave "the volume" undefined (fix round 2, N2), and refuse.
    static func volumeUUIDCount(inListPlist data: Data, wanted: UUID) -> Int? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let disks = d["AllDisksAndPartitions"] as? [[String: Any]]
        else { return nil }
        var entries: [[String: Any]] = []
        for disk in disks {
            entries.append(disk)
            for key in ["Partitions", "APFSVolumes"] {
                guard let nested = disk[key] else { continue }
                guard let list = nested as? [[String: Any]] else { return nil }
                entries.append(contentsOf: list)
            }
        }
        return entries.filter { ($0["VolumeUUID"] as? String).flatMap { UUID(uuidString: $0) } == wanted }.count
    }

    /// The volume's APFS roles in `diskutil apfs list -plist` (`Containers[].Volumes[].Roles`), or nil — which refuses —
    /// unless the output is that plist, the volume whose `DeviceIdentifier` is `disk` appears in it exactly once, and its
    /// `Roles` is present as a list of strings (fix round 7, H1). Measured on macOS 26.7.1: an external data volume's
    /// roles are `[]`; `info -plist` carries no roles at all.
    static func roles(inAPFSListPlist data: Data, disk: DiskIdentifier) -> [String]? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let containers = d["Containers"] as? [[String: Any]]
        else { return nil }
        var found: [[String: Any]] = []
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { return nil }
            found.append(contentsOf: volumes.filter { $0["DeviceIdentifier"] as? String == disk.value })
        }
        guard found.count == 1 else { return nil }
        return found[0]["Roles"] as? [String]
    }

    /// Both `MNT_NOSUID` and `MNT_NODEV` (fix round 7, M1): a mount without them is not one this verb touches, so if the
    /// device node is reassigned between the re-check and the command, what it lands on cannot carry a setuid binary
    /// or a device node either. Measured: external and disk-image mounts carry both.
    static func isNosuidNodev(_ flags: UInt32) -> Bool {
        let both = UInt32(MNT_NOSUID) | UInt32(MNT_NODEV)
        return flags & both == both
    }

    /// The pin, when diskutil and the mount table name one and the same volume (fix round 6). Pure, so every refusal
    /// is tested: a missing plist, another UUID, a UUID on more than one volume, no mount entry or more than one at the
    /// plist's mount point or with its device node, the two being different entries, or a device node that is not a
    /// volume's.
    static func pin(wanted: UUID, info: InfoPlist?, mounts: [MountEntry]?, uuidCount: Int?) -> MountPin? {
        guard let info, UUID(uuidString: info.volumeUUID) == wanted, uuidCount == 1, let mounts else { return nil }
        let atPoint = mounts.filter { $0.mountedOn == info.mountPoint }
        let fromNode = mounts.filter { $0.from == info.deviceNode }
        guard atPoint.count == 1, fromNode.count == 1, atPoint[0] == fromNode[0] else { return nil }
        let entry = atPoint[0]
        guard isNosuidNodev(entry.flags), let disk = diskIdentifier(ofDeviceNode: entry.from) else { return nil }
        return MountPin(
            mountPoint: entry.mountedOn, deviceNode: entry.from, fsid: entry.fsid, flags: entry.flags, fileSystemType: entry.type, disk: disk,
            uuid: wanted)
    }

    /// The pinned mount's entry, still at its mount point with the same device node and `f_fsid`, and the only one at
    /// either; nil otherwise. Flags are not compared here: the post-verify reads them anew.
    static func entry(of pin: MountPin, in mounts: [MountEntry]?) -> MountEntry? {
        guard let mounts else { return nil }
        let atPoint = mounts.filter { $0.mountedOn == pin.mountPoint }
        guard atPoint.count == 1, mounts.filter({ $0.from == pin.deviceNode }).count == 1 else { return nil }
        let e = atPoint[0]
        return e.from == pin.deviceNode && e.fsid == pin.fsid ? e : nil
    }

    /// The re-check before the command (fix rounds 6 and 7): diskutil still describing the pinned volume at that mount
    /// point and device node; the UUID still on exactly one volume; its APFS roles still present and empty; and the same
    /// mount entry, with the same flags, still `nosuid` and `nodev`. The live reader reads the mount table last (M1).
    static func isUnchanged(_ pin: MountPin, info: InfoPlist?, uuidCount: Int?, roles: [String]?, mounts: [MountEntry]?) -> Bool {
        guard let info, UUID(uuidString: info.volumeUUID) == pin.uuid, info.mountPoint == pin.mountPoint, info.deviceNode == pin.deviceNode
        else { return false }
        guard uuidCount == 1, roles == [] else { return false }
        guard let e = entry(of: pin, in: mounts), e.flags == pin.flags, e.type == pin.fileSystemType else { return false }
        return isNosuidNodev(e.flags)
    }

    /// The device nodes of `/` and `/System/Volumes/Data`, from the mount table: where the running system lives.
    static func bootNodes(_ mounts: [MountEntry]) -> [String] {
        mounts.filter { $0.mountedOn == "/" || $0.mountedOn == "/System/Volumes/Data" }.map(\.from)
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
        var containerReference: String?
        var isDiskImageOrVirtual: Bool = false
    }

    /// Nil — which refuses — unless the identity keys and the three keys eligibility rests on (`Internal`, `BusProtocol`,
    /// `WritableVolume`) are present with their types (fix round 1, M2): a missing `Internal` must not read as "external".
    static func parseInfo(_ data: Data) -> InfoPlist? {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        guard let uuid = d["VolumeUUID"] as? String, let node = d["DeviceNode"] as? String, let mp = d["MountPoint"] as? String,
            let isInternal = d["Internal"] as? Bool, let bus = d["BusProtocol"] as? String, let writable = d["WritableVolume"] as? Bool
        else { return nil }
        let imageKey = d.keys.contains { $0.range(of: "DiskImage", options: .caseInsensitive) != nil }
        let virtual = (d["VirtualOrPhysical"] as? String)?.caseInsensitiveCompare("Virtual") == .orderedSame || d["Virtual"] as? Bool == true
        return InfoPlist(
            volumeUUID: uuid, deviceNode: node, mountPoint: mp, isInternal: isInternal, busProtocol: bus, isWritable: writable,
            ownersEnabled: d["GlobalPermissionsEnabled"] as? Bool ?? false, containerReference: d["APFSContainerReference"] as? String,
            isDiskImageOrVirtual: imageKey || virtual)
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

    /// Facts from the pinned mount's entry, the plist and the roles `apfs list` gave (nil when it could not be read),
    /// refusing when the entry and the plist do not describe the same volume.
    static func facts(wanted: UUID, entry: MountEntry, info: InfoPlist, roles: [String]?, bootNodes: [String]) -> OwnershipVolumeLookup {
        guard UUID(uuidString: info.volumeUUID) == wanted else { return .unreadable("diskutil described a different volume") }
        guard info.mountPoint == entry.mountedOn else { return .unreadable("diskutil and the mount table disagree on the mount point") }
        guard info.deviceNode == entry.from else { return .unreadable("diskutil and the mount table disagree on the device node") }
        let readOnly = entry.flags & UInt32(MNT_RDONLY) != 0
        let ignoresOwnership = entry.flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        return .found(
            OwnershipVolumeFacts(
                deviceNode: info.deviceNode, mountPoint: entry.mountedOn, filesystemType: entry.type, isInternal: info.isInternal,
                busProtocol: info.busProtocol, isLocal: entry.flags & UInt32(MNT_LOCAL) != 0, isWritable: !readOnly && info.isWritable,
                ownersEnabled: info.ownersEnabled && !ignoresOwnership, roles: roles,
                sharesTheBootContainer: sharesBoot(node: info.deviceNode, container: info.containerReference, bootNodes: bootNodes),
                isDiskImageOrVirtual: info.isDiskImageOrVirtual))
    }
}

/// The live reader: the mount table and `diskutil` through `runner`, and nothing else — no path on the volume is
/// opened, stat'ed or asked for attributes (fix round 6; `helper-invariants.sh`). Never run by a test with the live
/// runner: it reads this Mac's volumes.
struct OwnershipVolumeReader: OwnershipVolumeReading {
    let runner: any DiskutilRunning
    /// The mount table; a test seam. Production reads `getmntinfo_r_np`.
    var readMounts: @Sendable () -> [MountEntry]? = { OwnershipVolumeReader.mountTable() }

    func pin(volumeUUID wanted: UUID) -> MountPin? {
        guard wanted != HelperService.nilVolumeUUID else { return nil }
        return HelperOwnership.pin(wanted: wanted, info: info(wanted), mounts: readMounts(), uuidCount: uuidCount(wanted))
    }

    func lookup(volumeUUID wanted: UUID, pin: MountPin) -> OwnershipVolumeLookup {
        guard let info = info(wanted) else { return .unreadable("diskutil info failed") }
        let roles = roles(pin.disk)
        let mounts = readMounts()
        guard let entry = HelperOwnership.entry(of: pin, in: mounts), let mounts else { return .unreadable("the volume changed") }
        return HelperOwnership.facts(wanted: wanted, entry: entry, info: info, roles: roles, bootNodes: HelperOwnership.bootNodes(mounts))
    }

    /// In this order, so the mount table — the reading a lost race would change — is the last thing read before the
    /// command (fix round 7, M1).
    func isUnchanged(_ pin: MountPin) -> Bool {
        let info = info(pin.uuid)
        let count = uuidCount(pin.uuid)
        let roles = roles(pin.disk)
        let mounts = readMounts()
        return HelperOwnership.isUnchanged(pin, info: info, uuidCount: count, roles: roles, mounts: mounts)
    }

    private func info(_ uuid: UUID) -> HelperOwnership.InfoPlist? {
        let output = runner.run(.infoPlist(volumeUUID: uuid))
        return output.succeeded ? HelperOwnership.parseInfo(output.stdout) : nil
    }

    private func roles(_ disk: DiskIdentifier) -> [String]? {
        let output = runner.run(.apfsListPlist)
        return output.succeeded ? HelperOwnership.roles(inAPFSListPlist: output.stdout, disk: disk) : nil
    }

    private func uuidCount(_ uuid: UUID) -> Int? {
        let output = runner.run(.listPlist)
        return output.succeeded ? HelperOwnership.volumeUUIDCount(inListPlist: output.stdout, wanted: uuid) : nil
    }

    /// The whole mount table, or nil when it cannot be read.
    static func mountTable() -> [MountEntry]? {
        var table: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard n > 0, let table else { return nil }
        defer { free(table) }
        return (0..<Int(n)).map { i in
            var e = table[i]
            return MountEntry(
                mountedOn: cString(&e.f_mntonname), from: cString(&e.f_mntfromname), type: cString(&e.f_fstypename), flags: e.f_flags,
                fsid: [e.f_fsid.val.0, e.f_fsid.val.1])
        }
    }

    private static func cString<T>(_ field: inout T) -> String {
        withUnsafePointer(to: &field) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }
}
