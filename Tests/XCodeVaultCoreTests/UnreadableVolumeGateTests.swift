import Foundation
import XCTest

@testable import XCodeVaultCore

/// A volume `diskutil` listed but could not read is unknown, not absent (PR #51). The disk-preparation gate and the doctor
/// read the mounted volumes, so before this they could not see one: the disk was offered for erasing as if the volume —
/// a vault, a Time Machine backup, another macOS installation — were not there, and the doctor said nothing (review of
/// PR #51, M1 and M2).
final class UnreadableVolumeGateTests: XCTestCase {
    // MARK: - The disk gate

    func testADiskWithAnUnreadableVolumeRefusesEveryChange() throws {
        // `disk3s1` (Media) is on disk2; drop it from the mounted volumes, as an unreadable one is.
        let volumes = R6DriveTests.volumes().filter { $0.deviceNode != "/dev/disk3s1" }
        let plain = DriveSnapshot(disks: try R6DriveTests.disks(), volumes: volumes)
        let disk2 = try XCTUnwrap(plain.disks.first { $0.id == "disk2" })
        // The control: the same disk, the volume merely not mounted, keeps its options.
        XCTAssertEqual(DiskSafety.changeRefusals(disk2, in: plain), [])
        XCTAssertFalse(DriveEvaluation.assess(disk2, in: plain, vaults: []).options.isEmpty)

        let snap = DriveSnapshot(disks: plain.disks, volumes: volumes, unreadableVolumeIDs: ["disk3s1"])
        XCTAssertEqual(snap.unreadableVolumeIDs(on: disk2), ["disk3s1"])
        XCTAssertEqual(DiskSafety.changeRefusals(disk2, in: snap), [.volumeUnreadable])
        XCTAssertTrue(DiskSafety.eraseRefusals(disk2, in: snap, registeredVaultUUIDs: []).contains(.volumeUnreadable))
        XCTAssertTrue(DriveEvaluation.assess(disk2, in: snap, vaults: []).options.isEmpty)
        // Only its own disk.
        let disk6 = try XCTUnwrap(snap.disks.first { $0.id == "disk6" })
        XCTAssertFalse(DiskSafety.changeRefusals(disk6, in: snap).contains(.volumeUnreadable))
        XCTAssertTrue(DiskRefusal.volumeUnreadable.reason.contains("could not read a volume on this disk"))
    }

    /// A volume no disk of the snapshot claims could be on any of them, and the refusal says it cannot tell which.
    func testAnUnplaceableUnreadableVolumeRefusesEveryDisk() throws {
        let snap = DriveSnapshot(disks: try R6DriveTests.disks(), volumes: R6DriveTests.volumes(), unreadableVolumeIDs: ["disk99s1"])
        XCTAssertEqual(snap.unplacedUnreadableVolumeIDs, ["disk99s1"])
        for disk in snap.disks {
            let r = DiskSafety.changeRefusals(disk, in: snap)
            XCTAssertTrue(r.contains(.unplacedVolumeUnreadable), disk.id)
            XCTAssertFalse(r.contains(.volumeUnreadable), "\(disk.id): not said to be on this disk")
            XCTAssertEqual(snap.unreadableVolumeIDs(on: disk), [], disk.id)
        }
        XCTAssertTrue(DiskRefusal.unplacedVolumeUnreadable.reason.contains("cannot tell which disk it is on"))
        let placed = DriveSnapshot(disks: snap.disks, volumes: snap.volumes, unreadableVolumeIDs: ["disk3s1"])
        XCTAssertEqual(placed.unplacedUnreadableVolumeIDs, [], "the control: a placed one is not unplaced")
    }

    /// The check right before the command runs asks again on a fresh snapshot, and a volume that has become unreadable
    /// since the preview stops it.
    func testRevalidationRefusesWhenAVolumeHasBecomeUnreadable() throws {
        let snap = try R6DriveTests.snapshot()
        let disk6 = try XCTUnwrap(snap.disks.first { $0.id == "disk6" })
        let plan = try DiskPreparation.plan(
            .eraseDisk(disk: "disk6"), configuration: VolumeConfiguration(), on: DriveEvaluation.assess(disk6, in: snap, vaults: []),
            snapshot: snap, registeredVaultUUIDs: [])
        XCTAssertNoThrow(try DiskPreparation.revalidate(plan, current: snap, registeredVaultUUIDs: []), "the control")
        var now = snap
        now.unreadableVolumeIDs = ["disk6s1"]
        XCTAssertThrowsError(try DiskPreparation.revalidate(plan, current: now, registeredVaultUUIDs: [])) {
            XCTAssertTrue("\($0)".contains("could not read a volume"), "\($0)")
        }
    }

    /// `diskutil` over the R6 fixtures: the whole disks from their fixtures, every listed volume as an unmounted one, and
    /// one volume's `info` failing every time.
    final class OneUnreadable: CommandRunning, @unchecked Sendable {
        let failing: String
        init(failing: String) { self.failing = failing }

        func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
            func ok(_ data: Data) -> CommandResult { CommandResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "") }
            switch arguments {
            case ["list", "-plist"]: return ok(Fixtures.data("diskutil-list-r6.plist"))
            case ["apfs", "list", "-plist"]: return ok(Fixtures.data("diskutil-apfs-list-r6.plist"))
            case let a where a.count == 3 && a[0] == "info" && a[1] == "-plist":
                let id = a[2]
                if R6DriveTests.infoIDs.contains(id) { return ok(Fixtures.data("diskutil-info-r6-\(id).plist")) }
                if id == failing { return CommandResult(status: 1, stdout: "", stderr: "Could not find disk: \(id)") }
                let info: [String: Any] = [
                    "DeviceIdentifier": id, "DeviceNode": "/dev/" + id, "VolumeName": id, "MountPoint": "", "FilesystemType": "apfs",
                    "Internal": false, "WritableVolume": true,
                ]
                return ok(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
            default:
                return CommandResult(status: 1, stdout: "", stderr: "not faked: \(arguments)")
            }
        }
    }

    /// Through the read the app uses: the unreadable volume is carried into the snapshot, not dropped from it.
    func testTheSnapshotReadCarriesTheUnreadableVolume() throws {
        let snap = try DriveSnapshot.read(runner: OneUnreadable(failing: "disk3s1"), fileExists: { _ in false })
        XCTAssertEqual(snap.unreadableVolumeIDs, ["disk3s1"], "only the one that failed: every other volume was read")
        XCTAssertEqual(snap.volumes, [], "none mounted")
        let disk2 = try XCTUnwrap(snap.disks.first { $0.id == "disk2" })
        XCTAssertEqual(DiskSafety.changeRefusals(disk2, in: snap), [.volumeUnreadable])
        let control = try DriveSnapshot.read(runner: OneUnreadable(failing: "none"), fileExists: { _ in false })
        XCTAssertEqual(control.unreadableVolumeIDs, [])
    }

    // MARK: - The doctor

    private func report(home: String, unreadable: [String] = [], listed: Bool = true) -> ScanReport {
        let host = HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: home,
            dataVolumeFreeBytes: 100_000_000_000, dataVolumeTotalBytes: 500_000_000_000, userName: "tester", isRoot: false)
        var r = ScanReport(
            generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: [], devices: [], volumes: [],
            items: [], summary: ScanSummary(), warnings: [])
        r.unreadableVolumeIDs = unreadable
        r.volumesListed = listed
        return r
    }

    func testTheDoctorSaysWhichVolumesItCouldNotSee() {
        let t = TempDir()
        let doctor = Doctor(home: t.path, runner: FakeRunner(responses: [:]))
        XCTAssertNil(doctor.diagnose(report: report(home: t.path)).first { $0.id == "volumes-unreadable" }, "the control")

        let f = doctor.diagnose(report: report(home: t.path, unreadable: ["disk9s1", "disk9s2"]))
        let hit = f.first { $0.id == "volumes-unreadable" }
        XCTAssertEqual(hit?.severity, .warning)
        XCTAssertTrue(hit?.detail.contains("disk9s1, disk9s2") == true, "\(String(describing: hit))")

        let none = doctor.diagnose(report: report(home: t.path, listed: false)).first { $0.id == "volumes-unreadable" }
        XCTAssertEqual(none?.severity, .error, "no volume was checked: doctor must not exit 0")
        XCTAssertTrue(none?.title.contains("volume list could not be read") == true)
    }

    /// A vault missing from the list because it could not be read reads as not connected; the finding says it may be.
    func testTheAbsentVaultFindingNamesTheUnreadableVolumes() throws {
        let t = TempDir()
        let registry = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        try registry.save([VaultVolume(volumeUUID: "U-1", volumeName: "Vault", lastMountPoint: t.path + "/Vault", registeredAt: Date(), sentinelID: "s")])
        let doctor = Doctor(home: t.path, runner: FakeRunner(responses: [:]))
        let control = doctor.checkVaultVolumes(registry: registry, volumes: []).first { $0.id == "vault-absent:U-1" }
        XCTAssertNotNil(control)
        XCTAssertFalse(control?.detail.contains("could not read") == true, "the control")
        let hit = doctor.checkVaultVolumes(registry: registry, volumes: [], unreadable: ["disk9s1"]).first { $0.id == "vault-absent:U-1" }
        XCTAssertTrue(hit?.detail.contains("could not read disk9s1; the vault may be one of them") == true, "\(String(describing: hit))")
    }

    /// The scan records them as typed fields, not only as a warning line.
    func testTheScanRecordsThem() throws {
        let t = TempDir()
        let r = XCodeVaultCore.Scanner(
            runner: VolumeEnumerationTests.FlakyInfo(failures: 2), home: t.path, catalog: [], measureSizes: false, detectXcodeCapabilities: false).scan()
        XCTAssertEqual(r.unreadableVolumeIDs, ["disk9s1"])
        XCTAssertTrue(r.volumesListed)
        let failed = XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, catalog: [], measureSizes: false, detectXcodeCapabilities: false).scan()
        XCTAssertFalse(failed.volumesListed)
        XCTAssertEqual(failed.unreadableVolumeIDs, [])
    }
}
