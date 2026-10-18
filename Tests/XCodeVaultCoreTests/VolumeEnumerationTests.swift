import Foundation
import XCTest

@testable import XCodeVaultCore

/// One failed `diskutil info` must not make a mounted volume — a vault above all — read as absent (2026-10-18: a single
/// failure on the macos-26 CI runner removed a mounted disk image from the list between two commands seconds apart).
/// Every `diskutil` here is a fake; no test reads a real volume except through `MountStatus` defaults it does not use.
final class VolumeEnumerationTests: XCTestCase {
    /// `diskutil` that answers `list` with one volume, `disk9s1`, and fails its `info` the first `failures` times.
    final class FlakyInfo: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var infoCalls = 0
        let failures: Int
        init(failures: Int) { self.failures = failures }
        var calls: Int { lock.withLock { infoCalls } }

        func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
            switch arguments.prefix(2).joined(separator: " ") {
            case "list -plist":
                let list: [String: Any] = ["AllDisksAndPartitions": [["APFSVolumes": [["DeviceIdentifier": "disk9s1"]]]]]
                return CommandResult(status: 0, stdout: Self.xml(list), stderr: "")
            case "info -plist":
                let n = lock.withLock { () -> Int in
                    infoCalls += 1
                    return infoCalls
                }
                if n <= failures { return CommandResult(status: 1, stdout: "", stderr: "Could not find disk") }
                let info: [String: Any] = [
                    "DeviceIdentifier": "disk9s1", "VolumeName": "Vault", "MountPoint": "/Volumes/Vault", "VolumeUUID": "U-1",
                    "FilesystemType": "apfs",
                ]
                return CommandResult(status: 0, stdout: Self.xml(info), stderr: "")
            default:
                return CommandResult(status: 1, stdout: "", stderr: "not faked")
            }
        }

        static func xml(_ plist: [String: Any]) -> String {
            String(decoding: (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data(), as: UTF8.self)
        }
    }

    func testOneFailedInfoIsAskedAgainAndTheVolumeIsListed() throws {
        let runner = FlakyInfo(failures: 1)
        let found = try VolumeDiscovery.enumerate(runner: runner, retryDelay: 0)
        XCTAssertEqual(found.volumes.map(\.volumeUUID), ["U-1"])
        XCTAssertEqual(found.unreadable, [])
        XCTAssertEqual(runner.calls, 2, "asked once more, and no more")
    }

    func testAVolumeStillUnreadableIsReportedNotDropped() throws {
        let runner = FlakyInfo(failures: 2)
        let found = try VolumeDiscovery.enumerate(runner: runner, retryDelay: 0)
        XCTAssertEqual(found.volumes, [])
        XCTAssertEqual(found.unreadable, ["disk9s1"], "unknown, not absent")
        XCTAssertEqual(runner.calls, 2, "one retry, not a loop")
        XCTAssertEqual(try VolumeDiscovery.mountedVolumes(runner: FlakyInfo(failures: 0)).map(\.volumeUUID), ["U-1"])
    }

    // MARK: - The verifier, when `diskutil` did not list the vault

    private func vault(at mp: String) -> VaultVolume {
        VaultVolume(volumeUUID: "U-1", volumeName: "Vault", lastMountPoint: mp, registeredAt: Date(), sentinelID: "tok")
    }

    private func writeSentinel(_ mp: String, id: String = "tok") throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(atPath: mp + "/" + VaultVolume.directoryName, withIntermediateDirectories: true)
        try enc.encode(VaultSentinel(volumeUUID: "U-1", sentinelID: id, createdAt: Date(), createdBy: "t"))
            .write(to: URL(fileURLWithPath: mp + "/" + VaultVolume.directoryName + "/" + VaultVolume.sentinelName))
    }

    /// The kernel says the volume at the last path is ours: it is verified there by its sentinel, as when it is listed.
    /// Before, this read "A different volume is mounted at …" — the vault's own volume called foreign.
    func testAnUnlistedVaultIsVerifiedWhenTheKernelSaysTheMountIsOurs() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let verifier = VaultVerifier(registry: reg, mountedVolumes: { [] }, isMountPoint: { $0 == mp }, volumeUUIDAt: { $0 == mp ? "U-1" : nil })
        let check = verifier.check(vault(at: mp))
        XCTAssertEqual(check.state, .verified, check.detail)
        XCTAssertEqual(check.currentMountPoint, mp)
    }

    /// Ours by UUID, but the sentinel is wrong or missing: the same refusals as for a listed volume.
    func testAnUnlistedVaultStillNeedsItsSentinel() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let verifier = VaultVerifier(registry: reg, mountedVolumes: { [] }, isMountPoint: { $0 == mp }, volumeUUIDAt: { _ in "U-1" })
        XCTAssertEqual(verifier.check(vault(at: mp)).state, .sentinelMissing)
        try writeSentinel(mp, id: "WRONG")
        XCTAssertEqual(verifier.check(vault(at: mp)).state, .foreign)
    }

    func testAnotherVolumeAtTheLastPathIsForeign() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let other = VaultVerifier(registry: reg, mountedVolumes: { [] }, isMountPoint: { $0 == mp }, volumeUUIDAt: { _ in "U-OTHER" })
        let check = other.check(vault(at: mp))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertTrue(check.detail.contains("A different volume"), check.detail)
    }

    /// The identity of what is mounted there cannot be read: not verified, never absent, and the text says why.
    func testAnUnidentifiableMountAtTheLastPathIsRefusedAndSaysSo() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let blind = VaultVerifier(registry: reg, mountedVolumes: { [] }, isMountPoint: { $0 == mp }, volumeUUIDAt: { _ in nil })
        let check = blind.check(vault(at: mp))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertFalse(check.isUsable)
        XCTAssertTrue(check.detail.contains("could not be read"), check.detail)
    }
}
