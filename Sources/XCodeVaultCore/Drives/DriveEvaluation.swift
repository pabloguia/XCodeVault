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
    /// An HFS+ partition that is not mounted: it might be a Time Machine backup, and nothing can tell until it is mounted
    /// (the marker check reads the volume's root).
    case mightBeTimeMachine

    /// English, for Core's own prose and the journal; the app has its own words.
    public var reason: String {
        switch self {
        case .internalDisk: "This is an internal disk. XCodeVault never erases or partitions an internal disk."
        case .bootDisk: "This disk holds the running system."
        case .diskImage: "This is a disk image, not a drive."
        case .holdsVault: "This disk holds a registered vault. Erasing or repartitioning it is blocked: it would destroy or remount the vault."
        case .timeMachine: "This disk holds a Time Machine backup."
        case .readOnlyMedia: "This disk's media is read-only."
        case .mightBeTimeMachine: "An unmounted HFS+ partition on this disk might be a Time Machine backup; mount it so XCodeVault can check."
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

    /// What forbids ERASING the whole disk, and what is shown as "why erasing is not offered": every change refusal, a
    /// registered vault on any of its volumes — registered, whether or not it is usable right now — and an unmounted HFS+
    /// partition that might be a Time Machine backup.
    public static func eraseRefusals(_ disk: PhysicalDisk, in snapshot: DriveSnapshot, registeredVaultUUIDs: Set<String>) -> [DiskRefusal] {
        var out = changeRefusals(disk, in: snapshot)
        if holdsVault(disk, in: snapshot, registeredVaultUUIDs: registeredVaultUUIDs) { out.append(.holdsVault) }
        if !unverifiedHFSPartitions(disk, in: snapshot).isEmpty { out.append(.mightBeTimeMachine) }
        return out
    }

    /// The one question asked before planning and again before running: what forbids `action` on `target` of `disk`.
    ///   - adding a volume: the change refusals (it does not touch the partition map);
    ///   - adding a partition: those and a registered vault on the disk — rewriting the map remounts the disk, a window
    ///     in which the vault is not where it was (rule 6);
    ///   - erasing a volume: those, and the target being an unmounted HFS+ partition (`mightBeTimeMachine`);
    ///   - erasing the disk: those, and any unmounted HFS+ partition on it.
    public static func refusals(
        for action: DiskPreparationAction, target: String, on disk: PhysicalDisk, in snapshot: DriveSnapshot, registeredVaultUUIDs: Set<String>
    ) -> [DiskRefusal] {
        var out = changeRefusals(disk, in: snapshot)
        guard action != .addVolume else { return out }
        if holdsVault(disk, in: snapshot, registeredVaultUUIDs: registeredVaultUUIDs) { out.append(.holdsVault) }
        let hfs = unverifiedHFSPartitions(disk, in: snapshot)
        switch action {
        case .eraseVolume where hfs.contains(target), .eraseDisk where !hfs.isEmpty: out.append(.mightBeTimeMachine)
        default: break
        }
        return out
    }

    /// HFS+ partitions of `disk` that are not mounted: their root, where a Time Machine marker would be, cannot be read.
    public static func unverifiedHFSPartitions(_ disk: PhysicalDisk, in snapshot: DriveSnapshot) -> [String] {
        let mounted = Set(snapshot.volumes(on: disk).map { DriveSnapshot.deviceID($0.deviceNode) })
        return disk.partitions.filter { ($0.content == "Apple_HFS" || $0.content == "Apple_HFSX") && !mounted.contains($0.id) }.map(\.id)
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
    /// ownership — the fix that erases nothing — or when nothing on the disk qualifies.
    public func isRecommended(_ option: PreparationOption) -> Bool {
        guard case .addVolume = option else { return false }
        return DriveEvaluation.wantsANewVolume(volumes) || verdict == .needsPreparation
    }

    /// The option **Prepare…** opens on: the recommended one, else the first that runs a command (least destructive).
    public var recommendedOption: PreparationOption? { options.first(where: isRecommended) }

    /// What **Prepare…** beside a drive does (the Run sheet's Destination): a drive that can be used as it is but whose
    /// volume is case-sensitive or ignores ownership gets the recommended new volume, never a registration of that volume.
    public enum PrepareAction: Equatable, Sendable {
        case useDrive
        case prepare(PreparationOption)
        case nothing
    }

    public var prepareAction: PrepareAction {
        if let recommended = recommendedOption { return .prepare(recommended) }
        if verdict == .canBeUsed { return .useDrive }
        if let first = commandOptions.first { return .prepare(first) }
        return .nothing
    }

    /// The options that run a command, least destructive first: the Drives screen's buttons.
    public var commandOptions: [PreparationOption] { options.filter(\.runsCommand) }

    /// The volumes whose ownership is off: the Get Info / Copy Command block, drawn before the buttons (least destructive).
    public var ownershipMountPoints: [String] {
        options.compactMap {
            if case .enableOwnership(let mp) = $0 { return mp }
            return nil
        }
    }

    /// The refusals the row says: why nothing can change the disk when that is so, else why erasing is not offered.
    public var shownRefusals: [DiskRefusal] { changeRefusals.isEmpty ? eraseRefusals : changeRefusals }

    /// One reason per mounted volume that does not qualify — its first blocker — except a volume whose fix is the
    /// ownership block, which says it with its buttons.
    public struct VolumeReason: Equatable, Sendable {
        public var volumeName: String
        public var reason: String
    }

    public var volumeReasons: [VolumeReason] {
        let owned = Set(ownershipMountPoints)
        return volumes.compactMap { v in
            guard let q = qualifications[v.deviceNode], q.verdict == .unsuitable, !owned.contains(v.mountPoint ?? ""), let first = q.blockers.first
            else { return nil }
            return VolumeReason(volumeName: v.volumeName, reason: first)
        }
    }

    /// The disk can be told apart from another of the same model only by media name and size (M1's residual case): an
    /// MBR disk with no recognised file system. The erase confirmation says so.
    public var identityIsWeak: Bool { !disk.identity.isDistinguishable }
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

        let all =
            changeRefusals.isEmpty
            ? Self.options(disk, in: snapshot, mounted: mounted, registeredVaultUUIDs: registered) : []
        let verdict: DriveVerdict
        if vault != nil {
            verdict = .ready
        } else if !changeRefusals.isEmpty {
            verdict = .cannotBeUsed
        } else if registrable != nil {
            verdict = .canBeUsed
        } else if !all.isEmpty {
            verdict = .needsPreparation
        } else {
            verdict = .cannotBeUsed
        }
        return DriveAssessment(
            // A ready vault keeps what erases nothing when its volume is case-sensitive or ignores ownership (PABLO's case):
            // the new case-insensitive volume is the recommended fix. Erasing was never in `all` for it (`.holdsVault`).
            disk: disk, volumes: mounted, verdict: verdict,
            options: verdict == .ready ? (wantsANewVolume(mounted) ? all.filter { !$0.erases } : []) : all, vault: vault,
            registrable: verdict == .canBeUsed ? registrable : nil, eraseRefusals: eraseRefusals, changeRefusals: changeRefusals,
            qualifications: quals)
    }

    /// The options for a disk `DiskSafety` allows changing, in the brief's order: a (add a volume to each APFS container
    /// that is not Time Machine's; add a partition in free space on a GUID map), b (erase each user volume), c (erase the
    /// disk), d (ownership, per mounted APFS volume that ignores it). b and c only when `eraseAllowed`.
    /// Every option is offered only when `DiskSafety.refusals` for it is empty — the same function `plan` and `revalidate`
    /// ask.
    static func options(_ disk: PhysicalDisk, in snapshot: DriveSnapshot, mounted: [Volume], registeredVaultUUIDs: Set<String>)
        -> [PreparationOption]
    {
        func allowed(_ action: DiskPreparationAction, _ target: String) -> Bool {
            DiskSafety.refusals(for: action, target: target, on: disk, in: snapshot, registeredVaultUUIDs: registeredVaultUUIDs).isEmpty
        }
        var out: [PreparationOption] = []
        for c in disk.containers where !c.volumes.contains(where: \.isTimeMachine) && allowed(.addVolume, c.reference) {
            out.append(.addVolume(container: c.reference))
        }
        if disk.isGPT, disk.unpartitionedBytes >= minimumPartitionBytes, let last = disk.partitions.last, allowed(.addPartition, last.id) {
            out.append(.addPartition(after: last.id, freeBytes: disk.unpartitionedBytes))
        }
        for p in disk.partitions where !p.isAPFSStore && !p.isSystemPartition && allowed(.eraseVolume, p.id) {
            out.append(.eraseVolume(volume: p.id, name: p.volumeName ?? ""))
        }
        for c in disk.containers {
            for v in c.volumes where v.roles.isEmpty && allowed(.eraseVolume, v.id) {
                out.append(.eraseVolume(volume: v.id, name: v.name))
            }
        }
        if allowed(.eraseDisk, disk.id) { out.append(.eraseDisk(disk: disk.id)) }
        for v in mounted where v.isAPFS && !v.ownersEnabled {
            if let mp = v.mountPoint { out.append(.enableOwnership(mountPoint: mp)) }
        }
        return out
    }

    /// A mounted APFS volume is case-sensitive or ignores ownership: a new case-insensitive volume is the fix.
    static func wantsANewVolume(_ mounted: [Volume]) -> Bool {
        mounted.contains { $0.isAPFS && ($0.filesystemPersonality.lowercased().contains("case-sensitive") || !$0.ownersEnabled) }
    }
}
