import Foundation

// R6 (ADR-0012): per external disk, one verdict and the ways to prepare it, least destructive first. Pure functions of a
// `DriveSnapshot` and the vault registry; the app draws what these return and decides nothing.
//
// EXPERIMENTAL (CLAUDE.md rule 10): every preparation option. H17 measured the commands on disk images only.

/// Why a disk may not be erased or partitioned. Decided in one place, `DiskSafety`, and checked twice: when the options
/// are offered and again immediately before a command runs.
public enum DiskRefusal: String, Sendable, Codable, CaseIterable {
    /// An internal disk. XCodeVault frees the internal disk; it never prepares one.
    case internalDisk
    /// The disk holds the running system (the boot volume or its container).
    case bootDisk
    /// A disk image: it backs something mounted (a simulator runtime, an installer), never a drive to prepare.
    case diskImage
    /// One of its volumes is a registered vault: erasing it would destroy a vault and everything parked on it.
    case holdsVault
    /// One of its volumes is a Time Machine backup.
    case timeMachine
    /// The disk's media is read-only.
    case readOnlyMedia

    /// English, for Core's own prose and the journal; the app has its own words.
    public var reason: String {
        switch self {
        case .internalDisk: "This is an internal disk. XCodeVault never erases or partitions an internal disk."
        case .bootDisk: "This disk holds the running system."
        case .diskImage: "This is a disk image, not a drive."
        case .holdsVault: "This disk holds a registered vault. Erasing it would destroy the vault and everything parked on it."
        case .timeMachine: "This disk holds a Time Machine backup."
        case .readOnlyMedia: "This disk's media is read-only."
        }
    }
}

/// The central guard. Every option that changes a disk is offered only when `refusals` for that change is empty, and
/// `DiskPreparation.revalidate` asks again, on a fresh snapshot, right before the command runs.
public enum DiskSafety {
    /// What forbids ANY change to `disk` — even adding a volume, which erases nothing: internal, boot, disk image,
    /// Time Machine, read-only media.
    public static func changeRefusals(_ disk: PhysicalDisk, in snapshot: DriveSnapshot) -> [DiskRefusal] {
        var out: [DiskRefusal] = []
        if disk.isInternal { out.append(.internalDisk) }
        if snapshot.bootDiskIDs.contains(disk.id) { out.append(.bootDisk) }
        if disk.isDiskImage { out.append(.diskImage) }
        if holdsTimeMachine(disk, in: snapshot) { out.append(.timeMachine) }
        if !disk.isWritable { out.append(.readOnlyMedia) }
        return out
    }

    /// What forbids ERASING anything on `disk` (one volume or the whole disk): every change refusal, plus a registered
    /// vault on any of its volumes — registered, whether or not it is usable right now.
    public static func eraseRefusals(_ disk: PhysicalDisk, in snapshot: DriveSnapshot, registeredVaultUUIDs: Set<String>) -> [DiskRefusal] {
        var out = changeRefusals(disk, in: snapshot)
        if holdsVault(disk, in: snapshot, registeredVaultUUIDs: registeredVaultUUIDs) { out.append(.holdsVault) }
        return out
    }

    public static func holdsTimeMachine(_ disk: PhysicalDisk, in snapshot: DriveSnapshot) -> Bool {
        disk.containers.contains { $0.volumes.contains(where: \.isTimeMachine) }
            || disk.volumeIDs.contains(where: snapshot.timeMachineMarkedVolumeIDs.contains)
    }

    /// Any volume of `disk` — APFS or a plain partition, mounted or not — whose UUID is a registered vault's.
    public static func holdsVault(_ disk: PhysicalDisk, in snapshot: DriveSnapshot, registeredVaultUUIDs: Set<String>) -> Bool {
        let wanted = Set(registeredVaultUUIDs.map { $0.uppercased() })
        let uuids =
            disk.containers.flatMap { $0.volumes.compactMap(\.uuid) } + disk.partitions.compactMap(\.volumeUUID)
            + snapshot.volumes(on: disk).compactMap(\.volumeUUID)
        return uuids.contains { wanted.contains($0.uppercased()) }
    }
}

/// One way to prepare a drive, least destructive first (brief §3).
public enum PreparationOption: Sendable, Equatable, Hashable, Codable {
    /// a. A new APFS volume in an existing container. Erases nothing.
    case addVolume(container: String)
    /// a. A new APFS partition in the free space after `after`. Erases nothing.
    case addPartition(after: String, freeBytes: UInt64)
    /// b. Erase one volume as APFS; the other partitions stay.
    case eraseVolume(volume: String, name: String)
    /// c. Erase the whole disk: GUID map and one APFS volume.
    case eraseDisk(disk: String)
    /// d. Ownership is ignored on this volume. Finder's Get Info turns it on; `sudo diskutil enableOwnership` is the
    /// copyable alternative. The app runs nothing for it.
    case enableOwnership(mountPoint: String)

    public var erases: Bool {
        switch self {
        case .eraseVolume, .eraseDisk: true
        default: false
        }
    }

    /// Whether this option runs a command in the app (ownership does not).
    public var runsCommand: Bool {
        if case .enableOwnership = self { return false }
        return true
    }
}

/// A drive's single verdict (brief §3).
public enum DriveVerdict: String, Sendable, Codable, CaseIterable {
    /// A registered vault is on it and usable.
    case ready
    /// One of its volumes qualifies and is not registered: **Use This Drive**.
    case canBeUsed
    /// Nothing on it qualifies, and an option can fix that.
    case needsPreparation
    /// Nothing on it qualifies and nothing here can change that.
    case cannotBeUsed
}

/// One external disk, judged.
public struct DriveAssessment: Sendable, Equatable, Identifiable {
    public var disk: PhysicalDisk
    /// Its mounted volumes.
    public var volumes: [Volume]
    public var verdict: DriveVerdict
    /// Least destructive first. Empty for `ready` and for a disk `DiskSafety` refuses entirely.
    public var options: [PreparationOption]
    /// The usable vault on it, for `ready`.
    public var vault: VaultVolumeCheck?
    /// The volume **Use This Drive** registers, for `canBeUsed`: the qualifying volume with the most free space.
    public var registrable: Volume?
    /// Why erasing is not offered (empty when it is).
    public var eraseRefusals: [DiskRefusal]
    /// Why nothing at all is offered (empty unless the disk is refused entirely).
    public var changeRefusals: [DiskRefusal]
    /// A volume's qualification blockers and warnings, by device node — the reasons behind the verdict.
    public var qualifications: [String: VolumeQualification]

    public var id: String { disk.id }

    /// The display name: the first named volume, else the media name, else the device id.
    public var displayName: String {
        volumes.first(where: { !$0.volumeName.isEmpty })?.volumeName ?? (disk.mediaName.isEmpty ? disk.id : disk.mediaName)
    }

    /// Whether an option is recommended: adding a volume when the disk's APFS volumes are case-sensitive or ignore
    /// ownership — the fix that erases nothing.
    public func isRecommended(_ option: PreparationOption) -> Bool {
        guard case .addVolume = option else { return false }
        return volumes.contains { $0.isAPFS && ($0.filesystemPersonality.lowercased().contains("case-sensitive") || !$0.ownersEnabled) }
            || verdict == .needsPreparation
    }
}

public enum DriveEvaluation {
    /// The smallest free space worth offering a new partition in.
    public static let minimumPartitionBytes: UInt64 = 1_000_000_000

    /// Every external drive worth showing: physical, not internal, not a disk image. A disk image or an internal disk
    /// is never listed here; `DiskSafety` refuses them anyway, should one reach `assess` by another path.
    public static func externalDisks(_ snapshot: DriveSnapshot) -> [PhysicalDisk] {
        snapshot.disks.filter { !$0.isInternal && !$0.isDiskImage }
    }

    public static func assessAll(_ snapshot: DriveSnapshot, vaults: [VaultVolumeCheck]) -> [DriveAssessment] {
        externalDisks(snapshot).map { assess($0, in: snapshot, vaults: vaults) }
            // Ready first, then usable, then those that need preparation, then the rest (brief §6).
            .sorted { (rank($0.verdict), $0.disk.id) < (rank($1.verdict), $1.disk.id) }
    }

    public static func rank(_ v: DriveVerdict) -> Int {
        switch v {
        case .ready: 0
        case .canBeUsed: 1
        case .needsPreparation: 2
        case .cannotBeUsed: 3
        }
    }

    public static func assess(_ disk: PhysicalDisk, in snapshot: DriveSnapshot, vaults: [VaultVolumeCheck]) -> DriveAssessment {
        let mounted = snapshot.volumes(on: disk)
        let registered = Set(vaults.map(\.volume.volumeUUID))
        let changeRefusals = DiskSafety.changeRefusals(disk, in: snapshot)
        let eraseRefusals = DiskSafety.eraseRefusals(disk, in: snapshot, registeredVaultUUIDs: registered)
        var quals: [String: VolumeQualification] = [:]
        for v in mounted { quals[v.deviceNode] = VolumeQualification.evaluate(v) }

        let vault = vaults.first { c in c.isUsable && mounted.contains { $0.volumeUUID?.uppercased() == c.volume.volumeUUID.uppercased() } }
        let registrable = mounted.filter { v in
            quals[v.deviceNode]?.verdict != .unsuitable && !registered.contains(where: { $0.uppercased() == v.volumeUUID?.uppercased() })
        }.max { $0.freeBytes < $1.freeBytes }

        let options = changeRefusals.isEmpty ? Self.options(disk, mounted: mounted, eraseAllowed: eraseRefusals.isEmpty) : []
        let verdict: DriveVerdict
        if vault != nil {
            verdict = .ready
        } else if !changeRefusals.isEmpty {
            verdict = .cannotBeUsed
        } else if registrable != nil {
            verdict = .canBeUsed
        } else if !options.isEmpty {
            verdict = .needsPreparation
        } else {
            verdict = .cannotBeUsed
        }
        return DriveAssessment(
            disk: disk, volumes: mounted, verdict: verdict, options: verdict == .ready ? [] : options, vault: vault,
            registrable: verdict == .canBeUsed ? registrable : nil, eraseRefusals: eraseRefusals, changeRefusals: changeRefusals,
            qualifications: quals)
    }

    /// The options for a disk `DiskSafety` allows changing, in the brief's order: a (add a volume to each APFS container
    /// that is not Time Machine's; add a partition in free space on a GUID map), b (erase each user volume), c (erase the
    /// disk), d (ownership, per mounted APFS volume that ignores it). b and c only when `eraseAllowed`.
    static func options(_ disk: PhysicalDisk, mounted: [Volume], eraseAllowed: Bool) -> [PreparationOption] {
        var out: [PreparationOption] = []
        for c in disk.containers where !c.volumes.contains(where: \.isTimeMachine) {
            out.append(.addVolume(container: c.reference))
        }
        if disk.isGPT, disk.unpartitionedBytes >= minimumPartitionBytes, let last = disk.partitions.last {
            out.append(.addPartition(after: last.id, freeBytes: disk.unpartitionedBytes))
        }
        if eraseAllowed {
            for p in disk.partitions where !p.isAPFSStore && !p.isSystemPartition {
                out.append(.eraseVolume(volume: p.id, name: p.volumeName ?? ""))
            }
            for c in disk.containers {
                for v in c.volumes where v.roles.isEmpty {
                    out.append(.eraseVolume(volume: v.id, name: v.name))
                }
            }
            out.append(.eraseDisk(disk: disk.id))
        }
        for v in mounted where v.isAPFS && !v.ownersEnabled {
            if let mp = v.mountPoint { out.append(.enableOwnership(mountPoint: mp)) }
        }
        return out
    }
}
