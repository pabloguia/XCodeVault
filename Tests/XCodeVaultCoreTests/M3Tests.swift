import XCTest

@testable import XCodeVaultCore

/// Fault-injection and safety tests for the vault + migration engine. All on temp directories;
/// "volumes" are simulated by pointing the verifier at fake Volume records whose mount point is a
/// real mount point (the temp dir's filesystem) so ATTR_DIR_MOUNTSTATUS checks stay honest.
final class VaultTests: XCTestCase {
    func fakeVolume(uuid: String, mountPoint: String, name: String = "VAULT") -> Volume {
        Volume(
            deviceNode: "/dev/disk99s1", volumeName: name, volumeUUID: uuid, mountPoint: mountPoint, filesystemPersonality: "APFS",
            filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true,
            isWritable: true, ownersEnabled: true, totalBytes: 10, freeBytes: 5, isBootVolume: false)
    }

    func testRegisterRefusesUnsuitableAndNonMountPoints() throws {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        var v = fakeVolume(uuid: "U1", mountPoint: t.path)  // a plain directory, not a mount point
        XCTAssertThrowsError(try reg.register(v, journal: Journal(url: URL(fileURLWithPath: t.path + "/j")))) { XCTAssertTrue("\($0)".contains("mount point")) }
        v.filesystemType = "exfat"; v.filesystemPersonality = "ExFAT"
        XCTAssertThrowsError(try reg.register(v, journal: Journal(url: URL(fileURLWithPath: t.path + "/j")))) {
            XCTAssertTrue("\($0)".contains("not suitable"))
        }
    }

    func testVerifierStates() throws {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        // Simulate a registered volume whose "mount point" is the temp dir's real mount point (e.g. /System/Volumes/Data).
        let realMount = MountStatus.filesystem(containing: t.path)!.mountPoint
        let vaultDir = realMount + "/" + VaultVolume.directoryName  // may not be writable; we test the absent/ambiguous branches instead
        _ = vaultDir
        let absent = VaultVolume(volumeUUID: "U-absent", volumeName: "A", lastMountPoint: t.path + "/never", registeredAt: Date(), sentinelID: "s")
        let shadowMP = t.dir("shadow"); t.file("shadow/DerivedData/x.o", bytes: 4096)
        let ambiguous = VaultVolume(volumeUUID: "U-amb", volumeName: "B", lastMountPoint: shadowMP, registeredAt: Date(), sentinelID: "s")
        let foreign = VaultVolume(volumeUUID: "U-for", volumeName: "C", lastMountPoint: realMount, registeredAt: Date(), sentinelID: "s")
        try reg.save([absent, ambiguous, foreign])
        let verifier = VaultVerifier(registry: reg, mountedVolumes: { [] })
        let checks = try verifier.checkAll()
        XCTAssertEqual(checks.map(\.state), [.absent, .ambiguous, .foreign])
        XCTAssertEqual(checks[1].shadowBytes ?? 0 > 0, true)
        XCTAssertFalse(checks[1].isUsable)
        XCTAssertThrowsError(try verifier.resolveUsable("U-amb"))
        // Sentinel matching: mounted volume with the right UUID but no sentinel → sentinelMissing; matching sentinel → verified.
        let vol = fakeVolume(uuid: "U-live", mountPoint: realMount)
        let live = VaultVolume(volumeUUID: "U-live", volumeName: "D", lastMountPoint: realMount, registeredAt: Date(), sentinelID: "tok")
        try reg.save([live])
        let mp = t.dir("livemount")
        let liveVol = fakeVolume(uuid: "U-live", mountPoint: mp)
        let liveReg = VaultVolume(volumeUUID: "U-live", volumeName: "D", lastMountPoint: mp, registeredAt: Date(), sentinelID: "tok")
        try reg.save([liveReg])
        let v2 = VaultVerifier(registry: reg, mountedVolumes: { [liveVol] }, isMountPoint: { $0 == mp })
        XCTAssertEqual(v2.check(liveReg).state, .sentinelMissing)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        t.dir("livemount/" + VaultVolume.directoryName)
        try enc.encode(VaultSentinel(volumeUUID: "U-live", sentinelID: "WRONG", createdAt: Date(), createdBy: "t")).write(
            to: URL(fileURLWithPath: mp + "/" + VaultVolume.directoryName + "/" + VaultVolume.sentinelName))
        XCTAssertEqual(v2.check(liveReg).state, .foreign)
        try enc.encode(VaultSentinel(volumeUUID: "U-live", sentinelID: "tok", createdAt: Date(), createdBy: "t")).write(
            to: URL(fileURLWithPath: mp + "/" + VaultVolume.directoryName + "/" + VaultVolume.sentinelName))
        XCTAssertEqual(v2.check(liveReg).state, .verified)
        XCTAssertEqual(try v2.resolveUsable("D").1, mp + "/" + VaultVolume.directoryName)
        // Same volume mounted elsewhere ("Name 1"): movedMountPoint, still usable.
        let moved = fakeVolume(uuid: "U-live", mountPoint: mp)
        let stale = VaultVolume(volumeUUID: "U-live", volumeName: "D", lastMountPoint: t.path + "/old", registeredAt: Date(), sentinelID: "tok")
        let v3 = VaultVerifier(registry: reg, mountedVolumes: { [moved] }, isMountPoint: { $0 == mp })
        XCTAssertEqual(v3.check(stale).state, .movedMountPoint); XCTAssertTrue(v3.check(stale).isUsable)
        _ = vol
    }

    func testSentinelRoundTrip() throws {
        let t = TempDir()
        let dir = t.dir(VaultVolume.directoryName)
        let s = VaultSentinel(volumeUUID: "U", sentinelID: "tok", createdAt: Date(), createdBy: "test")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(s).write(to: URL(fileURLWithPath: dir + "/" + VaultVolume.sentinelName))
        XCTAssertEqual(VaultVerifier.readSentinel(at: dir)?.sentinelID, "tok")
        XCTAssertNil(VaultVerifier.readSentinel(at: t.path + "/nope"))
    }
}

final class TreeVerifierTests: XCTestCase {
    func testDetectsEveryKindOfDifference() throws {
        let t = TempDir()
        t.file("src/a/one.bin", bytes: 100); t.file("src/b.txt", bytes: 5); t.symlink("src/link", to: "a/one.bin")
        XCTAssertEqual(setxattr(t.path + "/src/b.txt", "user.tag", "v", 1, 0, 0), 0)
        // Perfect copy via ditto
        try ProcessCommandRunner().check(Tools.ditto, [t.path + "/src", t.path + "/dst"])
        var r = TreeVerifier(deep: true).verify(source: t.path + "/src", destination: t.path + "/dst")
        XCTAssertTrue(r.isIdentical, "\(r.mismatches)")
        XCTAssertEqual(r.sourceFiles, 3); XCTAssertEqual(r.hashedFiles, 2)
        // Same size, different content → only deep verification catches it
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: t.path + "/dst/a/one.bin")); try fh.seek(toOffset: 10);
        try fh.write(contentsOf: Data([0x42])); try fh.close()
        XCTAssertTrue(
            TreeVerifier(deep: false).verify(source: t.path + "/src", destination: t.path + "/dst").isIdentical,
            "shallow verification cannot see a same-size corruption")
        r = TreeVerifier(deep: true).verify(source: t.path + "/src", destination: t.path + "/dst")
        XCTAssertEqual(r.mismatches.map(\.reason), ["content hash differs"])
        // Missing, extra, xattr, symlink target, size, mode
        try FileManager.default.removeItem(atPath: t.path + "/dst/b.txt")
        t.file("dst/extra", bytes: 1)
        try FileManager.default.removeItem(atPath: t.path + "/dst/link"); t.symlink("dst/link", to: "elsewhere")
        r = TreeVerifier(deep: false).verify(source: t.path + "/src", destination: t.path + "/dst")
        let reasons = Set(r.mismatches.map { $0.reason.components(separatedBy: " ").first! })
        XCTAssertTrue(reasons.isSuperset(of: ["missing", "extra", "symlink"]), "\(r.mismatches)")
        XCTAssertFalse(r.isIdentical)
    }

    func testFileCountAloneWouldHavePassed() throws {
        // The prior art's check (destination count >= source count) passes a truncated copy. Ours must not.
        let t = TempDir()
        t.file("src/big.bin", bytes: 10_000); t.file("dst/big.bin", bytes: 0)
        let r = TreeVerifier(deep: false).verify(source: t.path + "/src", destination: t.path + "/dst")
        XCTAssertEqual(r.sourceFiles, r.destinationFiles)
        XCTAssertFalse(r.isIdentical)
        XCTAssertTrue(r.mismatches[0].reason.hasPrefix("size"))
    }
}

final class MigrationEngineTests: XCTestCase {
    /// Builds a fake home with Archives content and a "vault" that is a plain directory. The vault
    /// verifier is stubbed to treat that directory as a verified volume.
    struct Fixture {
        let t = TempDir()
        var home: String { t.path + "/home" }
        var archives: String { home + "/Library/Developer/Xcode/Archives" }
        var vaultMount: String { t.path + "/vault" }
        var vaultDir: String { vaultMount + "/" + VaultVolume.directoryName }
        var journal: Journal { Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")) }
        var registry: VaultRegistry { VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")) }
        init() throws {
            t.file("home/Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist", bytes: 200)
            t.file("home/Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/dSYMs/App.dSYM/x", bytes: 5000)
            t.file("home/Library/Developer/Xcode/Archives/2026-09-02/B.xcarchive/Info.plist", bytes: 10)
            t.dir("vault/" + VaultVolume.directoryName)
            let sentinel = VaultSentinel(volumeUUID: "VU", sentinelID: "tok", createdAt: Date(), createdBy: "t")
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(sentinel).write(to: URL(fileURLWithPath: vaultDir + "/" + VaultVolume.sentinelName))
            try registry.save([VaultVolume(volumeUUID: "VU", volumeName: "VAULT", lastMountPoint: vaultMount, registeredAt: Date(), sentinelID: "tok")])
        }
        /// A verifier that reports the vault as verified at `vaultMount` (bypassing the real mount check, which temp dirs cannot satisfy).
        func engine(afterCopy: (@Sendable (MigrationPlan) throws -> Void)? = nil) -> MigrationEngine {
            let mp = vaultMount
            let vol = Volume(
                deviceNode: "/dev/disk98s1", volumeName: "VAULT", volumeUUID: "VU", mountPoint: mp, filesystemPersonality: "APFS", filesystemType: "apfs",
                isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
                totalBytes: 1, freeBytes: 1, isBootVolume: false)
            return MigrationEngine(
                journal: journal, verifier: StubVerifier.make(registry: registry, volume: vol, mountPoint: mp), home: home, isXcodeRunning: { false },
                afterCopy: afterCopy)
        }
    }

    func testHappyPathCopiesVerifiesKeepsSourceThenExplicitRemoval() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        XCTAssertEqual(plan.destination, f.vaultDir + "/archives/Archives")
        XCTAssertTrue(plan.deepVerify)
        XCTAssertTrue(plan.warnings.contains { $0.contains("non-regenerable") })
        let outcome = try engine.copyAndVerify(plan)
        XCTAssertTrue(outcome.verification.isIdentical); XCTAssertFalse(outcome.sourceRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/2026-09-01/App.xcarchive/dSYMs/App.dSYM/x"), "source untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination + "/2026-09-01/App.xcarchive/dSYMs/App.dSYM/x"))
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: false), "non-regenerable needs explicit confirmation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives))
        let removed = try engine.removeSource(outcome, confirmNonRegenerable: true)
        XCTAssertTrue(removed.sourceRemoved); XCTAssertFalse(FileManager.default.fileExists(atPath: f.archives))
        let states = try f.journal.entries().filter { $0.id == plan.operationID }.map(\.state)
        XCTAssertEqual(
            states, [.planned, .started, .started, .completed, .started, .started, .completed],
            "PLAN, COPY, VERIFY, VERIFIED, CLEANUP-rename, CLEANUP-delete, DONE")
        // Restore refuses to overwrite, then restores when the destination is gone.
        let r = try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "Archives", to: f.archives)
        let back = try engine.copyAndVerify(r)
        XCTAssertTrue(back.verification.isIdentical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/2026-09-02/B.xcarchive/Info.plist"))
        XCTAssertThrowsError(try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "Archives", to: f.archives))
    }

    func testSourceMutationDuringCopyFailsVerificationAndKeepsSource() throws {
        let f = try Fixture()
        let src = f.archives
        let engine = f.engine(afterCopy: { _ in
            // Source changes after the copy (Xcode wrote a new archive mid-migration).
            FileManager.default.createFile(atPath: src + "/2026-09-03-new.xcarchive", contents: Data(repeating: 1, count: 10))
        })
        let plan = try engine.planExternalize(categoryID: "archives", source: src, vaultRef: "VU")
        XCTAssertThrowsError(try engine.copyAndVerify(plan)) { XCTAssertTrue("\($0)".contains("Verification failed"), "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination), "partial copy removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src + "/2026-09-01/App.xcarchive/Info.plist"), "source intact")
        XCTAssertEqual(try f.journal.entries().last?.state, .failed)
    }

    func testDestinationVanishingMidCopyFailsSafely() throws {
        let f = try Fixture()
        let vaultDir = f.vaultDir
        let engine = f.engine(afterCopy: { plan in
            // The drive was yanked: the copy is gone.
            try FileManager.default.removeItem(atPath: plan.destination)
            _ = vaultDir
        })
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        XCTAssertThrowsError(try engine.copyAndVerify(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/2026-09-02/B.xcarchive/Info.plist"))
        XCTAssertEqual(try f.journal.entries().last?.state, .failed)
    }

    func testCorruptedCopyIsCaughtByDeepVerification() throws {
        let f = try Fixture()
        let engine = f.engine(afterCopy: { plan in
            let p = plan.destination + "/2026-09-01/App.xcarchive/dSYMs/App.dSYM/x"
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: p)); try fh.seek(toOffset: 100); try fh.write(contentsOf: Data([0xFF])); try fh.close()
        })
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        XCTAssertThrowsError(try engine.copyAndVerify(plan)) { XCTAssertTrue("\($0)".contains("content hash differs"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives))
    }

    func testInterruptedMigrationBlocksNewOnesUntilAborted() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        // Simulate a crash right after COPY started: journal has planned+started, partial copy on disk.
        try f.journal.record(id: plan.operationID, kind: .migration, state: .planned, summary: "x", paths: [plan.source, plan.destination])
        try f.journal.record(id: plan.operationID, kind: .migration, state: .started, summary: "COPY", paths: [plan.source, plan.destination])
        try FileManager.default.createDirectory(atPath: plan.destination, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plan.destination + "/partial", contents: Data([1]))
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")) {
            XCTAssertTrue("\($0)".contains("interrupted"))
        }
        XCTAssertEqual(try f.journal.interrupted().map(\.id), [plan.operationID])
        try engine.abort(operationID: plan.operationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives), "abort never touches the source")
        XCTAssertEqual(try f.journal.interrupted(), [])
        XCTAssertNoThrow(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU"))
    }

    func testRefusesRegenerableCategoriesSymlinksAndUnknownVaults() throws {
        let f = try Fixture()
        let engine = f.engine()
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "derivedData", source: f.home + "/Library/Developer/Xcode/DerivedData", vaultRef: "VU")) {
            XCTAssertTrue("\($0)".contains("coldStorage"))
        }
        f.t.symlink("home/Library/Developer/Xcode/ArchivesLink", to: f.archives)
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.home + "/Library/Developer/Xcode/ArchivesLink", vaultRef: "VU"))
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "NOPE"))
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.t.dir("elsewhere"), vaultRef: "VU")) {
            XCTAssertTrue("\($0)".contains("not under"))
        }
    }
}

/// A VaultVerifier whose mount-point check treats the fixture directory as a mounted volume.
enum StubVerifier {
    static func make(registry: VaultRegistry, volume: Volume, mountPoint: String) -> VaultVerifier {
        VaultVerifier(registry: registry, mountedVolumes: { [volume] }, isMountPoint: { $0 == mountPoint || MountStatus.isMountPoint($0) })
    }
}
