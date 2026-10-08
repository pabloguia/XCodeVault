import XCTest

@testable import XCodeVaultCore

/// ADR-0015: the vault folder is named by the user, one per Mac on a drive, and a Mac can have vaults on several drives.
/// Scratch directories and injected identities only.
final class VaultFolderNameTests: XCTestCase {
    private let uuidA = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    private let uuidB = "0F0E0D0C-0B0A-4908-8706-050403020100"

    private func volume(_ uuid: String, _ mp: String, name: String = "DRIVE") -> Volume {
        Volume(
            deviceNode: "/dev/disk99s1", volumeName: name, volumeUUID: uuid, mountPoint: mp, filesystemPersonality: "APFS", filesystemType: "apfs",
            isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 10, freeBytes: 5, isBootVolume: false)
    }

    private func register(
        _ reg: VaultRegistry, _ v: Volume, _ folder: String, host: String?, journal: Journal
    ) throws -> VaultVolume {
        let id = v.volumeUUID ?? ""
        return try reg.register(v, relativeDirectory: folder, journal: journal, isMountPoint: { _ in true }, volumeUUID: { _ in id }, host: { host })
    }

    // MARK: - The name

    func testTheSuggestedNameIsVaultAndIsValid() {
        XCTAssertEqual(VaultFolderName.suggested, "Vault")
        XCTAssertNil(VaultFolderName.problem("Vault"))
        XCTAssertNil(VaultFolderName.problem("VaultMacEmpresa"))
        XCTAssertNil(VaultFolderName.problem("Vault do Mac pessoal"))
        XCTAssertNil(VaultFolderName.problem("Cofre ✓"))
    }

    func testWhatIsNotOneFolderIsRefused() {
        XCTAssertEqual(VaultFolderName.problem(""), .empty)
        XCTAssertEqual(VaultFolderName.problem("   "), .empty)
        XCTAssertEqual(VaultFolderName.problem(" Vault"), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("Vault "), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("a/b"), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("a:b"), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("a\0b"), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("a\nb"), .notOneFolder)
        XCTAssertEqual(VaultFolderName.problem("."), .dotName)
        XCTAssertEqual(VaultFolderName.problem(".."), .dotName)
        XCTAssertEqual(VaultFolderName.problem(String(repeating: "x", count: 201)), .tooLong)
        XCTAssertEqual(VaultFolderName.problem(String(repeating: "é", count: 101)), .tooLong, "length is in bytes, not characters")
    }

    func testASlashWithACombiningMarkIsStillASlash() {
        XCTAssertEqual(VaultFolderName.problem("a/\u{0301}b"), .notOneFolder)
    }

    func testNamesMacOSKeepsAreRefusedInAnyCase() {
        for n in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".TRASHES", ".DS_Store"] {
            XCTAssertEqual(VaultFolderName.problem(n), .hiddenSystemName, n)
        }
        XCTAssertNil(VaultFolderName.problem(".vault"), "another hidden name is the user's choice")
    }

    func testEveryProblemHasAMessageAndAFineNameHasNone() {
        for p in [VaultFolderName.Problem.empty, .notOneFolder, .dotName, .tooLong, .hiddenSystemName] {
            XCTAssertNotNil(VaultFolderName.message(for: p))
        }
        XCTAssertNil(VaultFolderName.message(for: nil))
    }

    // MARK: - Scenario B: several drives on one Mac

    func testTwoDrivesOnOneMacEachHaveTheirOwnVaultAndFolder() throws {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let a = t.dir("a"), b = t.dir("b")
        _ = try register(reg, volume(uuidA, a, name: "A"), "VaultMacPessoal", host: "mac1", journal: journal)
        _ = try register(reg, volume(uuidB, b, name: "B"), "VaultMacEmpresa", host: "mac1", journal: journal)
        let all = try reg.volumes()
        XCTAssertEqual(Set(all.map(\.relativeDirectory)), ["VaultMacPessoal", "VaultMacEmpresa"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a + "/VaultMacPessoal/" + VaultVolume.sentinelName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b + "/VaultMacEmpresa/" + VaultVolume.sentinelName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + "/XCodeVault"))
    }

    // MARK: - Scenario C: one drive shared by several Macs

    func testAnotherMacsFolderIsNeverTakenOrOverwritten() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let drive = t.dir("drive")
        // Mac 1 registers "Vault"; Mac 2 has its own registry.
        _ = try register(VaultRegistry(url: URL(fileURLWithPath: t.path + "/mac1.json")), volume(uuidA, drive), "Vault", host: "mac1", journal: journal)
        let sentinelPath = drive + "/Vault/" + VaultVolume.sentinelName
        let before = try Data(contentsOf: URL(fileURLWithPath: sentinelPath))
        let reg2 = VaultRegistry(url: URL(fileURLWithPath: t.path + "/mac2.json"))
        XCTAssertThrowsError(try register(reg2, volume(uuidA, drive), "Vault", host: "mac2", journal: journal)) {
            XCTAssertTrue("\($0)".contains("another Mac"), "\($0)")
            XCTAssertTrue("\($0)".contains("Nothing was written"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sentinelPath)), before, "the other Mac's sentinel is untouched")
        XCTAssertEqual(try reg2.volumes().count, 0)
        // Its own folder works, beside the first.
        _ = try register(reg2, volume(uuidA, drive), "VaultMac2", host: "mac2", journal: journal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive + "/VaultMac2/" + VaultVolume.sentinelName))
    }

    func testThisMacsOwnFolderIsAdoptedAfterForgettingTheVault() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let drive = t.dir("drive")
        let first = try register(reg, volume(uuidA, drive), "Vault", host: "mac1", journal: journal)
        try reg.forget(uuid: uuidA)
        let again = try register(reg, volume(uuidA, drive), "Vault", host: "mac1", journal: journal)
        XCTAssertEqual(again.sentinelID, first.sentinelID, "the sentinel is reused, not rewritten")
    }

    func testASentinelFromBeforeTheHostWasRecordedIsAdopted() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let drive = t.dir("drive")
        try FileManager.default.createDirectory(atPath: drive + "/Vault", withIntermediateDirectories: false)
        let old = VaultSentinel(volumeUUID: uuidA, sentinelID: "legacy", createdAt: Date(), createdBy: "0.1")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(old).write(to: URL(fileURLWithPath: drive + "/Vault/" + VaultVolume.sentinelName))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        XCTAssertEqual(try register(reg, volume(uuidA, drive), "Vault", host: "mac1", journal: journal).sentinelID, "legacy")
    }

    func testASentinelOfAnotherVolumeOrAnUnreadableOneRefuses() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let drive = t.dir("drive")
        try FileManager.default.createDirectory(atPath: drive + "/Vault", withIntermediateDirectories: false)
        let path = drive + "/Vault/" + VaultVolume.sentinelName
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try register(reg, volume(uuidA, drive), "Vault", host: "mac1", journal: journal)) {
            XCTAssertTrue("\($0)".contains("cannot be read"), "\($0)")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(VaultSentinel(volumeUUID: uuidB, sentinelID: "x", createdAt: Date(), createdBy: "t", hostFingerprint: "mac1")).write(
            to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try register(reg, volume(uuidA, drive), "Vault", host: "mac1", journal: journal)) {
            XCTAssertTrue("\($0)".contains("another volume"), "\($0)")
        }
        XCTAssertEqual(try reg.volumes().count, 0)
    }

    // MARK: - Use This Drive and the precreate with a name

    func testUseDriveRefusesANameThatIsNotAFolder() {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let drive = t.dir("drive")
        for name in ["", "../x", "a/b", ".."] {
            XCTAssertThrowsError(
                try DriveRegistration.useDrive(
                    volume(uuidA, drive), folderName: name, registry: reg, journal: Journal(url: URL(fileURLWithPath: t.path + "/j"))), name)
        }
        XCTAssertEqual((try? reg.volumes().count) ?? -1, 0)
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: drive), [])
    }

    func testTheHelperStepIsOfferedOnlyForTheNameTheHelperMakes() {
        let v = volume(uuidA, "/Volumes/DRIVE")
        XCTAssertNil(DriveRegistration.vaultFolderHelperStep(v, folderName: "Vault", rootIsWritable: { _ in false }, folderIsAbsent: { _ in true }))
        XCTAssertNotNil(
            DriveRegistration.vaultFolderHelperStep(v, folderName: VaultVolume.directoryName, rootIsWritable: { _ in false }, folderIsAbsent: { _ in true }))
    }

    func testPrecreateMakesTheFolderUnderTheChosenName() throws {
        let t = TempDir()
        let mp = t.path + "/vols/DRIVE"
        try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        let id = uuidA
        let out = VaultFolderPrecreate.createBeforeOwnership(
            mountPoint: mp, volumeUUID: uuidA, journal: Journal(url: URL(fileURLWithPath: t.path + "/j")), isMountPoint: { _ in true },
            volumeUUIDAt: { _ in id },
            folderName: "VaultMacEmpresa", host: { "mac1" }, volumesRoot: t.path + "/vols")
        XCTAssertEqual(out, .created(mp + "/VaultMacEmpresa"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp + "/Vault"))
    }

    func testPrecreateRefusesABadNameAndAnotherMacsFolder() throws {
        let t = TempDir()
        let mp = t.path + "/vols/DRIVE"
        try FileManager.default.createDirectory(atPath: mp + "/Vault", withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(VaultSentinel(volumeUUID: uuidA, sentinelID: "x", createdAt: Date(), createdBy: "t", hostFingerprint: "mac1"))
            .write(to: URL(fileURLWithPath: mp + "/Vault/" + VaultVolume.sentinelName))
        let id = uuidA
        func run(_ name: String, host: String) -> VaultFolderPrecreate.Outcome {
            VaultFolderPrecreate.createBeforeOwnership(
                mountPoint: mp, volumeUUID: uuidA, journal: Journal(url: URL(fileURLWithPath: t.path + "/j")), isMountPoint: { _ in true },
                volumeUUIDAt: { _ in id }, folderName: name, host: { host }, volumesRoot: t.path + "/vols")
        }
        guard case .skipped = run("../x", host: "mac1") else { return XCTFail("bad name") }
        guard case .skipped(let why) = run("Vault", host: "mac2") else { return XCTFail("another Mac's folder") }
        XCTAssertTrue(why.contains("another Mac"))
        XCTAssertEqual(run("Vault", host: "mac1"), .alreadyThere(mp + "/Vault"))
    }
}
