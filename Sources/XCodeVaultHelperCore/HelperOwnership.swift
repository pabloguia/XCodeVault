// `enableOwnership`'s volume side (R8, ADR-0014): how the helper turns a client's UUID into a volume it may touch.
//
// The client sends a UUID and nothing else. The helper resolves it itself — the mount table and `getattrlist` (the
// same reentrant lookup `createVaultDirectory` uses) — and **pins** that mount: it opens the mount point
// `O_RDONLY | O_DIRECTORY | O_NOFOLLOW` and records what `fstatfs` says of the descriptor (device node and `f_fsid`).
// Every later reading goes through the descriptor, and immediately before the command runs the helper asks the
// descriptor again: a different device or file-system id is a different volume, and refuses (fix round 1, L1).
// `diskutil info -plist <UUID>` must agree with the pin on UUID, mount point and device node.
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
    /// `fstatfs`'s `f_fstypename`: `apfs`, `hfs`, `smbfs`, …
    var filesystemType: String
    /// `diskutil`'s `Internal`.
    var isInternal: Bool
    /// `diskutil`'s `BusProtocol`: `USB`, `Thunderbolt`, `Disk Image`, …
    var busProtocol: String
    /// `fstatfs`'s `MNT_LOCAL`.
    var isLocal: Bool
    /// Not `MNT_RDONLY`, and `diskutil`'s `WritableVolume`.
    var isWritable: Bool
    /// `diskutil`'s `GlobalPermissionsEnabled`, and `MNT_IGNORE_OWNERSHIP` clear.
    var ownersEnabled: Bool
    /// `diskutil`'s `APFSVolumeRoles`; `Backup` is Time Machine, `System`/`Data` the running OS's own.
    var roles: [String]
    /// A `Backups.backupdb` or `.timemachine` at the volume's root — or a root that could not be looked at.
    var hasTimeMachineMarker: Bool
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

/// A mount held open across the verb: the descriptor of its mount point and what `fstatfs` said of it when opened.
struct MountPin: Equatable, Sendable {
    let descriptor: Int32
    let mountPoint: String
    let deviceNode: String
    let fsid: [Int32]
    /// The bare identifier of `deviceNode`: what `diskutil enableOwnership` is given (fix round 2, N2).
    let disk: DiskIdentifier
    /// The volume UUID the pin was made for, compared with the descriptor's own volume before the command (round 3).
    let uuid: UUID
}

/// The seam the verb reads volumes through. Tests inject a fake; production uses `OwnershipVolumeReader`.
protocol OwnershipVolumeReading: Sendable {
    /// Opens the mount point of the volume with that UUID, or nil when none is mounted (or it cannot be opened).
    func pin(volumeUUID: UUID) -> MountPin?
    /// The volume's facts, read through the pin.
    func lookup(volumeUUID: UUID, pin: MountPin) -> OwnershipVolumeLookup
    /// Whether the pinned descriptor still names the same device, file system and mount point, and the volume is still
    /// the only mounted one with that UUID.
    func isUnchanged(_ pin: MountPin) -> Bool
    func release(_ pin: MountPin)
}

enum HelperOwnership {
    static let fileSystemsAllowed: Set<String> = ["apfs", "hfs"]
    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"]

    /// Why the verb must not touch this volume, in fixed words, or nil when it may. Pure, so every refusal is tested.
    /// The messages go to the audit `.public`, so none quotes a name, a path or a device node.
    static func refusal(_ f: OwnershipVolumeFacts) -> String? {
        if !isVolumeDeviceNode(f.deviceNode) { return "not a volume device node" }
        if f.mountPoint == "/" || f.mountPoint.hasPrefix("/System/Volumes") || f.roles.contains("System") || f.roles.contains("Data") && f.isInternal {
            return "this is the running system's volume"
        }
        if f.sharesTheBootContainer { return "this volume shares a container or disk with the running system" }
        if f.isInternal { return "only an external volume is eligible" }
        if networkFileSystems.contains(f.filesystemType.lowercased()) || !f.isLocal { return "a network volume is not eligible" }
        if !fileSystemsAllowed.contains(f.filesystemType.lowercased()) { return "only APFS and HFS+ volumes are eligible" }
        if f.busProtocol == "Disk Image" || f.isDiskImageOrVirtual { return "a disk image is not eligible" }
        if f.roles.contains("Backup") || f.hasTimeMachineMarker { return "a Time Machine backup is not eligible" }
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

    /// The one mount point, or nil when there is none or more than one (N2 / F3): pure, so the refusal is tested.
    static func soleMountPoint(_ mounts: [String]) -> String? { mounts.count == 1 ? mounts.first : nil }

    /// Every mount point whose volume has this UUID. More than one refuses: two mounted volumes carrying one UUID (a
    /// cloned volume, a disk image of one) leave "the volume" undefined (fix round 2, N2 / data F3).
    static func mountPoints(forVolumeUUID wanted: UUID) -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard n > 0, let mounts else { return [] }
        defer { free(mounts) }
        var out: [String] = []
        for i in 0..<Int(n) {
            var fs = mounts[i]
            let mp = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            if HelperService.volumeUUID(ofMountPoint: mp) == wanted { out.append(mp) }
        }
        return out
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
            ownersEnabled: d["GlobalPermissionsEnabled"] as? Bool ?? false, roles: d["APFSVolumeRoles"] as? [String] ?? [],
            containerReference: d["APFSContainerReference"] as? String, isDiskImageOrVirtual: imageKey || virtual)
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

    /// Facts from the pinned mount's `fstatfs` and the plist, refusing when they do not describe the same volume.
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
                sharesTheBootContainer: sharesBoot(node: info.deviceNode, container: info.containerReference, bootNodes: bootNodes),
                isDiskImageOrVirtual: info.isDiskImageOrVirtual))
    }
}

/// The live reader: the mount table, the pinned descriptor's `fstatfs`, and `diskutil info -plist` through `runner`.
/// Never run by a test with the live runner: it reads this Mac's volumes.
struct OwnershipVolumeReader: OwnershipVolumeReading {
    let runner: any DiskutilRunning

    func pin(volumeUUID wanted: UUID) -> MountPin? {
        guard wanted != HelperService.nilVolumeUUID else { return nil }
        guard let mp = HelperOwnership.soleMountPoint(HelperOwnership.mountPoints(forVolumeUUID: wanted)) else { return nil }
        let fd = open(mp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        // The descriptor must be the root of a mount at exactly that point: a symlink or a plain directory is not.
        guard let fs = Self.fstatfsOf(fd), fs.mountedOn == mp, let disk = HelperOwnership.diskIdentifier(ofDeviceNode: fs.node) else {
            close(fd)
            return nil
        }
        return MountPin(descriptor: fd, mountPoint: mp, deviceNode: fs.node, fsid: fs.fsid, disk: disk, uuid: wanted)
    }

    func lookup(volumeUUID wanted: UUID, pin: MountPin) -> OwnershipVolumeLookup {
        guard let fs = Self.fstatfsOf(pin.descriptor), fs.node == pin.deviceNode, fs.fsid == pin.fsid else { return .unreadable("the volume changed") }
        let output = runner.run(.infoPlist(volumeUUID: wanted))
        guard output.succeeded, let info = HelperOwnership.parseInfo(output.stdout) else { return .unreadable("diskutil info failed") }
        let bootNodes = ["/", "/System/Volumes/Data"].compactMap { Self.statfsNode($0) }
        let marker = ["Backups.backupdb", ".timemachine"].contains { name in
            // Present, or not known to be absent: a root that cannot be looked at may hold a backup, and refuses.
            var st = stat()
            return fstatat(pin.descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
        }
        return HelperOwnership.facts(
            wanted: wanted, mountPoint: pin.mountPoint, statfsNode: fs.node, statfsType: fs.type, statfsFlags: fs.flags, info: info,
            bootNodes: bootNodes, hasTimeMachineMarker: marker)
    }

    func isUnchanged(_ pin: MountPin) -> Bool {
        guard let fs = Self.fstatfsOf(pin.descriptor), fs.node == pin.deviceNode, fs.fsid == pin.fsid, fs.mountedOn == pin.mountPoint,
            HelperOwnership.diskIdentifier(ofDeviceNode: fs.node) == pin.disk
        else { return false }
        // The descriptor's own volume still has the pinned UUID, read through the descriptor (getattrlistat on "."),
        // and it is still the only mounted volume with it.
        guard HelperService.volumeUUID(ofDescriptor: pin.descriptor) == pin.uuid else { return false }
        return HelperOwnership.soleMountPoint(HelperOwnership.mountPoints(forVolumeUUID: pin.uuid)) == pin.mountPoint
    }

    func release(_ pin: MountPin) { close(pin.descriptor) }

    static func fstatfsOf(_ fd: Int32) -> (node: String, mountedOn: String, type: String, flags: UInt32, fsid: [Int32])? {
        var s = statfs()
        guard fstatfs(fd, &s) == 0 else { return nil }
        return (cString(&s.f_mntfromname), cString(&s.f_mntonname), cString(&s.f_fstypename), s.f_flags, [s.f_fsid.val.0, s.f_fsid.val.1])
    }

    static func statfsNode(_ path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return cString(&s.f_mntfromname)
    }

    private static func cString<T>(_ field: inout T) -> String {
        withUnsafePointer(to: &field) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }
}
