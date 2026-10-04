import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// R6 (ADR-0012): drive discovery, evaluation, the safety guard and preparation — all from redacted fixtures and a
/// recording fake. No test here runs `diskutil` or `hdiutil`: `DiskRecordingRunner` answers from fixtures and records every
/// call, and the tests that execute a plan assert which calls were made.
final class R6DriveTests: XCTestCase {
    // MARK: - Fixtures

    static let infoIDs = ["disk0", "disk2", "disk4", "disk6", "disk7", "disk9", "disk10"]

    static func disks() throws -> [PhysicalDisk] {
        try DiskTopology.parse(
            list: Fixtures.data("diskutil-list-r6.plist"), apfs: Fixtures.data("diskutil-apfs-list-r6.plist"),
            wholeDiskInfo: Dictionary(uniqueKeysWithValues: infoIDs.map { ($0, Fixtures.data("diskutil-info-r6-\($0).plist")) }))
    }

    static func volume(
        _ node: String, _ name: String, uuid: String, mount: String, fs: String = "APFS", type: String = "apfs", isInternal: Bool = false,
        bus: String = "USB", writable: Bool = true, owners: Bool = true, free: UInt64 = 300_000_000_000, total: UInt64 = 1_000_000_000_000,
        boot: Bool = false
    ) -> Volume {
        Volume(
            deviceNode: "/dev/" + node, volumeName: name, volumeUUID: uuid, mountPoint: mount, filesystemPersonality: fs, filesystemType: type,
            isInternal: isInternal, isRemovableMedia: false, isEjectable: !isInternal, busProtocol: bus, isSolidState: true, isWritable: writable,
            ownersEnabled: owners, totalBytes: total, freeBytes: free, isBootVolume: boot)
    }

    static func u(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    static func volumes(mediaOwners: Bool = true) -> [Volume] {
        [
            volume("disk1s1", "Macintosh HD - Data", uuid: u(201), mount: "/System/Volumes/Data", isInternal: true, bus: "PCI-Express", boot: true),
            volume("disk1s5", "Macintosh HD", uuid: u(205), mount: "/", isInternal: true, bus: "PCI-Express", writable: false, boot: true),
            volume("disk3s1", "Media", uuid: u(301), mount: "/Volumes/Media", fs: "Case-sensitive APFS", owners: mediaOwners),
            volume("disk5s1", "iOS 26.5 Simulator", uuid: u(501), mount: "/Volumes/Sim", bus: "Disk Image"),
            volume("disk6s1", "STICK", uuid: u(601), mount: "/Volumes/STICK", fs: "Windows_NTFS", type: "ntfs", writable: false, owners: false),
            volume("disk8s1", "Backups", uuid: u(801), mount: "/Volumes/Backups"),
            volume("disk9s2", "Transfer", uuid: u(902), mount: "/Volumes/Transfer", fs: "ExFAT", type: "exfat", owners: false),
            volume("disk11s1", "Vault", uuid: u(1101), mount: "/Volumes/Vault", bus: "Thunderbolt"),
        ]
    }

    static func snapshot(mediaOwners: Bool = true, marked: Set<String> = []) throws -> DriveSnapshot {
        DriveSnapshot(disks: try disks(), volumes: volumes(mediaOwners: mediaOwners), timeMachineMarkedVolumeIDs: marked)
    }

    static func vaultCheck(uuid: String = u(1101), state: VaultVolumeState = .verified, mount: String? = "/Volumes/Vault") -> VaultVolumeCheck {
        VaultVolumeCheck(
            volume: VaultVolume(volumeUUID: uuid, volumeName: "Vault", lastMountPoint: "/Volumes/Vault", registeredAt: Date(), sentinelID: "s"),
            state: state, currentMountPoint: mount, shadowBytes: nil, detail: "d")
    }

    func assessment(_ id: String, _ snap: DriveSnapshot, vaults: [VaultVolumeCheck] = [vaultCheck()]) throws -> DriveAssessment {
        let disk = try XCTUnwrap(snap.disks.first { $0.id == id })
        return DriveEvaluation.assess(disk, in: snap, vaults: vaults)
    }

    // MARK: - Topology

    func testPhysicalDisksExcludeSynthesizedContainers() throws {
        let ids = try DiskTopology.physicalDiskIDs(list: Fixtures.data("diskutil-list-r6.plist"))
        XCTAssertEqual(ids, ["disk0", "disk2", "disk4", "disk6", "disk7", "disk9", "disk10"])
        XCTAssertEqual(try Self.disks().map(\.id), ids)
    }

    func testParsesMapContainersAndFacts() throws {
        let disks = try Self.disks()
        let ssd = try XCTUnwrap(disks.first { $0.id == "disk2" })
        XCTAssertEqual(ssd.mediaName, "XS2000")
        XCTAssertEqual(ssd.busProtocol, "USB")
        XCTAssertFalse(ssd.isInternal)
        XCTAssertFalse(ssd.isDiskImage)
        XCTAssertTrue(ssd.isGPT)
        XCTAssertEqual(ssd.containers.map(\.reference), ["disk3"])
        XCTAssertEqual(ssd.containers.first?.volumes.map(\.name), ["Media"])
        XCTAssertEqual(ssd.volumeIDs, ["disk3s1"])
        XCTAssertEqual(ssd.unpartitionedBytes, 0, "a disk filled by one partition has no free space to offer")
        XCTAssertTrue(ssd.contains("disk3"))
        XCTAssertTrue(ssd.contains("disk3s1"))
        XCTAssertFalse(ssd.contains("disk1s1"))

        XCTAssertTrue(try XCTUnwrap(disks.first { $0.id == "disk4" }).isDiskImage)
        XCTAssertTrue(try XCTUnwrap(disks.first { $0.id == "disk0" }).isInternal)
        let stick = try XCTUnwrap(disks.first { $0.id == "disk6" })
        XCTAssertEqual(stick.partitionScheme, "FDisk_partition_scheme")
        XCTAssertEqual(stick.unpartitionedBytes, 32_000_000_000 - PhysicalDisk.mapOverheadBytes)
        XCTAssertEqual(stick.volumeIDs, ["disk6s1"])
        let tm = try XCTUnwrap(disks.first { $0.id == "disk7" })
        XCTAssertEqual(tm.containers.first?.volumes.first?.isTimeMachine, true)
        let hdd = try XCTUnwrap(disks.first { $0.id == "disk9" })
        XCTAssertEqual(hdd.volumeIDs, ["disk9s2"], "the EFI partition is never a user volume")
    }

    func testFreeSpaceFromTheExperimentsOwnMap() throws {
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "MediaName": "Disk Image", "Size": 2_147_483_648, "BusProtocol": "Disk Image", "Internal": false, "VirtualOrPhysical": "Virtual",
                "WritableMedia": true,
            ], format: .xml, options: 0)
        let apfs = try PropertyListSerialization.data(fromPropertyList: ["Containers": [Any]()], format: .xml, options: 0)
        let disks = try DiskTopology.parse(list: Fixtures.data("diskutil-list-e-diskprep-exfat-free.plist"), apfs: apfs, wholeDiskInfo: ["disk10": info])
        let d = try XCTUnwrap(disks.first)
        XCTAssertEqual(d.partitions.map(\.content), ["Microsoft Basic Data"])
        XCTAssertEqual(d.unpartitionedBytes, 2_147_483_648 - 799_014_912 - PhysicalDisk.mapOverheadBytes)
        XCTAssertGreaterThan(d.unpartitionedBytes, DriveEvaluation.minimumPartitionBytes)
        XCTAssertTrue(d.isDiskImage)
    }

    func testAMissingInfoLeavesTheDiskOutRatherThanGuessing() throws {
        let disks = try DiskTopology.parse(
            list: Fixtures.data("diskutil-list-r6.plist"), apfs: Fixtures.data("diskutil-apfs-list-r6.plist"),
            wholeDiskInfo: ["disk2": Fixtures.data("diskutil-info-r6-disk2.plist")])
        XCTAssertEqual(disks.map(\.id), ["disk2"])
    }

    func testReadsOnlyThroughTheRunnerAndOnlyReadOnlyVerbs() throws {
        var responses: [String: CommandResult] = [
            "diskutil list -plist": .init(status: 0, stdout: Fixtures.string("diskutil-list-r6.plist"), stderr: ""),
            "diskutil apfs list -plist": .init(status: 0, stdout: Fixtures.string("diskutil-apfs-list-r6.plist"), stderr: ""),
        ]
        for id in Self.infoIDs {
            responses["diskutil info -plist \(id)"] = .init(status: 0, stdout: Fixtures.string("diskutil-info-r6-\(id).plist"), stderr: "")
        }
        let runner = DiskRecordingRunner(responses: responses)
        XCTAssertEqual(try DiskTopology.read(runner: runner).count, 7)
        let verbs = Set(runner.calls.map { $0.dropFirst().first ?? "" })
        XCTAssertEqual(verbs, ["list", "apfs", "info"], "discovery must use read-only verbs only")
        XCTAssertTrue(runner.calls.allSatisfy { $0.first == "diskutil" })
    }

    func testBootDiskIsTheStoreOfTheBootContainer() throws {
        XCTAssertEqual(try Self.snapshot().bootDiskIDs, ["disk0"])
    }

    // MARK: - The guard

    func testGuardRefusesInternalBootImageAndTimeMachine() throws {
        let snap = try Self.snapshot()
        func change(_ id: String) -> [DiskRefusal] { DiskSafety.changeRefusals(snap.disks.first { $0.id == id }!, in: snap) }
        XCTAssertEqual(change("disk0"), [.internalDisk, .bootDisk])
        XCTAssertEqual(change("disk4"), [.diskImage])
        XCTAssertEqual(change("disk7"), [.timeMachine])
        XCTAssertEqual(change("disk2"), [])
        XCTAssertEqual(change("disk10"), [])
    }

    func testEraseIsRefusedOnAVaultDiskWhetherOrNotTheVaultIsUsable() throws {
        let snap = try Self.snapshot()
        let disk = try XCTUnwrap(snap.disks.first { $0.id == "disk10" })
        XCTAssertEqual(DiskSafety.eraseRefusals(disk, in: snap, registeredVaultUUIDs: [Self.u(1101)]), [.holdsVault])
        XCTAssertEqual(DiskSafety.eraseRefusals(disk, in: snap, registeredVaultUUIDs: [Self.u(1101).lowercased()]), [.holdsVault], "UUID case")
        XCTAssertEqual(DiskSafety.eraseRefusals(disk, in: snap, registeredVaultUUIDs: []), [])
        // A foreign or sentinel-missing vault is still registered: still refused.
        let a = try assessment("disk10", snap, vaults: [Self.vaultCheck(state: .sentinelMissing)])
        XCTAssertEqual(a.eraseRefusals, [.holdsVault])
        XCTAssertFalse(a.options.contains(where: \.erases))
    }

    func testTimeMachineMarkerRefusesADiskWithoutTheBackupRole() throws {
        let snap = try Self.snapshot(marked: ["disk9s2"])
        let disk = try XCTUnwrap(snap.disks.first { $0.id == "disk9" })
        XCTAssertEqual(DiskSafety.changeRefusals(disk, in: snap), [.timeMachine])
        XCTAssertEqual(try assessment("disk9", snap).options, [])
        XCTAssertEqual(try assessment("disk9", snap).verdict, .cannotBeUsed)
    }

    func testReadOnlyMediaRefusesEveryChange() throws {
        var snap = try Self.snapshot()
        snap.disks = snap.disks.map {
            var d = $0; if d.id == "disk2" { d.isWritable = false }; return d
        }
        XCTAssertEqual(DiskSafety.changeRefusals(snap.disks.first { $0.id == "disk2" }!, in: snap), [.readOnlyMedia])
    }

    // MARK: - Evaluation

    func testExternalDisksExcludeInternalAndImages() throws {
        XCTAssertEqual(DriveEvaluation.externalDisks(try Self.snapshot()).map(\.id), ["disk2", "disk6", "disk7", "disk9", "disk10"])
    }

    func testCaseSensitiveDriveCanBeUsedAndAddingAVolumeIsRecommended() throws {
        let a = try assessment("disk2", try Self.snapshot())
        XCTAssertEqual(a.verdict, .canBeUsed)
        XCTAssertEqual(a.registrable?.volumeName, "Media")
        XCTAssertEqual(a.options, [.addVolume(container: "disk3"), .eraseVolume(volume: "disk3s1", name: "Media"), .eraseDisk(disk: "disk2")])
        XCTAssertTrue(a.isRecommended(.addVolume(container: "disk3")))
        XCTAssertFalse(a.isRecommended(.eraseDisk(disk: "disk2")))
        XCTAssertEqual(a.displayName, "Media")
    }

    func testOwnershipOffNeedsPreparationAndOffersGetInfo() throws {
        let a = try assessment("disk2", try Self.snapshot(mediaOwners: false))
        XCTAssertEqual(a.verdict, .needsPreparation)
        XCTAssertNil(a.registrable)
        XCTAssertEqual(a.options.last, .enableOwnership(mountPoint: "/Volumes/Media"))
        XCTAssertEqual(DiskPreparation.enableOwnershipCommand(mountPoint: "/Volumes/My Drive"), "sudo diskutil enableOwnership '/Volumes/My Drive'")
    }

    func testReadOnlyNTFSStickOffersOnlyErasing() throws {
        let a = try assessment("disk6", try Self.snapshot())
        XCTAssertEqual(a.verdict, .needsPreparation)
        XCTAssertEqual(a.options, [.eraseVolume(volume: "disk6s1", name: "STICK"), .eraseDisk(disk: "disk6")], "MBR: no new APFS partition")
    }

    func testExFATDiskWithFreeSpaceOffersAPartitionFirst() throws {
        let a = try assessment("disk9", try Self.snapshot())
        XCTAssertEqual(a.verdict, .needsPreparation)
        guard case .addPartition(let after, let free) = a.options.first else { return XCTFail("\(a.options)") }
        XCTAssertEqual(after, "disk9s2")
        XCTAssertGreaterThan(free, 400_000_000_000)
        XCTAssertEqual(Array(a.options.dropFirst()), [.eraseVolume(volume: "disk9s2", name: "Transfer"), .eraseDisk(disk: "disk9")])
    }

    func testTimeMachineDiskCannotBeUsedAndOffersNothing() throws {
        let a = try assessment("disk7", try Self.snapshot())
        XCTAssertEqual(a.verdict, .cannotBeUsed)
        XCTAssertEqual(a.options, [])
        XCTAssertEqual(a.changeRefusals, [.timeMachine])
    }

    func testVaultDiskIsReadyAndOffersNothing() throws {
        let a = try assessment("disk10", try Self.snapshot())
        XCTAssertEqual(a.verdict, .ready)
        XCTAssertEqual(a.vault?.volume.volumeUUID, Self.u(1101))
        XCTAssertEqual(a.options, [])
        XCTAssertNil(a.registrable)
    }

    func testReadyFirstInTheList() throws {
        let all = DriveEvaluation.assessAll(try Self.snapshot(), vaults: [Self.vaultCheck()])
        XCTAssertEqual(all.map(\.verdict), [.ready, .canBeUsed, .needsPreparation, .needsPreparation, .cannotBeUsed])
        XCTAssertEqual(all.map(\.disk.id), ["disk10", "disk2", "disk6", "disk9", "disk7"])
    }

    func testNetworkVolumeIsABlocker() {
        let smb = Self.volume("disk99", "Share", uuid: Self.u(9), mount: "/Volumes/Share", fs: "smbfs", type: "smbfs")
        XCTAssertTrue(smb.isNetwork)
        XCTAssertEqual(VolumeQualification.evaluate(smb).verdict, .unsuitable)
        XCTAssertTrue(VolumeQualification.evaluate(smb).blockers.contains { $0.contains("network volume") })
        for t in ["nfs", "afpfs", "webdav", "SMBFS"] { XCTAssertTrue(Volume.isNetworkFilesystem(t), t) }
        XCTAssertFalse(Volume.isNetworkFilesystem("apfs"))
        XCTAssertThrowsError(try DriveRegistration.useDrive(smb, registry: VaultRegistry(url: URL(fileURLWithPath: "/nonexistent/v.json"))))
    }

    func testNetworkFolderIsRefusedAsADestination() {
        let smb = MountStatus.FilesystemInfo(mountPoint: "/Volumes/Share", device: "//u@nas/share", typeName: "smbfs", flags: 0)
        XCTAssertNotNil(DestinationFolder.networkRefusal(smb))
        let local = MountStatus.FilesystemInfo(mountPoint: "/Volumes/T7", device: "/dev/disk11s1", typeName: "apfs", flags: UInt32(MNT_LOCAL))
        XCTAssertNil(DestinationFolder.networkRefusal(local))
        XCTAssertNil(DestinationFolder.networkRefusal(nil))
    }

    // MARK: - Planning

    func plan(_ option: PreparationOption, _ id: String, _ config: VolumeConfiguration = VolumeConfiguration()) throws -> DiskPreparationPlan {
        let snap = try Self.snapshot()
        return try DiskPreparation.plan(option, configuration: config, on: try assessment(id, snap), snapshot: snap, registeredVaultUUIDs: [Self.u(1101)])
    }

    func testCommandsAreTheMeasuredShapes() throws {
        XCTAssertEqual(try plan(.addVolume(container: "disk3"), "disk2").arguments, ["apfs", "addVolume", "disk3", "APFS", "XCodeVault"])
        XCTAssertEqual(
            try plan(.addVolume(container: "disk3"), "disk2", VolumeConfiguration(caseSensitive: true, quotaGigabytes: 200)).arguments,
            ["apfs", "addVolume", "disk3", "Case-sensitive APFS", "XCodeVault", "-quota", "200g"])
        let free = try assessment("disk9", try Self.snapshot()).options.first!
        XCTAssertEqual(try plan(free, "disk9").arguments, ["addPartition", "disk9s2", "APFS", "XCodeVault", "0"])
        XCTAssertEqual(try plan(.eraseVolume(volume: "disk6s1", name: "STICK"), "disk6").arguments, ["eraseVolume", "APFS", "XCodeVault", "disk6s1"])
        let erase = try plan(.eraseDisk(disk: "disk6"), "disk6", VolumeConfiguration(name: "My Drive"))
        XCTAssertEqual(erase.arguments, ["eraseDisk", "APFS", "My Drive", "GPT", "disk6"])
        XCTAssertEqual(erase.command, "diskutil eraseDisk APFS 'My Drive' GPT disk6")
    }

    func testEraseListsWhatItDestroysAndNeedsTheExactName() throws {
        let disk = try plan(.eraseDisk(disk: "disk2"), "disk2")
        XCTAssertEqual(disk.destroys, [DestroyedVolume(id: "disk3s1", name: "Media", usedBytes: 649_000_000_000)])
        XCTAssertEqual(disk.confirmationName, "XS2000")
        let volume = try plan(.eraseVolume(volume: "disk3s1", name: "Media"), "disk2")
        XCTAssertEqual(volume.confirmationName, "Media")
        XCTAssertTrue(DiskPreparation.confirmationAccepted(typed: "Media", plan: volume))
        XCTAssertTrue(DiskPreparation.confirmationAccepted(typed: "  Media\n", plan: volume), "spaces from a paste")
        XCTAssertFalse(DiskPreparation.confirmationAccepted(typed: "media", plan: volume), "case matters")
        XCTAssertFalse(DiskPreparation.confirmationAccepted(typed: "", plan: volume))
        XCTAssertFalse(DiskPreparation.confirmationAccepted(typed: "Med", plan: volume))
        let add = try plan(.addVolume(container: "disk3"), "disk2")
        XCTAssertNil(add.confirmationName)
        XCTAssertEqual(add.destroys, [])
        XCTAssertTrue(DiskPreparation.confirmationAccepted(typed: "", plan: add))
    }

    func testPlanRefusesAnOptionNotOfferedAndAForgedOne() throws {
        let snap = try Self.snapshot()
        // Not in the assessment's options.
        XCTAssertThrowsError(try plan(.eraseDisk(disk: "disk10"), "disk10"))
        // A forged assessment that offers an erase on the vault disk: the guard inside `plan` still refuses.
        var forged = try assessment("disk10", snap)
        forged.options = [.eraseDisk(disk: "disk10")]
        XCTAssertThrowsError(
            try DiskPreparation.plan(.eraseDisk(disk: "disk10"), configuration: .init(), on: forged, snapshot: snap, registeredVaultUUIDs: [Self.u(1101)])
        ) { XCTAssertTrue("\($0)".contains("registered vault")) }
        // A forged assessment for the internal disk.
        var onInternal = try assessment("disk2", snap)
        onInternal.disk = snap.disks.first { $0.id == "disk0" }!
        onInternal.options = [.eraseDisk(disk: "disk0")]
        XCTAssertThrowsError(
            try DiskPreparation.plan(.eraseDisk(disk: "disk0"), configuration: .init(), on: onInternal, snapshot: snap, registeredVaultUUIDs: []))
        // A target that is not on the disk.
        var stray = try assessment("disk2", snap)
        stray.options = [.eraseVolume(volume: "disk1s1", name: "Macintosh HD - Data")]
        XCTAssertThrowsError(
            try DiskPreparation.plan(.eraseVolume(volume: "disk1s1", name: "x"), configuration: .init(), on: stray, snapshot: snap, registeredVaultUUIDs: []))
        XCTAssertThrowsError(try plan(.enableOwnership(mountPoint: "/Volumes/Media"), "disk2"))
    }

    func testVolumeNameValidation() {
        XCTAssertEqual(VolumeConfiguration().problems(for: .addVolume), [])
        XCTAssertFalse(VolumeConfiguration(name: "").problems(for: .eraseDisk).isEmpty)
        XCTAssertFalse(VolumeConfiguration(name: "-quota").problems(for: .addVolume).isEmpty)
        XCTAssertFalse(VolumeConfiguration(name: "a/b").problems(for: .addVolume).isEmpty)
        XCTAssertFalse(VolumeConfiguration(name: "a:b").problems(for: .addVolume).isEmpty)
        XCTAssertFalse(VolumeConfiguration(name: " lead").problems(for: .addVolume).isEmpty)
        XCTAssertFalse(VolumeConfiguration(quotaGigabytes: 10).problems(for: .eraseDisk).isEmpty, "a quota only for adding a volume")
        XCTAssertFalse(VolumeConfiguration(quotaGigabytes: 0).problems(for: .addVolume).isEmpty)
        XCTAssertEqual(VolumeConfiguration(name: "Dev Vault").problems(for: .eraseVolume), [])
    }

    func testShellQuoting() {
        XCTAssertEqual(DiskPreparation.shellQuoted("disk2"), "disk2")
        XCTAssertEqual(DiskPreparation.shellQuoted("Case-sensitive APFS"), "'Case-sensitive APFS'")
        XCTAssertEqual(DiskPreparation.shellQuoted("it's"), "'it'\\''s'")
    }

    // MARK: - Revalidation and the run

    func testRevalidateRefusesAChangedOrGoneDisk() throws {
        let p = try plan(.eraseDisk(disk: "disk6"), "disk6")
        let snap = try Self.snapshot()
        XCTAssertNoThrow(try DiskPreparation.revalidate(p, current: snap, registeredVaultUUIDs: []))
        var other = snap
        other.disks = snap.disks.map {
            var d = $0; if d.id == "disk6" { d.sizeBytes += 1 }; return d
        }
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: other, registeredVaultUUIDs: [])) { XCTAssertTrue("\($0)".contains("disk changed")) }
        var renamed = snap
        renamed.disks = snap.disks.map {
            var d = $0; if d.id == "disk6" { d.mediaName = "Other" }; return d
        }
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: renamed, registeredVaultUUIDs: []))
        var gone = snap
        gone.disks.removeAll { $0.id == "disk6" }
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: gone, registeredVaultUUIDs: []))
        let gpt = try plan(.eraseDisk(disk: "disk2"), "disk2")
        var remapped = snap
        remapped.disks = snap.disks.map {
            var d = $0; if d.id == "disk2" { d.partitions[0].diskUUID = Self.u(77) }; return d
        }
        XCTAssertThrowsError(try DiskPreparation.revalidate(gpt, current: remapped, registeredVaultUUIDs: []), "a rewritten map is a different disk")
    }

    func testRevalidateRefusesWhenTheDiskBecameAVaultOrTimeMachineSincePreview() throws {
        let p = try plan(.eraseDisk(disk: "disk2"), "disk2")
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: try Self.snapshot(), registeredVaultUUIDs: [Self.u(301)]))
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: try Self.snapshot(marked: ["disk3s1"]), registeredVaultUUIDs: []))
        var tampered = p
        tampered.arguments = ["eraseDisk", "APFS", "X", "GPT", "disk0"]
        XCTAssertThrowsError(try DiskPreparation.revalidate(tampered, current: try Self.snapshot(), registeredVaultUUIDs: []))
    }

    func testExecuteRunsOneCommandAndJournalsIt() throws {
        let tmp = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: tmp.path + "/journal.jsonl"))
        let p = try plan(.eraseVolume(volume: "disk6s1", name: "STICK"), "disk6")
        let runner = DiskRecordingRunner(responses: ["diskutil eraseVolume": .init(status: 0, stdout: "Finished erase", stderr: "")])
        let outcome = try DiskPreparation.execute(
            p, confirmedName: "STICK", runner: runner, journal: journal, registeredVaultUUIDs: { [] }, snapshot: { try Self.snapshot() })
        XCTAssertEqual(runner.calls, [["diskutil", "eraseVolume", "APFS", "XCodeVault", "disk6s1"]])
        let states = try journal.entries().filter { $0.id == outcome.journalID }.map(\.state)
        XCTAssertEqual(states, [.planned, .started, .completed])
        XCTAssertEqual(try journal.entries().first?.kind, .diskPreparation)
        XCTAssertEqual(JournalTimeline.kind(of: try journal.entries()), .diskPreparation)
    }

    func testExecuteRefusesAWrongNameBeforeAnything() throws {
        let tmp = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: tmp.path + "/journal.jsonl"))
        let p = try plan(.eraseDisk(disk: "disk6"), "disk6")
        let runner = DiskRecordingRunner(responses: [:])
        XCTAssertThrowsError(
            try DiskPreparation.execute(
                p, confirmedName: "usb flash disk", runner: runner, journal: journal, registeredVaultUUIDs: { [] },
                snapshot: {
                    XCTFail("must not even read the disks")
                    return try Self.snapshot()
                }))
        XCTAssertEqual(runner.calls, [])
        XCTAssertTrue(try journal.entries().isEmpty)
    }

    func testExecuteRefusesAChangedDiskWithoutRunningDiskutil() throws {
        let tmp = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: tmp.path + "/journal.jsonl"))
        let p = try plan(.eraseDisk(disk: "disk6"), "disk6")
        let runner = DiskRecordingRunner(responses: [:])
        var changed = try Self.snapshot()
        changed.disks = changed.disks.map {
            var d = $0; if d.id == "disk6" { d.mediaName = "Different" }; return d
        }
        XCTAssertThrowsError(
            try DiskPreparation.execute(
                p, confirmedName: "USB Flash Disk", runner: runner, journal: journal, registeredVaultUUIDs: { [] }, snapshot: { changed }))
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(try journal.entries().map(\.state), [.planned, .failed])
    }

    func testAFailedCommandIsReportedWithTheCommandToCopyAndNoRetry() throws {
        let tmp = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: tmp.path + "/journal.jsonl"))
        let p = try plan(.addVolume(container: "disk3"), "disk2")
        let runner = DiskRecordingRunner(responses: ["diskutil apfs addVolume": .init(status: 1, stdout: "", stderr: "Error: -69877: Couldn't open device")])
        XCTAssertThrowsError(
            try DiskPreparation.execute(p, confirmedName: "", runner: runner, journal: journal, registeredVaultUUIDs: { [] }, snapshot: { try Self.snapshot() })
        ) { error in
            XCTAssertTrue("\(error)".contains("diskutil apfs addVolume disk3 APFS XCodeVault"))
            XCTAssertTrue("\(error)".contains("-69877"))
        }
        XCTAssertEqual(runner.calls.count, 1, "never retried, never escalated")
        XCTAssertEqual(try journal.entries().map(\.state), [.planned, .started, .failed])
    }

    // MARK: - The layout and Use This Drive

    func testLayoutIsDefinedOnce() {
        XCTAssertEqual(VaultLayout.Purpose.allCases.map(\.folderName), ["DerivedData", "Archives", "Runtimes"])
        XCTAssertEqual(VaultLayout.path(.derivedData, vaultDirectory: "/Volumes/T7/XCodeVault"), "/Volumes/T7/XCodeVault/DerivedData")
        XCTAssertEqual(VaultLayout.path(.runtimes, vaultDirectory: "/Volumes/T7/XCodeVault/"), "/Volumes/T7/XCodeVault/Runtimes")
        XCTAssertEqual(VaultLayout.path(.archives, in: Self.vaultCheck()), "/Volumes/Vault/XCodeVault/Archives")
        XCTAssertNil(VaultLayout.path(.archives, in: Self.vaultCheck(state: .absent, mount: nil)))
    }

    func testCreateFoldersMakesTheStandardLayout() throws {
        let tmp = TempDir()
        let vault = tmp.path + "/XCodeVault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        let made = try VaultLayout.createFolders(vaultDirectory: vault)
        XCTAssertEqual(made.map { ($0 as NSString).lastPathComponent }, ["DerivedData", "Archives", "Runtimes"])
        for p in made { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
        XCTAssertEqual(try VaultLayout.createFolders(vaultDirectory: vault), made, "creating again changes nothing")
    }

    func testCreateFoldersOnAReadOnlyVaultGivesOwnershipAdvice() throws {
        let tmp = TempDir()
        let vault = tmp.path + "/XCodeVault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vault)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault) }
        XCTAssertThrowsError(try VaultLayout.createFolders(vaultDirectory: vault)) { XCTAssertTrue("\($0)".contains("Cannot create")) }
    }

    // MARK: - Fix round 1

    /// C1: PABLO's exact shape — case-sensitive APFS, registered as a vault, usable. The new case-insensitive volume is
    /// offered and recommended; both erase options are refused, and the row says why.
    func testACaseSensitiveVaultIsOfferedANewVolumeAndNeverAnErase() throws {
        let snap = try Self.snapshot()
        let a = try assessment("disk2", snap, vaults: [Self.vaultCheck(uuid: Self.u(301), mount: "/Volumes/Media")])
        XCTAssertEqual(a.verdict, .ready)
        XCTAssertEqual(a.options, [.addVolume(container: "disk3")])
        XCTAssertTrue(a.isRecommended(.addVolume(container: "disk3")))
        XCTAssertEqual(a.recommendedOption, .addVolume(container: "disk3"))
        XCTAssertEqual(a.prepareAction, .prepare(.addVolume(container: "disk3")))
        XCTAssertFalse(a.options.contains(where: \.erases))
        XCTAssertEqual(a.eraseRefusals, [.holdsVault])
        XCTAssertEqual(a.shownRefusals, [.holdsVault], "the row says erasing is blocked by the vault")
        var forged = a
        forged.options = [.eraseDisk(disk: "disk2")]
        XCTAssertThrowsError(
            try DiskPreparation.plan(.eraseDisk(disk: "disk2"), configuration: .init(), on: forged, snapshot: snap, registeredVaultUUIDs: [Self.u(301)]))
    }

    /// C1: Prepare… beside a case-sensitive drive that can be used opens the recommended new volume, never Use This Drive.
    func testPrepareRoutesACaseSensitiveDriveToTheNewVolume() throws {
        let a = try assessment("disk2", try Self.snapshot())
        XCTAssertEqual(a.verdict, .canBeUsed)
        XCTAssertEqual(a.prepareAction, .prepare(.addVolume(container: "disk3")))
        // A plain APFS drive that can be used: registration.
        var snap = try Self.snapshot()
        snap.volumes = snap.volumes.map {
            var v = $0; if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }; return v
        }
        XCTAssertEqual(try assessment("disk2", snap).prepareAction, .useDrive)
    }

    /// M3: a disk holding a vault — mounted or not — is never repartitioned; adding a volume stays allowed.
    func testAddingAPartitionIsRefusedOnADiskHoldingAVault() throws {
        let snap = try Self.snapshot()
        let disk9 = try XCTUnwrap(snap.disks.first { $0.id == "disk9" })
        let absent = Self.vaultCheck(uuid: Self.u(902), state: .absent, mount: nil)
        XCTAssertEqual(
            DiskSafety.refusals(for: .addPartition, target: "disk9s2", on: disk9, in: snap, registeredVaultUUIDs: [Self.u(902)]), [.holdsVault])
        let a = try assessment("disk9", snap, vaults: [absent])
        XCTAssertFalse(a.options.contains { if case .addPartition = $0 { true } else { false } })
        XCTAssertFalse(a.options.contains(where: \.erases))
        XCTAssertTrue(a.shownRefusals.contains(.holdsVault))
        var forged = a
        forged.options = [.addPartition(after: "disk9s2", freeBytes: 1)]
        XCTAssertThrowsError(
            try DiskPreparation.plan(
                .addPartition(after: "disk9s2", freeBytes: 1), configuration: .init(), on: forged, snapshot: snap, registeredVaultUUIDs: [Self.u(902)]))
        let disk2 = try XCTUnwrap(snap.disks.first { $0.id == "disk2" })
        XCTAssertEqual(DiskSafety.refusals(for: .addVolume, target: "disk3", on: disk2, in: snap, registeredVaultUUIDs: [Self.u(301)]), [])
    }

    /// M1: MBR has no partition UUIDs; two sticks of the same model differ by their volume UUIDs.
    func testMBRSticksOfTheSameModelAreDifferentIdentities() throws {
        let snap = try Self.snapshot()
        let stick = try XCTUnwrap(snap.disks.first { $0.id == "disk6" })
        XCTAssertEqual(stick.identity.partitionUUIDs, [])
        XCTAssertTrue(stick.identity.isDistinguishable)
        var twin = stick
        twin.partitions[0].volumeUUID = Self.u(699)
        XCTAssertNotEqual(stick.identity, twin.identity)
        var blank = stick
        blank.partitions[0].volumeUUID = nil
        XCTAssertFalse(blank.identity.isDistinguishable, "no file system: media name and size only (ADR-0012 §6)")
        var weakSnap = snap
        weakSnap.disks = snap.disks.map { $0.id == "disk6" ? blank : $0 }
        let a = try assessment("disk6", weakSnap)
        XCTAssertTrue(a.identityIsWeak)
        XCTAssertTrue(a.options.contains(.eraseDisk(disk: "disk6")), "erasing stays offered; the confirmation says it")
    }

    /// M2: the volume is deleted and re-added under the same device id between preview and run: refused.
    func testRevalidateRefusesATargetReplacedUnderTheSameID() throws {
        let p = try plan(.eraseVolume(volume: "disk3s1", name: "Media"), "disk2")
        XCTAssertEqual(p.targetUUID, Self.u(301))
        XCTAssertEqual(p.targetName, "Media")
        func with(_ change: (inout APFSVolumeInfo) -> Void) throws -> DriveSnapshot {
            var snap = try Self.snapshot()
            snap.disks = snap.disks.map { d in
                var d = d
                if d.id == "disk2" { change(&d.containers[0].volumes[0]) }
                return d
            }
            return snap
        }
        // The identity includes the volume UUIDs, so a new UUID is caught there; the target check catches a rename.
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: try with { $0.uuid = Self.u(399) }, registeredVaultUUIDs: []))
        var renamed = try with { $0.name = "Other" }
        XCTAssertThrowsError(try DiskPreparation.revalidate(p, current: renamed, registeredVaultUUIDs: [])) {
            XCTAssertTrue("\($0)".contains("no longer the volume"))
        }
        renamed = try Self.snapshot()
        XCTAssertNoThrow(try DiskPreparation.revalidate(p, current: renamed, registeredVaultUUIDs: []))
    }

    /// Low: an unmounted HFS+ partition might be Time Machine; erasing it or the whole disk is refused, the rest is not.
    func testAnUnmountedHFSPartitionBlocksErasingItAndTheDisk() throws {
        var snap = try Self.snapshot()
        snap.disks = snap.disks.map { d in
            var d = d
            if d.id == "disk9" { d.partitions.append(DiskPartition(id: "disk9s3", content: "Apple_HFS", sizeBytes: 100_000_000_000, volumeName: "Old")) }
            return d
        }
        let a = try assessment("disk9", snap)
        XCTAssertFalse(a.options.contains(.eraseDisk(disk: "disk9")))
        XCTAssertFalse(a.options.contains(.eraseVolume(volume: "disk9s3", name: "Old")))
        XCTAssertTrue(a.options.contains(.eraseVolume(volume: "disk9s2", name: "Transfer")))
        XCTAssertTrue(a.shownRefusals.contains(.mightBeTimeMachine))
        // Mounted, the marker check can run: no longer refused for that reason.
        snap.volumes.append(Self.volume("disk9s3", "Old", uuid: Self.u(903), mount: "/Volumes/Old", fs: "Mac OS Extended (Journaled)", type: "hfs"))
        XCTAssertTrue(try assessment("disk9", snap).options.contains(.eraseDisk(disk: "disk9")))
    }

    func testInvisibleAndControlCharactersAreRefusedInAName() {
        for bad in ["a\u{7F}b", "a\u{85}b", "a\u{202E}b", "a\u{200B}b", "a\u{0007}b", "a\nb"] {
            XCTAssertFalse(VolumeConfiguration(name: bad).problems(for: .addVolume).isEmpty, bad.unicodeScalars.map { String($0.value, radix: 16) }.joined())
        }
        XCTAssertEqual(VolumeConfiguration(name: "Café Vault").problems(for: .addVolume), [])
    }

    func testTheMediaNameIsMatchedTrimmedOnBothSides() throws {
        var snap = try Self.snapshot()
        snap.disks = snap.disks.map {
            var d = $0; if d.id == "disk6" { d.mediaName = " USB Flash Disk  " }; return d
        }
        let p = try DiskPreparation.plan(
            .eraseDisk(disk: "disk6"), configuration: .init(), on: try assessment("disk6", snap), snapshot: snap, registeredVaultUUIDs: [])
        XCTAssertEqual(p.confirmationName, "USB Flash Disk")
        XCTAssertTrue(DiskPreparation.confirmationAccepted(typed: "USB Flash Disk", plan: p))
    }

    /// I2: registered, folders failed — a partial outcome, never "not registered".
    func testAFolderFailureAfterRegistrationIsAPartialOutcome() {
        let vault = VaultVolume(volumeUUID: "U", volumeName: "V", lastMountPoint: "/Volumes/V", registeredAt: Date(), sentinelID: "s")
        let partial = DriveRegistration.outcome(vault: vault) { throw VaultError("Cannot create /Volumes/V/XCodeVault/Archives: denied") }
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.vault, vault)
        XCTAssertTrue(partial.foldersError?.contains("Cannot create") ?? false)
        XCTAssertTrue(DriveRegistration.outcome(vault: vault) { ["/a"] }.isComplete)
    }

    /// I1: only a vault's standard folder is created, inside an existing vault directory.
    func testCreateStandardFolderCreatesOnlyThatFolder() throws {
        let tmp = TempDir()
        let vault = tmp.path + "/XCodeVault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        try VaultLayout.createStandardFolder(vault + "/DerivedData", vaultDirectory: vault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/DerivedData"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault + "/Archives"))
        XCTAssertThrowsError(try VaultLayout.createStandardFolder(vault + "/Elsewhere", vaultDirectory: vault))
        XCTAssertThrowsError(try VaultLayout.createStandardFolder(tmp.path + "/DerivedData", vaultDirectory: vault))
        XCTAssertThrowsError(try VaultLayout.createStandardFolder(tmp.path + "/Gone/Archives", vaultDirectory: tmp.path + "/Gone"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path + "/Gone"), "a missing vault directory is never created")
    }
}

/// Answers from fixtures by prefix and records every call. Never runs anything.
final class DiskRecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let responses: [String: CommandResult]
    init(responses: [String: CommandResult]) { self.responses = responses }
    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        let argv = [(executable as NSString).lastPathComponent] + arguments
        lock.withLock { recorded.append(argv) }
        let key = argv.joined(separator: " ")
        for (k, v) in responses.sorted(by: { $0.key.count > $1.key.count }) where key.hasPrefix(k) { return v }
        return CommandResult(status: 127, stdout: "", stderr: "DiskRecordingRunner: no response for \(key)")
    }
}

/// I2 at the CLI: `vault init` exits 3 when the vault was registered but its standard folders were not made.
final class R6VaultInitExitCodeTests: XCTestCase {
    func testVaultInitExitCodes() {
        let vault = VaultVolume(volumeUUID: "U", volumeName: "V", lastMountPoint: "/Volumes/V", registeredAt: Date(), sentinelID: "s")
        XCTAssertEqual(Vault.Init.exitCode(DriveRegistration.Outcome(vault: vault, folders: ["/a"], foldersError: nil)), 0)
        XCTAssertEqual(Vault.Init.exitCode(DriveRegistration.Outcome(vault: vault, folders: [], foldersError: "denied")), 3)
        XCTAssertEqual(Vault.Init.foldersNotCreated, 3)
    }
}
