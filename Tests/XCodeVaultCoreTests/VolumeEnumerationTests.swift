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

    private func vault(at mp: String, uuid: String = "U-1") -> VaultVolume {
        VaultVolume(volumeUUID: uuid, volumeName: "Vault", lastMountPoint: mp, registeredAt: Date(), sentinelID: "tok")
    }

    /// The live volume mounted at `mp`, writable; `device` and `flags` vary for the snapshot and read-only cases.
    private func live(_ mp: String, device: String = "/dev/disk9s1", flags: UInt32 = 0) -> @Sendable (String) -> MountStatus.FilesystemInfo? {
        { path in path == mp ? MountStatus.FilesystemInfo(mountPoint: mp, device: device, typeName: "apfs", flags: flags) : nil }
    }

    private func verifier(
        _ t: TempDir, mountPoint mp: String, isMountPoint: Bool = true, uuid: String?, filesystem: (@Sendable (String) -> MountStatus.FilesystemInfo?)? = nil
    ) -> VaultVerifier {
        VaultVerifier(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), mountedVolumes: { [] },
            isMountPoint: { $0 == mp && isMountPoint }, volumeUUIDAt: { _ in uuid }, filesystemAt: filesystem ?? live(mp), mountTable: { [] })
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
        let check = verifier(t, mountPoint: mp, uuid: "U-1").check(vault(at: mp))
        XCTAssertEqual(check.state, .verified, check.detail)
        XCTAssertEqual(check.currentMountPoint, mp)
    }

    /// Ours by UUID, but the sentinel is wrong or missing: the same refusals as for a listed volume.
    func testAnUnlistedVaultStillNeedsItsSentinel() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        let ours = verifier(t, mountPoint: mp, uuid: "U-1")
        XCTAssertEqual(ours.check(vault(at: mp)).state, .sentinelMissing)
        try writeSentinel(mp, id: "WRONG")
        XCTAssertEqual(ours.check(vault(at: mp)).state, .foreign)
    }

    func testAnotherVolumeAtTheLastPathIsForeign() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let check = verifier(t, mountPoint: mp, uuid: "U-OTHER").check(vault(at: mp))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertTrue(check.detail.contains("A different volume"), check.detail)
    }

    /// The identity of what is mounted there cannot be read: not verified, never absent, and the text says why.
    func testAnUnidentifiableMountAtTheLastPathIsRefusedAndSaysSo() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let check = verifier(t, mountPoint: mp, uuid: nil).check(vault(at: mp))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertFalse(check.isUsable)
        XCTAssertTrue(check.detail.contains("could not be read"), check.detail)
    }

    /// The mount-point check decides whether the kernel is asked at all (review, L1): a plain directory at the last path
    /// holding a valid sentinel is never verified, whatever the UUID of the volume it lives on — it is shadow data.
    func testAPlainDirectoryAtTheLastPathIsNeverVerified() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let check = verifier(t, mountPoint: mp, isMountPoint: false, uuid: "U-1").check(vault(at: mp))
        XCTAssertNotEqual(check.state, .verified)
        XCTAssertFalse(check.isUsable)
        XCTAssertEqual(check.state, .ambiguous, "a local folder with content where the vault was: shadow data")
    }

    /// A snapshot of the vault's volume, or a read-only mount of it, reports the same UUID and must not pass (L4); nor
    /// may a filesystem whose mount point is not the last path, or one statfs cannot read.
    func testASnapshotOrReadOnlyMountOfTheVaultIsRefused() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        try writeSentinel(mp)
        let cases: [(String, @Sendable (String) -> MountStatus.FilesystemInfo?)] = [
            ("snapshot", live(mp, device: "com.apple.TimeMachine.2026-10-18-120000@/dev/disk9s1")),
            ("read-only", live(mp, flags: UInt32(MNT_RDONLY))),
            ("elsewhere", { _ in MountStatus.FilesystemInfo(mountPoint: "/", device: "/dev/disk1s1", typeName: "apfs", flags: 0) }),
            ("unreadable", { _ in nil }),
        ]
        for (name, fs) in cases {
            let check = verifier(t, mountPoint: mp, uuid: "U-1", filesystem: fs).check(vault(at: mp))
            XCTAssertEqual(check.state, .foreign, name)
            XCTAssertFalse(check.isUsable, name)
        }
        XCTAssertEqual(verifier(t, mountPoint: mp, uuid: "U-1").check(vault(at: mp)).state, .verified, "the control: the live volume")
    }

    // MARK: - Mounted somewhere else, and not listed (#51)

    /// A mount-table entry for `mp`: local and writable unless told otherwise.
    private static func entry(_ mp: String, device: String = "/dev/disk9s1", type: String = "apfs", flags: UInt32 = UInt32(MNT_LOCAL)) -> MountStatus.FilesystemInfo {
        MountStatus.FilesystemInfo(mountPoint: mp, device: device, typeName: type, flags: flags)
    }

    /// Records which mount points the UUID was asked for.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.withLock { paths.append(p) } }
        var all: [String] { lock.withLock { paths } }
    }

    /// The vault at `now`, its last path `last` (not a mount point), found only through the mount table `table`.
    private func elsewhere(
        _ t: TempDir, now: String, table: [MountStatus.FilesystemInfo], uuidAt: [String: String] = [:], mountPoints: Set<String>? = nil,
        filesystem: (@Sendable (String) -> MountStatus.FilesystemInfo?)? = nil, asked: Asked = Asked()
    ) -> VaultVerifier {
        let uuids = uuidAt.isEmpty ? [now: "U-1"] : uuidAt
        let points = mountPoints ?? [now]
        return VaultVerifier(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), mountedVolumes: { [] },
            isMountPoint: { points.contains($0) }, volumeUUIDAt: { asked.add($0); return uuids[$0] },
            filesystemAt: filesystem ?? { path in table.first { $0.mountPoint == path } }, mountTable: { table })
    }

    /// The case that was wrong: the vault's volume is mounted at another path and `diskutil` did not list it. It read
    /// "not connected"; the mount table names it, and it is verified there by its sentinel — as moved, never as verified.
    func testAVaultMountedElsewhereAndUnlistedIsFoundAsMoved() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let now = t.dir("new")
        try writeSentinel(now)
        let check = elsewhere(t, now: now, table: [Self.entry("/", device: "/dev/disk1s1"), Self.entry(now)]).check(vault(at: last))
        XCTAssertEqual(check.state, .movedMountPoint, check.detail)
        XCTAssertEqual(check.currentMountPoint, now)
        XCTAssertTrue(check.isUsable)
        // The control: the same vault with nothing in the table is not connected, as before.
        XCTAssertEqual(elsewhere(t, now: now, table: []).check(vault(at: last)).state, .absent)
    }

    /// Found by UUID, the sentinel still decides: missing, or another vault's, is never usable.
    func testAVaultFoundElsewhereStillNeedsItsSentinel() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let now = t.dir("new")
        let v = elsewhere(t, now: now, table: [Self.entry(now)])
        XCTAssertEqual(v.check(vault(at: last)).state, .sentinelMissing)
        try writeSentinel(now, id: "WRONG")
        XCTAssertEqual(v.check(vault(at: last)).state, .foreign)
        XCTAssertFalse(v.check(vault(at: last)).isUsable)
    }

    /// The demands made at the last path hold here too. Each case would have been found without its flaw (the control
    /// above); with it, nothing qualifies and the vault is not connected — not usable, and never verified.
    func testAMountElsewhereThatIsNotTheWritableLiveVolumeIsNotTaken() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let now = t.dir("new")
        try writeSentinel(now)
        let cases: [(String, VaultVerifier)] = [
            ("snapshot", elsewhere(t, now: now, table: [Self.entry(now, device: "com.apple.TimeMachine.x@/dev/disk9s1")])),
            ("not local", elsewhere(t, now: now, table: [Self.entry(now, flags: 0)])),
            ("not a vault file system", elsewhere(t, now: now, table: [Self.entry(now, type: "macfuse")])),
            ("another volume", elsewhere(t, now: now, table: [Self.entry(now)], uuidAt: [now: "U-OTHER"])),
            ("no identity", elsewhere(t, now: now, table: [Self.entry(now)], uuidAt: ["/elsewhere": "U-1"])),
            ("not a mount point", elsewhere(t, now: now, table: [Self.entry(now)], mountPoints: [])),
            ("statfs names another mount", elsewhere(t, now: now, table: [Self.entry(now)], filesystem: { _ in Self.entry("/") })),
            ("statfs says snapshot", elsewhere(t, now: now, table: [Self.entry(now)], filesystem: { _ in Self.entry(now, device: "s@/dev/disk9s1") })),
            ("statfs says read-only", elsewhere(t, now: now, table: [Self.entry(now)], filesystem: { _ in Self.entry(now, flags: UInt32(MNT_RDONLY)) })),
            ("statfs unreadable", elsewhere(t, now: now, table: [Self.entry(now)], filesystem: { _ in nil })),
        ]
        for (name, v) in cases {
            let check = v.check(vault(at: last))
            XCTAssertEqual(check.state, .absent, name)
            XCTAssertFalse(check.isUsable, name)
        }
    }

    /// Mounted read-only somewhere else: refused and said so, not "not connected" (review finding 2).
    func testAVaultMountedReadOnlyElsewhereIsRefusedAndSaysSo() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let now = t.dir("new")
        try writeSentinel(now)
        let check = elsewhere(t, now: now, table: [Self.entry(now, flags: UInt32(MNT_LOCAL) | UInt32(MNT_RDONLY))]).check(vault(at: last))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertFalse(check.isUsable)
        XCTAssertTrue(check.detail.contains("read-only"), check.detail)
    }

    /// Found elsewhere, but files were left at the last path: shadow data, and Xcode settings recorded earlier still point
    /// there. Not usable (review finding 1). The same holds when `diskutil` lists it at the new path.
    func testAVaultFoundElsewhereWithFilesAtItsLastPathIsAmbiguous() throws {
        let t = TempDir()
        let last = t.dir("old")
        let now = t.dir("new")
        try writeSentinel(now)
        // The control: an empty folder at the last path is not shadow data.
        XCTAssertEqual(elsewhere(t, now: now, table: [Self.entry(now)]).check(vault(at: last)).state, .movedMountPoint)
        try Data("x".utf8).write(to: URL(fileURLWithPath: last + "/left-behind"))
        let check = elsewhere(t, now: now, table: [Self.entry(now)]).check(vault(at: last))
        XCTAssertEqual(check.state, .ambiguous, check.detail)
        XCTAssertFalse(check.isUsable)
        let listed = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "Vault", volumeUUID: "U-1", mountPoint: now, filesystemPersonality: "APFS", filesystemType: "apfs",
            isInternal: false, isRemovableMedia: true, isEjectable: true, busProtocol: "USB", isSolidState: nil, isWritable: true, ownersEnabled: true,
            totalBytes: 2, freeBytes: 1, isBootVolume: false)
        let viaDiskutil = VaultVerifier(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), mountedVolumes: { [listed] }, isMountPoint: { $0 == now },
            volumeUUIDAt: { _ in nil }, filesystemAt: { _ in nil }, mountTable: { [] })
        XCTAssertEqual(viaDiskutil.check(vault(at: last)).state, .ambiguous)
    }

    /// One UUID mounted at two places cannot be told apart: refused, and neither is used.
    func testAVaultUUIDMountedTwiceElsewhereIsRefused() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let a = t.dir("a")
        let b = t.dir("b")
        try writeSentinel(a)
        try writeSentinel(b)
        let check = elsewhere(t, now: a, table: [Self.entry(a), Self.entry(b)], uuidAt: [a: "U-1", b: "U-1"], mountPoints: [a, b]).check(vault(at: last))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertFalse(check.isUsable)
        XCTAssertTrue(check.detail.contains("more than one place"), check.detail)
    }

    /// Snapshot, non-local and automount entries are not asked for their UUID at all — `getattrlist` never
    /// reaches a network or automounted path — and the last path is not asked twice.
    func testOnlyLocalWritableLiveMountsAreAskedForTheirUUID() throws {
        let t = TempDir()
        let last = t.path + "/old"
        let now = t.dir("new")
        try writeSentinel(now)
        let asked = Asked()
        let table = [
            Self.entry("/net", type: "autofs"), Self.entry("/dev", device: "devfs", type: "devfs"), Self.entry("/Volumes/smb", flags: 0),
            Self.entry("/Volumes/ro", flags: UInt32(MNT_LOCAL) | UInt32(MNT_RDONLY)), Self.entry("/Volumes/snap", device: "x@/dev/disk2s1"), Self.entry(last), Self.entry(now),
        ]
        let check = elsewhere(t, now: now, table: table, asked: asked).check(vault(at: last))
        XCTAssertEqual(check.state, .movedMountPoint, check.detail)
        XCTAssertEqual(asked.all, ["/Volumes/ro", now], "the read-only mount is asked, so that it can be named; nothing else")
    }

    /// The real mount table, read without `diskutil`: it holds the boot volume. Nothing is opened on any volume.
    func testTheRealMountTableIsReadAndHoldsTheRoot() {
        let table = MountStatus.mountedFilesystems()
        XCTAssertTrue(table.contains { $0.mountPoint == "/" }, "\(table.map(\.mountPoint))")
    }

    /// A registry entry without a volume UUID cannot be compared with what is mounted, and says that, not "unreadable".
    func testAVaultWithoutARecordedUUIDIsRefusedAndSaysSo() throws {
        let t = TempDir()
        let mp = t.dir("mnt")
        let check = verifier(t, mountPoint: mp, uuid: "U-1").check(vault(at: mp, uuid: ""))
        XCTAssertEqual(check.state, .foreign)
        XCTAssertTrue(check.detail.contains("no volume UUID"), check.detail)
    }

    /// A volume list that does not parse is an error, not an empty list (L3).
    func testAnUnparsableListIsAnErrorNotNoVolumes() {
        let garbage = FakeRunner(responses: ["diskutil list -plist": CommandResult(status: 0, stdout: "not a plist", stderr: "")])
        XCTAssertThrowsError(try VolumeDiscovery.enumerate(runner: garbage, retryDelay: 0))
        // The case that changed: a valid plist without the list, which used to read as no volumes at all.
        let empty = FakeRunner(responses: ["diskutil list -plist": CommandResult(status: 0, stdout: FlakyInfo.xml([:]), stderr: "")])
        XCTAssertThrowsError(try VolumeDiscovery.enumerate(runner: empty, retryDelay: 0))
    }
}
