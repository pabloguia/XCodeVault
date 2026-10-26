import Foundation
import XCTest

@testable import XCodeVaultCore

/// A file system written on the whole disk, with no partition map. Measured 2026-10-18 on `-layout NONE` disk images
/// (fixtures `*-wholedisk*`): `diskutil list` gives the disk no `Partitions` and puts the volume's name and mount point
/// on the disk's own entry; an APFS one is a container whose store is the whole disk. Before this, `enumerate` did not
/// list such a volume, the topology gave its disk no volumes, and the container was attached to no disk — so the safety
/// guard and the erase preview saw nothing on it (migration-safety review of PR #54).
final class WholeDiskVolumeTests: XCTestCase {
    // disk10: FAT32 on the whole disk, mounted. disk11: HFS+, mounted. disk12: an APFS store whose container is disk13,
    // with one volume, disk13s1.
    static let wholeDisks = ["disk10", "disk11", "disk12"]

    static func info(_ id: String, unmountedHFS: Bool = false) -> Data {
        Fixtures.data(id == "disk11" && unmountedHFS ? "diskutil-info-wholedisk-disk11-unmounted.plist" : "diskutil-info-wholedisk-\(id).plist")
    }

    /// The disks as an external USB drive would be: the fixtures are disk images, which the guard refuses outright.
    static func disks(unmountedHFS: Bool = false) throws -> [PhysicalDisk] {
        try DiskTopology.parse(
            list: Fixtures.data("diskutil-list-wholedisk.plist"), apfs: Fixtures.data("diskutil-apfs-list-wholedisk.plist"),
            wholeDiskInfo: Dictionary(uniqueKeysWithValues: wholeDisks.map { ($0, info($0, unmountedHFS: unmountedHFS)) })
        ).map {
            var d = $0
            d.isVirtual = false; d.busProtocol = "USB"; d.isInternal = false; d.isWritable = true
            return d
        }
    }

    static func volume(_ node: String, _ name: String, uuid: String, mount: String, type: String) -> Volume {
        R6DriveTests.volume(node, name, uuid: uuid, mount: mount, type: type)
    }

    func testTheTopologySeesAFileSystemOnTheWholeDisk() throws {
        let disks = try Self.disks()
        XCTAssertEqual(disks.map(\.id), Self.wholeDisks, "the container disk13 is not a physical disk")
        let fat = try XCTUnwrap(disks.first { $0.id == "disk10" })
        XCTAssertNil(fat.partitionScheme)
        XCTAssertEqual(fat.partitions, [])
        XCTAssertEqual(fat.wholeDiskVolume?.content, "msdos")
        XCTAssertEqual(fat.wholeDiskVolume?.volumeName, "XCVWDFAT")
        XCTAssertEqual(fat.wholeDiskVolume?.mountPoint, "/Volumes/XCVWDFAT")
        XCTAssertEqual(fat.volumeIDs, ["disk10"])
        let hfs = try XCTUnwrap(disks.first { $0.id == "disk11" })
        XCTAssertEqual(hfs.wholeDiskVolume?.isHFS, true)
        XCTAssertEqual(hfs.identity.volumeUUIDs, ["3FF43BEF-85EE-350F-A404-7806C1E025E0"], "the file system tells the disk apart")
        // The APFS store: its container is on it, and it has no file system of its own.
        let store = try XCTUnwrap(disks.first { $0.id == "disk12" })
        XCTAssertNil(store.wholeDiskVolume)
        XCTAssertEqual(store.containers.map(\.reference), ["disk13"])
        XCTAssertEqual(store.volumeIDs, ["disk13s1"])
        XCTAssertTrue(store.contains("disk13s1"))
    }

    /// Erasing the disk lists the volume it destroys; before, the list was empty.
    func testTheErasePreviewNamesTheVolume() throws {
        let snap = DriveSnapshot(
            disks: try Self.disks(),
            volumes: [
                Self.volume("disk10", "XCVWDFAT", uuid: "F-1", mount: "/Volumes/XCVWDFAT", type: "msdos"),
                Self.volume("disk13s1", "XCVWDAPFS", uuid: "A-1", mount: "/Volumes/XCVWDAPFS", type: "apfs"),
            ])
        let fat = try XCTUnwrap(snap.disks.first { $0.id == "disk10" })
        XCTAssertEqual(DiskSafety.changeRefusals(fat, in: snap), [], "the control: an ordinary external disk")
        let assessment = DriveEvaluation.assess(fat, in: snap, vaults: [])
        XCTAssertTrue(assessment.options.contains(.eraseDisk(disk: "disk10")), "\(assessment.options)")
        XCTAssertFalse(assessment.options.contains { if case .eraseVolume = $0 { true } else { false } }, "only the disk is erased")
        let plan = try DiskPreparation.plan(
            .eraseDisk(disk: "disk10"), configuration: VolumeConfiguration(), on: assessment, snapshot: snap, registeredVaultUUIDs: [])
        XCTAssertEqual(plan.destroys.map(\.id), ["disk10"])
        XCTAssertEqual(plan.destroys.map(\.name), ["XCVWDFAT"])
        let store = try XCTUnwrap(snap.disks.first { $0.id == "disk12" })
        XCTAssertEqual(DiskPreparation.destroyedVolumes(.eraseDisk, target: "disk12", disk: store, snapshot: snap).map(\.name), ["XCVWDAPFS"])
        // `eraseVolume` on the whole disk is refused: it was never measured.
        XCTAssertThrowsError(
            try DiskPreparation.refuseUnsafe(.eraseVolume, target: "disk10", disk: fat, snapshot: snap, registeredVaultUUIDs: [])
        ) { XCTAssertTrue("\($0)".contains("erase the disk instead"), "\($0)") }
    }

    /// An unmounted HFS+ file system on the whole disk might be a Time Machine backup, as an unmounted HFS+ partition
    /// might; mounted, its marker is read.
    func testAnUnmountedWholeDiskHFSMightBeTimeMachine() throws {
        let unmounted = DriveSnapshot(disks: try Self.disks(unmountedHFS: true), volumes: [])
        let hfs = try XCTUnwrap(unmounted.disks.first { $0.id == "disk11" })
        XCTAssertNil(hfs.wholeDiskVolume?.mountPoint, "measured: info names the file system and no mount point")
        XCTAssertEqual(DiskSafety.unverifiedPartitions(hfs, in: unmounted), ["disk11"])
        XCTAssertTrue(DiskSafety.eraseRefusals(hfs, in: unmounted, registeredVaultUUIDs: []).contains(.mightBeTimeMachine))

        let mountedVolume = Self.volume("disk11", "XCVWDHFS", uuid: "3FF43BEF-85EE-350F-A404-7806C1E025E0", mount: "/Volumes/XCVWDHFS", type: "hfs")
        let mounted = DriveSnapshot(disks: try Self.disks(), volumes: [mountedVolume])
        let disk11 = try XCTUnwrap(mounted.disks.first { $0.id == "disk11" })
        XCTAssertEqual(DiskSafety.unverifiedPartitions(disk11, in: mounted), [], "the control: mounted, its root can be read")
        let marked = DriveSnapshot(disks: mounted.disks, volumes: [mountedVolume], timeMachineMarkedVolumeIDs: ["disk11"])
        XCTAssertTrue(DiskSafety.changeRefusals(disk11, in: marked).contains(.timeMachine), "a marker on the whole-disk volume")
    }

    /// A vault on the whole-disk volume is seen by its UUID, mounted or not.
    func testAVaultOnTheWholeDiskIsSeen() throws {
        let snap = DriveSnapshot(disks: try Self.disks(unmountedHFS: true), volumes: [])
        let hfs = try XCTUnwrap(snap.disks.first { $0.id == "disk11" })
        XCTAssertFalse(DiskSafety.holdsVault(hfs, in: snap, registeredVaultUUIDs: ["00000000-0000-4000-8000-000000000001"]), "the control")
        XCTAssertTrue(DiskSafety.holdsVault(hfs, in: snap, registeredVaultUUIDs: ["3ff43bef-85ee-350f-a404-7806c1e025e0"]))
    }

    /// `diskutil` over the whole-disk fixtures, with every `info` it is asked recorded.
    final class WholeDiskDiskutil: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var infos: [String] { lock.withLock { asked } }
        /// `info` of the device fails after this many successful reads of it (0: always).
        let failing: [String: Int]
        init(failing: [String: Int] = [:]) { self.failing = failing }

        func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
            func ok(_ data: Data) -> CommandResult { CommandResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "") }
            switch arguments {
            case ["list", "-plist"]: return ok(Fixtures.data("diskutil-list-wholedisk.plist"))
            case ["apfs", "list", "-plist"]: return ok(Fixtures.data("diskutil-apfs-list-wholedisk.plist"))
            case let a where a.count == 3 && a[0] == "info" && a[1] == "-plist":
                let earlier = lock.withLock { () -> Int in
                    defer { asked.append(a[2]) }
                    return asked.filter { $0 == a[2] }.count
                }
                if let ok = failing[a[2]], earlier >= ok { return CommandResult(status: 1, stdout: "", stderr: "Could not find disk: \(a[2])") }
                guard ["disk10", "disk11", "disk12", "disk13s1"].contains(a[2]) else { return CommandResult(status: 1, stdout: "", stderr: "no fixture") }
                return ok(Fixtures.data("diskutil-info-wholedisk-\(a[2]).plist"))
            default:
                return CommandResult(status: 1, stdout: "", stderr: "not faked: \(arguments)")
            }
        }
    }

    /// The volumes on whole disks are listed: measured missing before (`xcodevaultctl volumes` showed only disk13s1).
    func testEnumerationListsTheWholeDiskVolumes() throws {
        let runner = WholeDiskDiskutil()
        let found = try VolumeDiscovery.enumerate(runner: runner, retryDelay: 0)
        XCTAssertEqual(found.volumes.map(\.deviceNode).sorted(), ["/dev/disk10", "/dev/disk11", "/dev/disk13s1"])
        XCTAssertEqual(found.unreadable, [])
        XCTAssertEqual(found.volumes.first { $0.deviceNode == "/dev/disk10" }?.mountPoint, "/Volumes/XCVWDFAT")
        XCTAssertEqual(Set(runner.infos), ["disk10", "disk11", "disk12", "disk13s1"], "the store is asked and skipped; the container is not")
        // Through the snapshot the app reads: the volume is on its disk.
        let snap = try DriveSnapshot.read(runner: WholeDiskDiskutil(), fileExists: { _ in false })
        let fat = try XCTUnwrap(snap.disks.first { $0.id == "disk10" })
        XCTAssertEqual(snap.volumes(on: fat).map(\.volumeName), ["XCVWDFAT"])
    }

    /// A whole disk `enumerate` now asks about, whose `info` fails. Both reads failing: the topology drops the disk and
    /// no disk claims the id, so every disk refuses (PR #54's rule for a volume that cannot be placed — broad on purpose:
    /// the snapshot cannot tell it is the dropped disk's own). Only the second read failing: that disk alone refuses.
    func testAWholeDiskWhoseInfoFailsRefusesChanges() throws {
        let gone = try DriveSnapshot.read(runner: WholeDiskDiskutil(failing: ["disk10": 0]), fileExists: { _ in false })
        XCTAssertFalse(gone.disks.contains { $0.id == "disk10" }, "the topology leaves out a disk it could not read")
        XCTAssertEqual(gone.unreadableVolumeIDs, ["disk10"])
        XCTAssertEqual(gone.unplacedUnreadableVolumeIDs, ["disk10"])
        let disk11 = try XCTUnwrap(gone.disks.first { $0.id == "disk11" })
        XCTAssertTrue(DiskSafety.changeRefusals(disk11, in: gone).contains(.unplacedVolumeUnreadable))

        let later = try DriveSnapshot.read(runner: WholeDiskDiskutil(failing: ["disk10": 1]), fileExists: { _ in false })
        let disk10 = try XCTUnwrap(later.disks.first { $0.id == "disk10" }, "the topology's read succeeded")
        XCTAssertEqual(later.unreadableVolumeIDs, ["disk10"])
        // `.diskImage` too: these are the fixtures' images, read through `DriveSnapshot.read`, not made USB disks.
        XCTAssertEqual(DiskSafety.changeRefusals(disk10, in: later), [.diskImage, .volumeUnreadable])
        let other = try XCTUnwrap(later.disks.first { $0.id == "disk11" })
        XCTAssertFalse(DiskSafety.changeRefusals(other, in: later).contains(.volumeUnreadable), "only its own disk")
        XCTAssertFalse(DiskSafety.changeRefusals(other, in: later).contains(.unplacedVolumeUnreadable))

        let control = try DriveSnapshot.read(runner: WholeDiskDiskutil(), fileExists: { _ in false })
        XCTAssertEqual(control.unreadableVolumeIDs, [])
    }

    /// A whole-disk file system `info` gives no type is still the disk's volume; a blank disk (measured on an image) has
    /// no type, name or UUID and no volume.
    func testAnUntypedFileSystemIsStillAVolumeAndABlankDiskIsNot() throws {
        func disk10(_ info: Data) throws -> PhysicalDisk {
            var all = Dictionary(uniqueKeysWithValues: Self.wholeDisks.map { ($0, Self.info($0)) })
            all["disk10"] = info
            return try XCTUnwrap(
                try DiskTopology.parse(
                    list: Fixtures.data("diskutil-list-wholedisk.plist"), apfs: Fixtures.data("diskutil-apfs-list-wholedisk.plist"),
                    wholeDiskInfo: all
                ).first { $0.id == "disk10" })
        }
        var plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Self.info("disk10"), format: nil) as? [String: Any])
        plist["FilesystemType"] = nil
        plist["MountPoint"] = ""
        let untyped = try disk10(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        XCTAssertEqual(untyped.wholeDiskVolume?.content, "unknown")
        XCTAssertEqual(untyped.wholeDiskVolume?.volumeName, "XCVWDFAT")
        XCTAssertNil(untyped.wholeDiskVolume?.mountPoint)
        XCTAssertEqual(untyped.volumeIDs, ["disk10"])
        XCTAssertEqual(untyped.wholeDiskVolume?.isHFS, false)
        // Not HFS+, but nothing says it is not a backup either: unmounted, erasing the disk is refused (2026-10-26).
        var external = untyped
        external.isVirtual = false; external.busProtocol = "USB"; external.isInternal = false; external.isWritable = true
        let unmounted = DriveSnapshot(disks: [external], volumes: [])
        XCTAssertEqual(DiskSafety.unverifiedPartitions(external, in: unmounted), ["disk10"])
        XCTAssertTrue(DiskSafety.eraseRefusals(external, in: unmounted, registeredVaultUUIDs: []).contains(.mightBeTimeMachine))
        let mounted = DriveSnapshot(
            disks: [external], volumes: [Self.volume("disk10", "XCVWDFAT", uuid: "F-1", mount: "/Volumes/XCVWDFAT", type: "msdos")])
        XCTAssertEqual(DiskSafety.unverifiedPartitions(external, in: mounted), [], "the control: mounted, its root can be read")

        // The blank disk's measured `info`, under disk10's `list` entry, which names XCVWDFAT: the entry's name alone
        // would make a volume, so the control uses an entry without it.
        var list = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Fixtures.data("diskutil-list-wholedisk.plist"), format: nil) as? [String: Any])
        var entries = try XCTUnwrap(list["AllDisksAndPartitions"] as? [[String: Any]])
        let i = try XCTUnwrap(entries.firstIndex { $0["DeviceIdentifier"] as? String == "disk10" })
        entries[i]["VolumeName"] = nil
        entries[i]["MountPoint"] = nil
        list["AllDisksAndPartitions"] = entries
        var infos = Dictionary(uniqueKeysWithValues: Self.wholeDisks.map { ($0, Self.info($0)) })
        infos["disk10"] = Fixtures.data("diskutil-info-wholedisk-blank.plist")
        let blank = try XCTUnwrap(
            try DiskTopology.parse(
                list: try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0),
                apfs: Fixtures.data("diskutil-apfs-list-wholedisk.plist"), wholeDiskInfo: infos
            ).first { $0.id == "disk10" })
        XCTAssertNil(blank.wholeDiskVolume)
        XCTAssertEqual(blank.volumeIDs, [])
    }
}
