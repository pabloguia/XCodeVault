import Foundation
import XCTest

@testable import XCodeVaultCore

/// A volume of another macOS installation is not "the boot volume" and its disk does not "hold the running system": the
/// running system is told by where it is mounted, another installation by its APFS role (migration-safety review of PR #50,
/// finding e). Each is refused for what it is, and the second is refused wider than before — never less.
final class OtherMacOSInstallTests: XCTestCase {
    private func info(_ fields: [String: Any]) throws -> Data {
        var d: [String: Any] = [
            "DeviceIdentifier": "disk9s1", "DeviceNode": "/dev/disk9s1", "VolumeName": "Other", "MountPoint": "/Volumes/Other",
            "FilesystemType": "apfs", "Internal": false, "WritableVolume": true,
        ]
        d.merge(fields) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    func testTheRunningSystemIsToldByItsMountPoint() throws {
        let data = try VolumeDiscovery.parse(diskutilInfoPlist: info(["MountPoint": "/System/Volumes/Data", "APFSVolumeRoles": ["Data"], "Internal": true]))
        XCTAssertTrue(data.isBootVolume)
        XCTAssertFalse(data.belongsToMacOSInstall, "the running system is the boot volume, not another installation")
        let root = try VolumeDiscovery.parse(diskutilInfoPlist: info(["MountPoint": "/", "APFSVolumeRoles": ["System"], "Internal": true]))
        XCTAssertTrue(root.isBootVolume)
        XCTAssertFalse(root.belongsToMacOSInstall)
    }

    /// An external macOS install's Data volume was a vault candidate before (no Internal, not mounted at a boot path);
    /// it is refused now, with its own reason, not the boot volume's.
    func testAnExternalInstallsVolumesAreRefusedForWhatTheyAre() throws {
        for role in ["Data", "System"] {
            let v = try VolumeDiscovery.parse(
                diskutilInfoPlist: info(["MountPoint": "/Volumes/Macintosh HD - \(role)", "APFSVolumeRoles": [role]]))
            XCTAssertFalse(v.isBootVolume, role)
            XCTAssertTrue(v.belongsToMacOSInstall, role)
            let q = VolumeQualification.evaluate(v)
            XCTAssertEqual(q.verdict, .unsuitable, role)
            XCTAssertTrue(q.blockers.contains { $0.contains("belongs to a macOS installation") }, "\(role): \(q.blockers)")
            XCTAssertFalse(q.blockers.contains { $0.contains("boot/system volume") }, "\(role): not called the running system")
        }
        let plain = try VolumeDiscovery.parse(diskutilInfoPlist: info([:]))
        XCTAssertFalse(plain.belongsToMacOSInstall, "no role: an ordinary volume")
        XCTAssertFalse(plain.isBootVolume)
    }

    /// The disk holding it refuses every preparation with its own reason, and the running system's disk keeps its own.
    func testItsDiskRefusesEveryPreparationWithItsOwnReason() throws {
        var volumes = R6DriveTests.volumes()
        let media = try XCTUnwrap(volumes.firstIndex { $0.deviceNode == "/dev/disk3s1" })
        volumes[media].belongsToMacOSInstall = true
        let snap = DriveSnapshot(disks: try R6DriveTests.disks(), volumes: volumes, timeMachineMarkedVolumeIDs: [])
        let disk2 = try XCTUnwrap(snap.disks.first { $0.id == "disk2" })
        XCTAssertEqual(snap.macOSInstallDiskIDs, ["disk2"])
        XCTAssertEqual(DiskSafety.changeRefusals(disk2, in: snap), [.holdsMacOSInstall])
        XCTAssertFalse(DiskSafety.changeRefusals(disk2, in: snap).contains(.bootDisk), "not the running system")
        let disk0 = try XCTUnwrap(snap.disks.first { $0.id == "disk0" })
        XCTAssertEqual(DiskSafety.changeRefusals(disk0, in: snap), [.internalDisk, .bootDisk])

        let before = DriveEvaluation.assess(disk2, in: try R6DriveTests.snapshot(), vaults: [])
        XCTAssertFalse(before.options.isEmpty, "the control: an ordinary external disk has options")
        let after = DriveEvaluation.assess(disk2, in: snap, vaults: [])
        XCTAssertTrue(after.options.isEmpty, "\(after.options)")
        XCTAssertTrue(DiskRefusal.holdsMacOSInstall.reason.contains("another macOS installation"))
    }
}
