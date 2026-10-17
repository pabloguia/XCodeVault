import XCTest

@testable import XCodeVaultCore

/// H18 follow-up: the vault folder made before ownership is turned on. Scratch directories only; the "volumes root" is
/// a temp directory, so no real volume, journal or registry is touched.
final class VaultFolderPrecreateTests: XCTestCase {
    private let uuid = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    private struct Rig {
        var t = TempDir()
        var mp: String { t.path + "/vols/DRIVE" }
        var journal: Journal { Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")) }
        var root: String { t.path + "/vols" }
    }

    private func rig() -> Rig {
        let r = Rig()
        try? FileManager.default.createDirectory(atPath: r.mp, withIntermediateDirectories: true)
        return r
    }

    private func run(
        _ r: Rig, mounted: Bool = true, volumeUUID: String? = nil, writable: Bool? = nil, uid: uid_t = getuid(), mountPoint: String? = nil
    ) -> VaultFolderPrecreate.Outcome {
        let id = volumeUUID ?? uuid
        return VaultFolderPrecreate.createBeforeOwnership(
            mountPoint: mountPoint ?? r.mp, volumeUUID: uuid, journal: r.journal, isMountPoint: { _ in mounted }, volumeUUIDAt: { _ in id },
            rootIsWritable: { writable ?? (access($0, W_OK) == 0) }, uid: uid, volumesRoot: r.root)
    }

    func testCreatesTheFolderOwnedByTheCallerAndJournalsIt() throws {
        let r = rig()
        XCTAssertEqual(run(r), .created(r.mp + "/Vault"))
        var st = stat()
        XCTAssertEqual(lstat(r.mp + "/Vault", &st), 0)
        XCTAssertEqual(st.st_uid, getuid())
        XCTAssertEqual(try r.journal.entries().filter { $0.state == .completed }.count, 1)
    }

    func testAFolderAlreadyThereIsLeftAlone() throws {
        let r = rig()
        try FileManager.default.createDirectory(atPath: r.mp + "/Vault", withIntermediateDirectories: false)
        try "x".write(toFile: r.mp + "/Vault/keep", atomically: true, encoding: .utf8)
        guard case .skipped = run(r) else { return XCTFail("a folder with files is not a vault") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.mp + "/Vault/keep"))
        XCTAssertNil(VaultFolderPrecreate.Outcome.alreadyThere("x").note)
    }

    func testAFolderOfAnotherOwnerIsSkipped() throws {
        let r = rig()
        try FileManager.default.createDirectory(atPath: r.mp + "/Vault", withIntermediateDirectories: false)
        guard case .skipped = run(r, uid: getuid() &+ 1) else { return XCTFail("expected skipped") }
    }

    func testASymlinkOrAFileInItsPlaceIsNeverFollowedOrReplaced() throws {
        let r = rig()
        let elsewhere = r.t.path + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: r.mp + "/Vault", withDestinationPath: elsewhere)
        guard case .skipped = run(r) else { return XCTFail("expected skipped for a symlink") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
    }

    func testRefusesWhatIsNotTheVolumeThatWasChosen() {
        let r = rig()
        guard case .skipped = run(r, mounted: false) else { return XCTFail("unmounted") }
        guard case .skipped = run(r, volumeUUID: "0F0E0D0C-0B0A-4908-8706-050403020100") else { return XCTFail("other volume") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.mp + "/Vault"))
    }

    func testRefusesAnythingButATopLevelVolume() {
        let r = rig()
        for mp in [r.root, r.root + "/", r.root + "/..", r.root + "/.", r.mp + "/sub", "/Users/x", r.mp + "/../x", "relative"] {
            guard case .skipped = run(r, mountPoint: mp) else { return XCTFail("\(mp) was not refused") }
        }
    }

    func testARootTheUserCannotWriteIsSkippedNotForced() {
        let r = rig()
        guard case .skipped = run(r, writable: false) else { return XCTFail("expected skipped") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.mp + "/Vault"))
    }

    func testAMkdirThatFailsIsReportedAndJournalled() throws {
        let r = rig()
        let mp = r.mp
        chmod(mp, 0o555)
        addTeardownBlock { chmod(mp, 0o755) }
        guard case .failed = run(r, writable: true) else { return XCTFail("expected failed") }
        XCTAssertEqual(try r.journal.entries().filter { $0.state == .failed }.count, 1)
    }

    func testAVolumeThatChangesDuringTheMkdirIsNotReportedAsCreated() throws {
        let r = rig()
        var calls = 0
        let outcome = VaultFolderPrecreate.createBeforeOwnership(
            mountPoint: r.mp, volumeUUID: uuid, journal: r.journal, isMountPoint: { _ in true },
            volumeUUIDAt: { _ in
                calls += 1
                return calls == 1 ? self.uuid : "0F0E0D0C-0B0A-4908-8706-050403020100"
            }, volumesRoot: r.root)
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(try r.journal.entries().filter { $0.state == .completed }.count, 0)
        XCTAssertEqual(try r.journal.entries().filter { $0.state == .failed }.count, 1)
    }

    func testAnUnwritableJournalIsSaidInTheNote() throws {
        let r = rig()
        let outcome = VaultFolderPrecreate.createBeforeOwnership(
            mountPoint: r.mp, volumeUUID: uuid, journal: Journal(url: URL(fileURLWithPath: "/nonexistent-dir-xcv/j.jsonl")), isMountPoint: { _ in true },
            volumeUUIDAt: { _ in self.uuid }, volumesRoot: r.root)
        XCTAssertEqual(outcome, .created(r.mp + "/Vault", journalled: false))
        XCTAssertTrue(outcome.note?.contains("journal") == true)
    }

    func testTheNoteSaysWhatHappened() {
        XCTAssertTrue(VaultFolderPrecreate.Outcome.created("/Volumes/D/Vault").note?.contains("/Volumes/D/Vault") == true)
        XCTAssertNotNil(VaultFolderPrecreate.Outcome.skipped("why").note)
        XCTAssertNotNil(VaultFolderPrecreate.Outcome.failed("why").note)
    }
}
