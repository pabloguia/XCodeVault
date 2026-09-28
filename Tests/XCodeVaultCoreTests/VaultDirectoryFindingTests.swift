import XCTest

@testable import XCodeVaultCore

/// Spec §2's first structured action, placed where the operator chose on 2026-09-27: `vault init` journals
/// the permission refusal, and `doctor` turns the latest one per volume into the finding `vault-dir:<uuid>`,
/// the only finding that carries an action. The text remediation stays as the fallback.
final class VaultDirectoryFindingTests: XCTestCase {
    private let uuid = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    private let otherUUID = "0F0E0D0C-0B0A-4908-8706-050403020100"

    private func volume(_ mountPoint: String, uuid: String? = nil, name: String = "VAULT", writable: Bool = true) -> Volume {
        Volume(
            deviceNode: "/dev/disk99s1", volumeName: name, volumeUUID: uuid ?? self.uuid, mountPoint: mountPoint, filesystemPersonality: "APFS",
            filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true,
            isWritable: writable, ownersEnabled: true, totalBytes: 10, freeBytes: 5, isBootVolume: false)
    }

    /// A mount point this user cannot write into, which is how a root-owned volume root refuses a regular
    /// user's `mkdir`: `EACCES`. Tests run as a regular user; root would write through the mode bits.
    private func unwritableMountPoint(_ t: TempDir) -> String {
        let mnt = t.dir("mnt")
        chmod(mnt, 0o555)
        addTeardownBlock { chmod(mnt, 0o755) }
        return mnt
    }

    private func register(_ reg: VaultRegistry, _ v: Volume, _ journal: Journal, directory: String = VaultVolume.directoryName) throws {
        let id = uuid
        try reg.register(v, relativeDirectory: directory, journal: journal, isMountPoint: { _ in true }, volumeUUID: { _ in id })
    }

    // MARK: - vault init journals the refusal the helper can fix, and only that one

    func testVaultInitJournalsAPermissionRefusalOfTheDefaultFolder() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        XCTAssertThrowsError(try register(reg, volume(unwritableMountPoint(t)), journal)) {
            // The text fallback is still printed, in the form that cannot create the mount point (carried note 4).
            let text = "\($0)"
            XCTAssertTrue(text.contains("sudo mkdir ") && text.contains("/\(VaultVolume.directoryName)' && sudo chown -h "), text)
            XCTAssertFalse(text.contains("install -d"), text)
        }
        let refusals = try journal.entries().filter(VaultDirectoryRefusal.matches)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.detail[VaultDirectoryRefusal.volumeUUIDKey], uuid)
    }

    func testACustomDirectoryIsNotJournalledBecauseTheHelperCannotCreateIt() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let v = volume(unwritableMountPoint(t))
        XCTAssertThrowsError(try register(reg, v, journal, directory: "Custom"))
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 0)
        // Positive control: the same volume and the default folder are journalled.
        XCTAssertThrowsError(try register(reg, v, journal))
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 1)
    }

    /// The journal write is `try?` so that a journal failure cannot replace the error the user can act on.
    func testAJournalThatCannotBeWrittenDoesNotReplaceTheRealError() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: "/dev/null/j.jsonl"))
        // Control: this journal really cannot be written, or the test proves nothing.
        XCTAssertThrowsError(try journal.record(kind: .migration, state: .failed, summary: "probe"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        XCTAssertThrowsError(try register(reg, volume(unwritableMountPoint(t)), journal)) {
            XCTAssertTrue($0 is VaultError, "the vault error must reach the user, not the journal's: \($0)")
        }
    }

    func testOnlyAPermissionRefusalCountsAsOne() {
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(CocoaError(.fileWriteNoPermission)))
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(wrapped))
        // A read-only volume or a full disk is not the helper's to fix, and must not be offered it.
        XCTAssertFalse(VaultDirectoryRefusal.isPermissionRefusal(CocoaError(.fileWriteVolumeReadOnly)))
        XCTAssertFalse(VaultDirectoryRefusal.isPermissionRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    }

    func testOnlyTheRefusalRecordMatches() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        // The shape of `register`'s other failure, the unusable-directory record: same kind and state.
        try journal.record(kind: .migration, state: .failed, summary: "vault directory unusable: …", paths: ["/Volumes/VAULT/XCodeVault"])
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 0)
        try journal.record(
            kind: .migration, state: .failed, summary: "refusal",
            detail: [VaultDirectoryRefusal.reasonKey: VaultDirectoryRefusal.reason, VaultDirectoryRefusal.volumeUUIDKey: uuid])
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 1)  // positive control
    }

    // MARK: - doctor turns it into the finding while it is actionable

    private func journalWithRefusal(_ t: TempDir, uuid: String? = nil) throws -> Journal {
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        try journal.record(
            kind: .migration, state: .failed, summary: "vault folder could not be created (permission)",
            detail: [VaultDirectoryRefusal.reasonKey: VaultDirectoryRefusal.reason, VaultDirectoryRefusal.volumeUUIDKey: uuid ?? self.uuid])
        return journal
    }

    /// `folderState` is injected so these rules run against `/Volumes/<name>` mount points, the only shape the
    /// helper accepts, without touching `/Volumes`. The real `lstat` is tested on its own below.
    private func findings(
        _ t: TempDir, volumes: [Volume], registry: VaultRegistry? = nil, folder: VaultDirectoryRefusal.FolderState = .absent,
        journalUUID: String? = nil
    ) throws -> [Finding] {
        Doctor(home: t.path).checkUncreatableVaultDirectories(
            registry: registry ?? VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), journal: try journalWithRefusal(t, uuid: journalUUID),
            volumes: volumes, folderState: { _ in folder })
    }

    func testARefusalOnAMountedUnregisteredVolumeIsTheFindingWithTheAction() throws {
        let t = TempDir()
        let f = try findings(t, volumes: [volume("/Volumes/VAULT")])
        let dir = "/Volumes/VAULT/" + VaultVolume.directoryName
        XCTAssertEqual(f.map(\.id), ["vault-dir:\(uuid)"])
        XCTAssertEqual(f.first?.action, .createVaultDirectory(volumeUUID: uuid))
        // The folder named, and the command printed for it, are the vault folder — never the drive's top folder.
        XCTAssertEqual(f.first?.path, dir)
        XCTAssertTrue(f.first?.remediation?.contains(OwnershipAdvice.createVaultDirectoryInPlaceCommand(dir)) ?? false, "\(f)")
    }

    /// The printed command must not be able to create the drive's mount point: run after an eject, `install -d`
    /// would leave a root-owned `/Volumes/<name>` on the internal disk (migration-safety review, 2026-09-28).
    func testThePrintedCommandCannotCreateTheMountPoint() {
        let command = OwnershipAdvice.createVaultDirectoryInPlaceCommand("/Volumes/VAULT/XCodeVault")
        XCTAssertTrue(command.hasPrefix("sudo mkdir '"), command)
        // No parents (`-p`, `install -d`), and no path-based mode change after creating (`-m`).
        XCTAssertFalse(command.contains("install -d") || command.contains("mkdir -p") || command.contains("mkdir -m"), command)
        // And the ownership change does not follow a symlink swapped in between the two commands.
        XCTAssertTrue(command.contains(" && sudo chown -h "), command)
        // `vault init` prints the same command for the default folder since carried note 4 of the plan.
        XCTAssertEqual(
            OwnershipAdvice.createVaultDirectoryCommand(mountPoint: "/Volumes/VAULT", relativeDirectory: "XCodeVault", exists: { _ in false }), command)
    }

    func testTheRefusalIsMatchedToItsOwnVolumeByUUID() throws {
        let t = TempDir()
        let other = volume("/Volumes/OTHER", uuid: otherUUID, name: "OTHER")
        // Only another drive is mounted: nothing to offer.
        XCTAssertEqual(try findings(t, volumes: [other]), [])
        // The other drive listed first, and the refusal recorded in lowercase: the match is by UUID, whatever
        // its case, and names the right drive.
        let t2 = TempDir()
        let f = try findings(t2, volumes: [other, volume("/Volumes/VAULT")], journalUUID: uuid.lowercased())
        XCTAssertEqual(f.map(\.path), ["/Volumes/VAULT/" + VaultVolume.directoryName])
        XCTAssertEqual(f.first?.action, .createVaultDirectory(volumeUUID: uuid))
    }

    /// The injected folder check above must not be the only one ever run: production calls the rule without
    /// it (`diagnoseVault`), so its default is pinned here, on a temporary mount point outside `/Volumes` —
    /// nothing touches `/Volumes`, and the action is absent there, which the finding does not need.
    func testTheProductionFolderCheckIsTheRealLstat() throws {
        let t = TempDir()
        let mnt = t.dir("mnt")
        let doctor = Doctor(home: t.path)
        let registry = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let journal = try journalWithRefusal(t)
        XCTAssertEqual(doctor.checkUncreatableVaultDirectories(registry: registry, journal: journal, volumes: [volume(mnt)]).count, 1, "absent")
        t.dir("mnt/" + VaultVolume.directoryName)
        XCTAssertEqual(doctor.checkUncreatableVaultDirectories(registry: registry, journal: journal, volumes: [volume(mnt)]), [], "present")
    }

    func testTheFindingDisappearsOnceTheFolderExists() throws {
        let t = TempDir()
        XCTAssertEqual(try findings(t, volumes: [volume("/Volumes/VAULT")], folder: .present), [], "the helper would not adopt it anyway")
    }

    func testAFolderThatCannotBeLookedAtIsNotAbsent() throws {
        let t = TempDir()
        XCTAssertEqual(try findings(t, volumes: [volume("/Volumes/VAULT")], folder: .unknown), [])
    }

    func testTheRealLstatSaysAbsentOnlyForENOENT() {
        let t = TempDir()
        let mnt = t.dir("mnt")
        XCTAssertEqual(VaultDirectoryRefusal.folderState(mnt + "/XCodeVault"), .absent)
        t.dir("mnt/XCodeVault")
        XCTAssertEqual(VaultDirectoryRefusal.folderState(mnt + "/XCodeVault"), .present)
        // A parent this user cannot search: `lstat` answers EACCES, and the folder may well be there.
        chmod(mnt, 0o000)
        defer { chmod(mnt, 0o755) }
        XCTAssertEqual(VaultDirectoryRefusal.folderState(mnt + "/XCodeVault"), .unknown)
    }

    func testTheFindingDisappearsOnceTheVolumeIsRegistered() throws {
        let t = TempDir()
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        try reg.save([
            VaultVolume(
                volumeUUID: uuid, volumeName: "VAULT", lastMountPoint: "/Volumes/VAULT", registeredAt: Date(), sentinelID: "s",
                relativeDirectory: VaultVolume.directoryName)
        ])
        XCTAssertEqual(try findings(t, volumes: [volume("/Volumes/VAULT")], registry: reg), [])
    }

    func testNoFindingWhileTheVolumeIsNotMounted() throws {
        let t = TempDir()
        XCTAssertEqual(try findings(t, volumes: []), [], "the helper resolves the UUID itself and refuses an unmounted volume")
    }

    func testNoFindingOnADriveThatNoLongerQualifies() throws {
        let t = TempDir()
        XCTAssertEqual(try findings(t, volumes: [volume("/Volumes/VAULT", writable: false)]), [], "read-only: both routes would fail")
    }

    /// The helper refuses any mount point but `/Volumes/<name>` (`HelperService.createVaultDirectory`), so the
    /// action is attached only there; the finding and its text stay everywhere.
    func testTheActionIsOfferedOnlyWhereTheHelperWouldAcceptTheMountPoint() throws {
        for mp in ["/Volumes/VAULT/nested", "/private/tmp/VAULT"] {
            let t = TempDir()
            let f = try findings(t, volumes: [volume(mp)])
            XCTAssertEqual(f.count, 1, mp)
            XCTAssertNil(f.first?.action, mp)
            XCTAssertNotNil(f.first?.remediation, mp)
        }
        XCTAssertTrue(VaultDirectoryRefusal.helperAccepts(mountPoint: "/Volumes/VAULT", volumeUUID: uuid))  // positive control
        XCTAssertFalse(VaultDirectoryRefusal.helperAccepts(mountPoint: "/Volumes/VAULT", volumeUUID: "not-a-uuid"))
        XCTAssertFalse(VaultDirectoryRefusal.helperAccepts(mountPoint: "/Volumes/", volumeUUID: uuid))
    }

    /// Spec §4: the structured action is present only on the vault-dir finding. A source scan, because
    /// running every doctor rule needs the real machine (`/Volumes`, `defaults`, `simctl`) and a test must
    /// not walk real volumes. Its limit: an action attached from outside `Doctor/` would escape it.
    func testOnlyTheVaultFolderFindingCarriesAnAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/XCodeVaultCore/Doctor")
        var hits: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Every `action:` argument passed in Doctor/, which is where a finding gets one; the property's
                // own declaration and comments are not arguments.
                guard !code.hasPrefix("//"), code.contains("action: "), !code.contains("var action") else { continue }
                hits.append("\(name): \(code)")
            }
        }
        XCTAssertEqual(hits.count, 1, "\(hits)")
        XCTAssertTrue(hits.first?.contains("createVaultDirectory") ?? false, "\(hits)")
    }
}
