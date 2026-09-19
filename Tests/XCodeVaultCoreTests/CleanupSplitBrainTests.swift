import XCTest

@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// Issue #24 — the cleanup verb deletes the shadow half of a split brain after a disconnect and
/// reports it as routine cleanup.
///
/// Every individual check in the verb is correct. The composition is what erases data: while the
/// volume is connected the descriptor-based mount query answers `.isMountPoint` and the verb
/// refuses; after a disconnect the local stub reappears `root:admin 0755`, the guarded walk passes,
/// the mount query *truthfully* answers `.isNotMountPoint`, and the contents are deleted with
/// `ok: true, "cleaned …"`.
///
/// The fix gives the verb the state its reviewer identified as missing — a record of what it has
/// previously observed at each target — so a plain directory where a mount point used to be is a
/// refusal rather than a cache clean.
final class CleanupSplitBrainTests: XCTestCase {
    private var base: URL!
    private let target = HelperCleanupTarget.coreSimulatorDyldCache

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        // The verb walks every component from the anchor and requires each to be owned by whoever
        // owns the anchor and not group/other-writable, so the tree has to be built that way.
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(target.path), withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)])
        // The record store anchors at `<base>/Library/Application Support` and guard-walks to it,
        // so it has to exist and be owned by whoever owns the anchor — the test user here.
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)])

        var p = base!
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: p.path)
        for component in target.path.split(separator: "/") {
            p = p.appendingPathComponent(String(component))
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: p.path)
        }
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private var targetDirectory: URL { base.appendingPathComponent(target.path) }

    private func seedOneFile() throws {
        FileManager.default.createFile(atPath: targetDirectory.appendingPathComponent("cache-entry").path, contents: Data([1, 2, 3]))
    }

    private func service() -> HelperService { HelperService(callerUID: getuid(), callerGID: getgid()) }

    /// Builds the store so it can be *read* and not *written*: every component present, owned and
    /// tight enough for the guarded walk, with the leaf left without write permission. This is the
    /// only way to reach the write-failure branch without reaching the read-failure one first.
    @discardableResult
    private func makeStoreUnwritable() throws -> String {
        let dir = HelperMountHistory.directory(under: base.path)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: dir)
        return dir
    }

    /// The verb, with the mount answer supplied — the only way to stage "a volume is mounted here"
    /// without a real volume and root. The anchor is the test's own tree, never `/`.
    private func clean(mountAnswer: HelperService.MountAnswer) -> HelperResult {
        service().doRemoveRegenerableSystemDirectoryContents(
            target: target.rawValue, under: base.path, mount: { _ in mountAnswer })
    }

    // MARK: the sequence the issue describes

    /// Connected → refuses, and **remembers**. Disconnected → refuses *because* it remembers,
    /// instead of cleaning the stub and calling it routine.
    func testAfterAMountIsSeenThePlainDirectoryThatReplacesItIsRefused() throws {
        try seedOneFile()

        // 1. While connected. The verb refuses because the path is a mount point.
        let connected = clean(mountAnswer: .isMountPoint)
        XCTAssertFalse(connected.ok)
        XCTAssertEqual(connected.message, "target is a mount point")
        XCTAssertEqual(
            HelperMountHistory.read(target: target, under: base.path), .observed(.wasMountPoint),
            "the refusal has to record what it saw, or the next run learns nothing from it")

        // 2. After a disconnect. The stub is a plain directory and the mount query says so
        //    truthfully — this is precisely the state in which the verb used to delete.
        let afterDisconnect = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(afterDisconnect.ok, "this is the split-brain deletion the issue is about")
        XCTAssertTrue(
            afterDisconnect.message.contains("was a mount point when last seen"),
            "and the refusal has to say why, in terms of shadow data. Got: \(afterDisconnect.message)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    /// The control. Without it the assertion above passes for any reason the verb declined,
    /// including the wrong one.
    func testAnOrdinaryCacheDirectoryIsStillCleaned() throws {
        try seedOneFile()
        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertTrue(r.ok, "a target never seen as a mount point is an ordinary cache: \(r.message)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "and its contents are removed")
    }

    // MARK: the success message

    /// The issue's minimum ask: a shadow-data deletion must not be able to render as a bare
    /// "cleaned". The message now says what was checked, not only what was done.
    func testTheSuccessMessageSaysWhatWasCheckedNotJustWhatWasDone() throws {
        try seedOneFile()
        let first = clean(mountAnswer: .isNotMountPoint)
        XCTAssertTrue(first.ok)
        XCTAssertTrue(
            first.message.contains("no prior mount ever observed here"),
            "a first clean has no history, and must say so rather than claim more. Got: \(first.message)")

        try seedOneFile()
        let second = clean(mountAnswer: .isNotMountPoint)
        XCTAssertTrue(second.ok)
        XCTAssertTrue(
            second.message.contains("previously observed as a plain directory"),
            "a repeat clean has a record and may say the stronger thing. Got: \(second.message)")
    }

    // MARK: the record itself

    /// Three answers, because two would be the collapse this project has now found four times.
    /// A record that exists and cannot be read is **not** "never seen".
    func testAnUnreadableRecordRefusesRatherThanReadingAsNeverSeen() throws {
        try seedOneFile()
        let dir = HelperMountHistory.directory(under: base.path)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        // Something this version does not understand — the same class as a truncated or
        // future-format record.
        try "something-else".write(toFile: dir + "/" + target.rawValue, atomically: true, encoding: .utf8)

        // The reason no longer quotes the file's contents: they reach a `.public` audit log line.
        XCTAssertEqual(HelperMountHistory.read(target: target, under: base.path), .unreadable("unrecognised record"))
        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok, "an unreadable record may hide an observation saying stop")
        XCTAssertTrue(r.message.contains("could not read what was previously observed"), r.message)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed while the record is unreadable")
    }

    func testAnAbsentRecordIsADefiniteNeverSeen() {
        XCTAssertEqual(HelperMountHistory.read(target: target, under: base.path), .none)
    }

    /// The other half of the same collapse, and the one mutation testing showed was uncovered: an
    /// `lstat` that fails for a reason **other** than absence. `ENOENT` and `ENOTDIR` mean the
    /// record is not there; `EACCES` means it may be there and may say stop, which is the opposite
    /// answer. Staged by making the record directory unreadable, which needs no privilege.
    func testARecordBehindAnUnreadableDirectoryIsNotReadAsNeverSeen() throws {
        try seedOneFile()
        let dir = HelperMountHistory.directory(under: base.path)
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: target, under: base.path))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir) }

        // Precondition: this environment really does deny the read. Running as root would not fail
        // the assertions below, it would make them vacuous.
        var st = stat()
        try XCTSkipIf(
            lstat(dir + "/" + target.rawValue, &st) == 0,
            "this environment can stat through a 0o000 directory (running as root?), so the branch is unreachable here")

        guard case .unreadable = HelperMountHistory.read(target: target, under: base.path) else {
            return XCTFail("an EACCES on the record must be `.unreadable`, never `.none` — `.none` means 'proceed'")
        }
        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok, "the verb must refuse while it cannot read what it previously observed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    /// A record that cannot be written silently disables the guard for the *next* run, so the verb
    /// refuses rather than cleaning on a promise it cannot keep.
    ///
    /// Staged so the **read** still succeeds — the store is reachable and holds no record — and only
    /// the write fails, because the leaf directory is not writable. Blocking the store outright
    /// refuses at the read instead, which is the assertion below the next test makes; this one would
    /// then have passed without the write path ever running.
    func testAFailedWriteRefusesRatherThanCleaningSilently() throws {
        try seedOneFile()
        let dir = try makeStoreUnwritable()
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir) }

        XCTAssertEqual(
            HelperMountHistory.read(target: target, under: base.path), .none,
            "precondition: the read reaches the store and finds nothing — only the write may fail")
        try XCTSkipIf(
            HelperMountHistory.write(.wasPlainDirectory, target: target, under: base.path),
            "this environment can create files in a 0o500 directory (running as root?), so the branch is unreachable here")

        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("could not record what was observed"), r.message)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    /// The same policy on the arm that matters more. Seeing a mount point and failing to record it
    /// leaves the *next* run in the unguarded state this issue is about, so the refusal has to say
    /// the observation was lost rather than read as an ordinary "it is mounted, try later".
    func testAFailedWriteOnTheMountPointArmIsAlsoReported() throws {
        try seedOneFile()
        let dir = try makeStoreUnwritable()
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir) }
        try XCTSkipIf(
            HelperMountHistory.write(.wasMountPoint, target: target, under: base.path),
            "this environment can create files in a 0o500 directory (running as root?), so the branch is unreachable here")

        let r = clean(mountAnswer: .isMountPoint)
        XCTAssertFalse(r.ok, "it declines either way — what changes is whether the operator learns the record is missing")
        XCTAssertTrue(
            r.message.contains("could not be recorded"),
            "the refusal must say the observation was lost, or the next run repeats it blind. Got: \(r.message)")
        XCTAssertNotEqual(r.message, "target is a mount point", "the plain refusal would hide the lost record")
    }

    /// A store that cannot be reached at all is not "never seen". Absence of the store is (nothing
    /// has ever been recorded, so nothing can say stop); a non-directory in its path is not.
    func testAnUnreachableStoreRefusesRatherThanReadingAsNeverSeen() throws {
        try seedOneFile()
        FileManager.default.createFile(
            atPath: base.appendingPathComponent("Library/Application Support/XCodeVault").path, contents: Data([0]))

        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("could not read what was previously observed"), r.message)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    // MARK: the walk that reaches the record

    /// The ancestor check the reviewer asked for. A store component anyone can write is a record
    /// anyone can set to `wasPlainDirectory`, which switches the whole guard off silently.
    func testAStoreComponentWritableByAnyoneElseIsRefused() throws {
        try seedOneFile()
        try FileManager.default.createDirectory(
            atPath: base.appendingPathComponent("Library/Application Support/XCodeVault").path,
            withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o777)])

        guard case .failure(let f) = HelperMountHistory.openDirectory(under: base.path, creating: true) else {
            return XCTFail("a group/other-writable store component must be refused, not adopted")
        }
        XCTAssertTrue(f.reason.contains("writable by group or other"), f.reason)

        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok, "and the verb must refuse rather than clean on a record anyone can rewrite")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    /// A symlink at a store component sends root's write wherever it points. `O_NOFOLLOW` at every
    /// step is what stops that; the first version used `FileManager`, which follows.
    func testASymlinkedStoreComponentIsRefused() throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("Library/Application Support/XCodeVault"), withDestinationURL: elsewhere)

        guard case .failure = HelperMountHistory.openDirectory(under: base.path, creating: true) else {
            return XCTFail("a symlinked store component must be refused; root's write would land wherever it points")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [],
            "and nothing may have been created through it")
    }

    // MARK: the record's own safety

    /// The filename comes from a closed enum no client can extend, and is still validated on bytes
    /// — the same discipline `doCreateVaultDirectory` applies to its compile-time-constant name.
    func testEveryCleanupTargetProducesASafeRecordName() {
        for t in HelperCleanupTarget.allCases {
            let name = HelperMountHistory.fileName(for: t)
            XCTAssertNotNil(name, "\(t.rawValue) has no usable record name")
            guard let name else { continue }
            let bytes = Array(name.utf8)
            XCTAssertFalse(bytes.contains(0x2F), "\(name) contains a path separator")
            XCTAssertFalse(bytes.contains(0x00), "\(name) contains a NUL")
            XCTAssertNotEqual(name, "..")
            XCTAssertNotEqual(name, ".")
        }
    }

    /// The record must be root-only. One an unprivileged user can edit is one that can be made to
    /// say "never mounted" about a path that was.
    func testTheRecordIsWrittenRootOnly() throws {
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: target, under: base.path))
        var st = stat()
        XCTAssertEqual(lstat(HelperMountHistory.directory(under: base.path), &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "the record directory must not be readable by anyone but its owner")
        XCTAssertEqual(lstat(HelperMountHistory.directory(under: base.path) + "/" + target.rawValue, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "nor the record itself")
    }

    // MARK: lifting the refusal (issue #24 review — the record is sticky by design)

    /// The defect this addresses: nothing expired the record and nothing cleared it, so a user whose
    /// vault volume was gone for good could never clean that cache again — following a remediation
    /// message that pointed at `doctor`, which has no code that touches this.
    func testForgettingLiftsTheRefusalAndTheTargetIsCleanableAgain() throws {
        try seedOneFile()
        XCTAssertFalse(clean(mountAnswer: .isMountPoint).ok)
        XCTAssertFalse(clean(mountAnswer: .isNotMountPoint).ok, "precondition: the refusal is in force")

        let forgotten = service().doForgetMountObservation(target: target.rawValue, under: base.path)
        XCTAssertTrue(forgotten.ok, forgotten.message)
        XCTAssertTrue(forgotten.message.contains("forgot what was previously observed"), forgotten.message)
        XCTAssertEqual(HelperMountHistory.read(target: target, under: base.path), .none)

        let after = clean(mountAnswer: .isNotMountPoint)
        XCTAssertTrue(after.ok, "the refusal must actually be lifted, not merely reported as lifted: \(after.message)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "and the target is an ordinary cache again")
    }

    /// Forgetting nothing and forgetting something are different facts about the machine. Reporting
    /// both as a cheerful success would let a user believe they had lifted a block they had not.
    func testForgettingWhenNothingWasRecordedSaysSoRatherThanClaimingAChange() {
        let r = service().doForgetMountObservation(target: target.rawValue, under: base.path)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("nothing was recorded"), r.message)
        XCTAssertFalse(r.message.contains("forgot what was previously observed"), r.message)
    }

    /// It clears one target, not the store. A user lifting a refusal on the dyld cache must not
    /// silently lift it on every other allowlisted path too.
    func testForgettingIsScopedToOneTarget() throws {
        let other = HelperCleanupTarget.cryptexCaches
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: target, under: base.path))
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: other, under: base.path))

        XCTAssertTrue(service().doForgetMountObservation(target: target.rawValue, under: base.path).ok)
        XCTAssertEqual(HelperMountHistory.read(target: target, under: base.path), .none)
        XCTAssertEqual(
            HelperMountHistory.read(target: other, under: base.path), .observed(.wasMountPoint),
            "forgetting one target may not clear another's record")
    }

    /// It re-enables a root deletion, so it is gated like every other state-changing verb rather
    /// than treated as harmless because it only unlinks a small file.
    func testForgettingIsRefusedForANonAdministrator() throws {
        try seedOneFile()
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: target, under: base.path))

        // A uid that is not in the admin group. 99 is `nobody` on macOS.
        let r = HelperService(callerUID: 99, callerGID: 99).doForgetMountObservation(target: target.rawValue, under: base.path)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, HelperService.unauthorizedMessage)
        XCTAssertEqual(
            HelperMountHistory.read(target: target, under: base.path), .observed(.wasMountPoint),
            "and the record must survive the refused call")
    }

    func testForgettingRejectsATargetThatIsNotAllowlisted() {
        let r = service().doForgetMountObservation(target: "../../etc/passwd", under: base.path)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, "unknown target")
    }

    /// An unreachable store is not "nothing to forget". Reporting success there would tell a user a
    /// refusal had been lifted while it is still in force.
    func testForgettingReportsAStoreItCannotReach() throws {
        try FileManager.default.createDirectory(
            atPath: base.appendingPathComponent("Library/Application Support/XCodeVault").path,
            withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o777)])
        let r = service().doForgetMountObservation(target: target.rawValue, under: base.path)
        XCTAssertFalse(r.ok, "a store the guarded walk rejects may still hold a record saying stop")
        XCTAssertTrue(r.message.contains("could not forget"), r.message)
    }

    // MARK: absence is structural, not a string

    /// The regression this pins cost nine tests. `read` decided "the store is absent, proceed" by
    /// matching the suffix `"does not exist"` — the wording of its *own* message for a missing owned
    /// component. A missing **anchor** comes out of `openat` as `strerror(ENOENT)`, "No such file or
    /// directory", which did not match, so the answer flipped to `.unreadable` and the cleanup verb
    /// refused permanently on any machine without `/Library/Application Support`.
    ///
    /// Two different message producers, one string comparison deciding a safety answer between them.
    func testAMissingAnchorReadsAsNeverSeenRatherThanUnreadable() throws {
        let bare = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: bare, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o755)])
        defer { try? FileManager.default.removeItem(at: bare) }

        guard case .failure(let f) = HelperMountHistory.openDirectory(under: bare.path, creating: false) else {
            return XCTFail("a missing anchor cannot open")
        }
        XCTAssertTrue(f.isAbsence, "absence must be carried structurally, not inferred from \(f.reason)")
        XCTAssertFalse(
            f.reason.hasSuffix("does not exist"),
            "and this is the point: the anchor's message does NOT end that way, which is how the string comparison failed")

        XCTAssertEqual(
            HelperMountHistory.read(target: target, under: bare.path), .none,
            "nothing has ever been recorded, so nothing can be saying stop")
        XCTAssertEqual(
            HelperMountHistory.forget(target: target, under: bare.path), .success(false),
            "and forgetting an absent store is 'nothing to forget', not a failure")
    }

    /// The staging a reviewer used to defeat the absence flag. Mode `0400` on a store component
    /// passes every guard the walk applies — there are no `w` bits to fail on, and the owner is
    /// right — and then the **next** component's `fstatat` returns `EACCES`, not `ENOENT`.
    ///
    /// The first version set `isAbsence: true` for any `fstatat` failure, so the store answered
    /// "nothing was ever recorded here", `.none` means proceed, and the verb deleted the shadow half
    /// while the record on disk said `wasMountPoint`. `0o000` (covered above) fails at the `openat`
    /// instead, so it passed against the broken code — this is the mode that separates them.
    func testAStoreComponentThatCannotBeTraversedIsNotReadAsNeverSeen() throws {
        try seedOneFile()
        XCTAssertTrue(HelperMountHistory.write(.wasMountPoint, target: target, under: base.path))
        let component = base.appendingPathComponent("Library/Application Support/XCodeVault").path
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o400)], ofItemAtPath: component)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: component) }

        // Precondition: this environment really does deny traversal. As root it would not fail the
        // assertions below, it would make them vacuous.
        var st = stat()
        try XCTSkipIf(
            stat(HelperMountHistory.directory(under: base.path), &st) == 0,
            "this environment can traverse a 0o400 directory (running as root?), so the branch is unreachable here")

        guard case .unreadable = HelperMountHistory.read(target: target, under: base.path) else {
            return XCTFail("an EACCES while walking to the store must be `.unreadable` — `.none` means 'proceed and delete'")
        }
        let r = clean(mountAnswer: .isNotMountPoint)
        XCTAssertFalse(r.ok, "the record on disk says wasMountPoint; this is the split-brain deletion")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("cache-entry").path),
            "nothing may be removed")
    }

    /// The case that let the `ENOTDIR` defect survive a review that was looking for it. Every
    /// existing symlink test stages its link at `XCodeVault` — an *owned* component, handled by code
    /// that never sets the absence flag. Only a symlink at the **anchor** (`Library` or
    /// `Application Support`) reaches `openGuardedDirectory`'s own absence site.
    ///
    /// Darwin returns `ENOTDIR`, not `ELOOP`, when `O_DIRECTORY` and `O_NOFOLLOW` meet a symlink —
    /// so classifying `ENOTDIR` as absence made a symlinked ancestor read as "never recorded,
    /// proceed and delete".
    func testASymlinkedAnchorComponentIsRefusedRatherThanReadAsNeverSeen() throws {
        let bare = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let real = bare.appendingPathComponent("real-support")
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o755)])
        try FileManager.default.createDirectory(
            at: bare.appendingPathComponent("Library"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)])
        defer { try? FileManager.default.removeItem(at: bare) }
        // A symlink exactly where the trust anchor's last component must be.
        try FileManager.default.createSymbolicLink(
            at: bare.appendingPathComponent("Library/Application Support"), withDestinationURL: real)

        guard case .failure(let f) = HelperMountHistory.openDirectory(under: bare.path, creating: false) else {
            return XCTFail("a symlinked anchor must not open")
        }
        XCTAssertFalse(
            f.isAbsence,
            "a symlink is not an absence — it is a redirection, and calling it absence means 'proceed and delete'. Got: \(f.reason)")

        guard case .unreadable = HelperMountHistory.read(target: target, under: bare.path) else {
            return XCTFail("the read must refuse; `.none` would mean 'nothing was ever recorded here'")
        }
        // And the forget verb, which has no second check masking the answer.
        let r = HelperService(callerUID: getuid(), callerGID: getgid())
            .doForgetMountObservation(target: target.rawValue, under: bare.path)
        XCTAssertFalse(
            r.ok, "reporting 'nothing was recorded' for a store it could not reach is a false statement about the machine. Got: \(r.message)")
    }

    /// The writer checks the type it opened, as the reader does. An asymmetry between the two
    /// readers of one file is the shape of the defect above.
    func testTheWriterRefusesANonRegularFileAtTheRecordName() throws {
        let dir = HelperMountHistory.directory(under: base.path)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.createDirectory(atPath: dir + "/" + target.rawValue, withIntermediateDirectories: true)

        XCTAssertFalse(
            HelperMountHistory.write(.wasMountPoint, target: target, under: base.path),
            "a directory at the record name is not a record this wrote, and must not be written through")
    }
}

