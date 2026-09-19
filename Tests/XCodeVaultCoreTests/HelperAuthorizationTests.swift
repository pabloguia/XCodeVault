import XCTest

@testable import XCodeVaultCore
@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// The authorization gate on the root daemon's three state-changing verbs.
///
/// These exist because the first version of `isAdministrator` shipped with a defect that no test
/// could reach: it lived in an executable target. The defect was a retry loop that could never run,
/// and its effect was to deny every administrator with more than 64 group memberships. That is the
/// whole argument for `XCodeVaultHelperCore` being a library.
final class HelperAuthorizationTests: XCTestCase {
    private let adminGID: Int32 = 80

    private func decide(
        uid: uid_t, name: String = "someone", primaryGID: Int32 = 20, memberships: [Int32]? = [20],
        admin: Int32? = 80
    ) -> Bool {
        HelperService.isAdministrator(
            uid: uid,
            passwd: { _ in (name: name, gid: primaryGID) },
            adminGroup: { admin },
            groups: { _, _ in memberships })
    }

    func testAnAdminByGroupMembershipIsAllowed() {
        XCTAssertTrue(decide(uid: 501, memberships: [20, 12, 80, 701]))
    }

    func testAnAdminByPrimaryGroupIsAllowed() {
        XCTAssertTrue(decide(uid: 501, primaryGID: adminGID, memberships: []))
    }

    func testAnOrdinaryUserIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: [20, 12, 701]))
    }

    /// The whole point of the gate: a signed client satisfying the code-signing requirement is not
    /// an authorization, and a service account driving it must not reach a verb that deletes as root.
    func testAServiceAccountIsRefused() {
        XCTAssertFalse(decide(uid: 200, primaryGID: 200, memberships: [200]))
    }

    func testRootIsAllowedWithoutConsultingTheDirectory() {
        // Fails the lookups deliberately: root must not depend on them.
        XCTAssertTrue(
            HelperService.isAdministrator(uid: 0, passwd: { _ in nil }, adminGroup: { nil }, groups: { _, _ in nil }))
    }

    // MARK: fails closed

    func testAnUnresolvableAccountIsRefused() {
        XCTAssertFalse(
            HelperService.isAdministrator(uid: 501, passwd: { _ in nil }, adminGroup: { self.adminGID }, groups: { _, _ in [80] }))
    }

    func testAnUnresolvableAdminGroupIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: [80], admin: nil))
    }

    /// "I could not read the group list" must not be reachable from "allowed". This is the path the
    /// real `groupList` takes when it gives up, and it is the one a directory outage produces.
    func testAnUnreadableGroupListIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: nil))
    }

    // MARK: the real lookups, against this machine

    /// `getgrouplist` on Darwin sets `*ngroups` to the *truncated* count on overflow, not the needed
    /// size — the opposite of the contract the first implementation assumed. This pins the observable
    /// consequence: the real lookup returns the account's full membership rather than giving up.
    func testTheRealGroupListReturnsTheFullMembership() throws {
        let uid = getuid()
        let pw = try XCTUnwrap(HelperService.passwdLookup(uid))
        let groups = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid), "could not read this account's groups")
        XCTAssertFalse(groups.isEmpty)
        // `id -G` is the same question asked of the system.
        let expected = Set(Self.idG())
        XCTAssertFalse(expected.isEmpty, "could not read `id -G`")
        XCTAssertTrue(expected.isSubset(of: Set(groups)), "groupList returned fewer groups than `id -G`: \(groups) vs \(expected)")
    }

    /// And the decision itself, end to end on this machine, checked against `id -Gn`.
    func testTheRealDecisionAgreesWithTheSystem() throws {
        let uid = getuid()
        guard let admin = HelperService.adminGroupID() else { throw XCTSkip("no admin group on this machine") }
        let inAdmin = Set(Self.idG()).contains(admin)
        XCTAssertEqual(HelperService.isAdministrator(uid: uid), inAdmin)
    }

    /// The growth path, driven on a machine that has far fewer than 64 groups — which is every
    /// machine, and every CI runner. Without this seam the retry is never executed, and "a retry
    /// that can never run" is precisely the defect this function was rewritten to fix. A test that
    /// only ever exercises the first iteration would not have caught it either.
    func testTheGroupListRetryActuallyRuns() throws {
        let uid = getuid()
        let pw = try XCTUnwrap(HelperService.passwdLookup(uid))
        let full = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid))
        XCTAssertGreaterThan(full.count, 1, "this account has too few groups for the test to mean anything")
        // seedCapacity 1 guarantees at least one overflow-and-grow cycle.
        let viaRetry = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid, seedCapacity: 1), "the retry gave up")
        XCTAssertEqual(viaRetry, full)
    }

    private static func idG() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        p.arguments = ["-G"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
}

/// Tests for the privileged verbs themselves, not only the gate in front of them.
///
/// `XCodeVaultHelperCore` exists — by its own file header, by `Package.swift` and by ADR-0006 —
/// "so the verbs, the authorization gate and the path guards can be tested". Until 2026-09-18 the
/// gate was tested and the verbs were `private`, so `@testable import` could not reach them: the
/// refactor moved the code into a testable target and then sealed it. A helper-security review
/// confirmed the consequence by mutation — replacing the ownership guard with `true` passed every
/// gate the project has.
///
/// These run as an ordinary user over a temporary tree. `requiredOwner` is a parameter on the walk
/// for exactly that reason; the rule under test is the rule that runs in production, only the
/// identity it demands is supplied.
final class HelperPrivilegedVerbTests: XCTestCase {

    private func tempDir(_ name: String, mode: mode_t = 0o755) throws -> String {
        let p = NSTemporaryDirectory() + "xcv-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        // Resolve through /var -> private/var before handing it to a walk that refuses symlinks.
        let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: resolved)
        return resolved
    }

    // MARK: - The ownership decision (issue #6, and the race in #5)

    /// The truth table, exhaustively. Mutating the implementation to `true` — the mutation a
    /// reviewer showed passes every other gate — fails four of these five rows.
    func testOwnershipDecisionTruthTable() {
        let caller: uid_t = 501
        // Created by this call and owned by root: the ordinary case.
        XCTAssertTrue(HelperService.mayTakeOwnership(created: true, directoryUID: 0, callerUID: caller))
        // Already existed and already belongs to the caller: idempotent re-registration.
        XCTAssertTrue(HelperService.mayTakeOwnership(created: false, directoryUID: caller, callerUID: caller))
        // Already existed and belongs to someone else: this is the escalation. Root must not
        // perform an ownership change the caller could never perform itself.
        XCTAssertFalse(HelperService.mayTakeOwnership(created: false, directoryUID: 502, callerUID: caller))
        // Already existed and is root-owned, but this call did not create it.
        XCTAssertFalse(HelperService.mayTakeOwnership(created: false, directoryUID: 0, callerUID: caller))
        // THE RACE (#5): mkdir returned, then something was renamed into the path before open.
        // `created` is true but the directory is not the one this call made, so it is not root's.
        XCTAssertFalse(HelperService.mayTakeOwnership(created: true, directoryUID: 502, callerUID: caller))
    }

    // MARK: - The guarded walk (issue #1)

    func testTheWalkAcceptsATreeThatMeetsEveryRequirement() throws {
        let root = try tempDir("walk-ok")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let leaf = root + "/a/b"
        try FileManager.default.createDirectory(atPath: leaf, withIntermediateDirectories: true)
        for p in [root + "/a", leaf] { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: p) }

        switch HelperService.openGuardedDirectory(leaf, under: root, requiredOwner: getuid()) {
        case .success(let fd): close(fd)
        case .failure(let f): XCTFail("a root:0755-shaped tree must be accepted, refused '\(f.component)': \(f.reason)")
        }
    }

    /// The gap this closes: the verb used to check the FINAL component only. An intermediate that
    /// anyone can write to lets an unprivileged user plant entries root then deletes.
    func testAGroupWritableINTERMEDIATEComponentIsRefused() throws {
        let root = try tempDir("walk-mid")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mid = root + "/loose", leaf = mid + "/leaf"
        try FileManager.default.createDirectory(atPath: leaf, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o775)], ofItemAtPath: mid)

        switch HelperService.openGuardedDirectory(leaf, under: root, requiredOwner: getuid()) {
        case .success(let fd): close(fd); XCTFail("a group-writable intermediate component must be refused")
        case .failure(let f): XCTAssertEqual(f.component, "loose", "the refusal must name the component that failed")
        }
    }

    /// The other half of the same gap: owner was checked, mode was not.
    func testAWorldWritableFINALComponentIsRefused() throws {
        let root = try tempDir("walk-final")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let leaf = root + "/leaf"
        try FileManager.default.createDirectory(atPath: leaf, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o757)], ofItemAtPath: leaf)

        switch HelperService.openGuardedDirectory(leaf, under: root, requiredOwner: getuid()) {
        case .success(let fd): close(fd); XCTFail("a world-writable target must be refused even when root-owned")
        case .failure(let f): XCTAssertEqual(f.component, "leaf")
        }
    }

    /// O_NOFOLLOW at every level is what makes this a walk rather than a path resolution.
    func testASymlinkedComponentIsRefusedRatherThanFollowed() throws {
        let root = try tempDir("walk-link")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = root + "/real"
        try FileManager.default.createDirectory(atPath: real + "/leaf", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: real)

        switch HelperService.openGuardedDirectory(root + "/link/leaf", under: root, requiredOwner: getuid()) {
        case .success(let fd): close(fd); XCTFail("a symlinked component must fail the open, not be followed")
        case .failure(let f): XCTAssertEqual(f.component, "link")
        }
    }

    func testAComponentOwnedBySomeoneElseIsRefused() throws {
        let root = try tempDir("walk-owner")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Requiring root over a tree this user owns is the same refusal, staged without needing root.
        switch HelperService.openGuardedDirectory(root, under: root, requiredOwner: 0) {
        case .success(let fd): close(fd); XCTFail("a user-owned tree must be refused when root ownership is required")
        case .failure(let f): XCTAssertTrue(f.reason.contains("owned by uid"), "got: \(f.reason)")
        }
    }

    func testRelativeComponentsAreRefusedBecauseNOFOLLOWDoesNotConstrainThem() throws {
        let root = try tempDir("walk-dotdot")
        defer { try? FileManager.default.removeItem(atPath: root) }
        switch HelperService.openGuardedDirectory(root + "/../..", under: root, requiredOwner: getuid()) {
        case .success(let fd): close(fd); XCTFail("'..' must be refused; it climbs back out of an approved component")
        case .failure(let f): XCTAssertEqual(f.component, "..")
        }
    }

    // MARK: - Mount status is three-valued (issue #2)

    /// The defect: one value meant both "not a mount point" and "could not tell", and the cleanup
    /// path read both as permission to proceed.
    func testMountStatusSeparatesNotAMountPointFromCouldNotTell() throws {
        let root = try tempDir("mount")
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(HelperService.mountStatus(root), .isNotMountPoint)
        XCTAssertEqual(
            HelperService.mountStatus(root + "/does-not-exist"), .undetermined,
            "a path the attribute cannot be read for is undetermined, never 'not a mount point'")
        XCTAssertEqual(HelperService.mountStatus("/"), .isMountPoint)
    }

    /// `isMountPoint` still exists for the byte accounting, where a wrong answer costs a wrong
    /// number rather than a wrong deletion. Pin that it collapses `.undetermined` to false, so the
    /// reason it must not appear in a guard stays visible.
    func testIsMountPointCollapsesUndeterminedToFalseWhichIsWhyGuardsMustNotUseIt() throws {
        let root = try tempDir("mount-collapse")
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertFalse(HelperService.isMountPoint(root + "/does-not-exist"))
        XCTAssertEqual(HelperService.mountStatus(root + "/does-not-exist"), .undetermined)
    }

    // MARK: - The VERB, not just its parts (issues #1, #2, #6)

    /// Everything above is a unit test of a guard. These call the verb.
    ///
    /// That distinction is the whole finding of two independent reviews of the first draft of this
    /// change: the primitives were tested and the *call sites* were not, so both original defects
    /// could be reintroduced verbatim with the suite still green. A reviewer demonstrated it —
    /// replacing the verb's whole `mountStatus` switch with `_ = Self.mountStatus(dir)`, which is
    /// the fail-open of issue #2 restored exactly, passed 23/23; replacing the guarded walk with a
    /// bare `open(dir, O_RDONLY|O_DIRECTORY)`, which is issue #1 restored exactly, also passed
    /// 23/23. Tests below exist to make both of those fail.
    ///
    /// `under:` is the seam. It injects the trust anchor only: the target is still chosen from
    /// `HelperCleanupTarget` and still cannot come from a client, and the required owner is
    /// derived from whoever owns the anchor, so a test owns its own tree while production keeps
    /// demanding root.
    private func cleanupFixture(_ label: String, mode: mode_t = 0o755) throws -> (base: String, target: String) {
        let base = try tempDir(label, mode: mode)
        let target = base + "/Library/Developer/CoreSimulator/Caches/dyld"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        // `/Library/Application Support` exists on every Mac, and the verb now writes its mount
        // history under it (issue #24). A fixture without it is not a machine the verb will ever
        // meet, and leaving it out made these tests assert against a state production cannot reach.
        // The store is not created here on purpose: the anchor must pre-exist and be trustworthy,
        // and everything below it is the daemon's to create.
        try FileManager.default.createDirectory(
            atPath: base + "/Library/Application Support", withIntermediateDirectories: true)
        // The walk requires every component from the anchor down, so fix the whole chain.
        for p in [
            "/Library", "/Library/Application Support", "/Library/Developer", "/Library/Developer/CoreSimulator",
            "/Library/Developer/CoreSimulator/Caches", "/Library/Developer/CoreSimulator/Caches/dyld",
        ] {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: base + p)
        }
        return (base, target)
    }

    private func service() -> HelperService { HelperService(callerUID: getuid(), callerGID: getgid()) }

    func testTheVerbDeletesTheContentsAndNotTheDirectory() throws {
        let (base, target) = try cleanupFixture("verb-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: target + "/a.bin", contents: Data(repeating: 0xAB, count: 4096))
        try FileManager.default.createDirectory(atPath: target + "/nested/deeper", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target + "/nested/deeper/b.bin", contents: Data(repeating: 0xCD, count: 2048))

        let r = service().doRemoveRegenerableSystemDirectoryContents(target: "coreSimulatorDyldCache", under: base)

        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target), "the directory itself must survive; CoreSimulator recreates caches in place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target), [], "every child must be gone, including nested ones")
        XCTAssertGreaterThan(r.bytesFreed, 0, "bytes actually freed must be reported")
    }

    /// Kills the reviewer's M2: replacing the guarded walk with a bare `open` must fail here.
    func testTheVerbRefusesWhenAComponentOfTheChainIsGroupWritable() throws {
        let (base, target) = try cleanupFixture("verb-walk")
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: target + "/keep.bin", contents: Data(repeating: 0x01, count: 512))
        // An intermediate component, not the target: the old code only ever checked the last one.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o775)], ofItemAtPath: base + "/Library/Developer/CoreSimulator")

        let r = service().doRemoveRegenerableSystemDirectoryContents(target: "coreSimulatorDyldCache", under: base)

        XCTAssertFalse(r.ok, "a group-writable intermediate component must stop the verb")
        XCTAssertTrue(r.message.contains("CoreSimulator"), "the refusal must name the component that failed: \(r.message)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target + "/keep.bin"),
            "nothing may be deleted once the walk has refused")
    }

    /// Kills the reviewer's M1 — the mutation that replaced this verb's whole `mountStatus`
    /// switch with `_ = Self.mountStatus(dir)`, restoring issue #2's fail-open verbatim, and
    /// still passed 23/23.
    ///
    /// Both refusing answers are driven through the injected query, because neither is stageable
    /// for real in a unit test: an open descriptor keeps answering after its directory is
    /// unlinked (measured — it returns `.isNotMountPoint`, not `.undetermined`), and a genuine
    /// mount point needs a volume.
    func testTheVerbRefusesOnBothNonAnswersFromTheMountQuery() throws {
        for (answer, expected) in [
            (HelperService.MountAnswer.isMountPoint, "is a mount point"),
            (HelperService.MountAnswer.undetermined, "could not determine"),
        ] {
            let (base, target) = try cleanupFixture("verb-mount-\(expected.prefix(3))")
            defer { try? FileManager.default.removeItem(atPath: base) }
            FileManager.default.createFile(atPath: target + "/keep.bin", contents: Data(repeating: 0x02, count: 256))

            let r = service().doRemoveRegenerableSystemDirectoryContents(
                target: "coreSimulatorDyldCache", under: base, mount: { _ in answer })

            XCTAssertFalse(r.ok, "\(answer) must stop the verb")
            XCTAssertTrue(r.message.contains(expected), "unexpected message: \(r.message)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target + "/keep.bin"),
                "nothing may be deleted once the mount check has refused (\(answer))")
        }
    }

    /// The other half: a definite "not a mount point" must let the verb proceed, so the test
    /// above is pinning the refusal and not merely the injection.
    func testTheVerbProceedsWhenTheMountQueryIsDefinitelyNegative() throws {
        let (base, target) = try cleanupFixture("verb-mount-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: target + "/gone.bin", contents: Data(repeating: 0x03, count: 256))
        let r = service().doRemoveRegenerableSystemDirectoryContents(
            target: "coreSimulatorDyldCache", under: base, mount: { _ in .isNotMountPoint })
        XCTAssertTrue(r.ok, r.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/gone.bin"))
    }

    /// The real query, on a live descriptor, answers rather than guessing.
    func testTheDescriptorMountQueryAnswersForARealDirectory() throws {
        let root = try tempDir("fd-mount")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(HelperService.mountStatus(ofDescriptor: fd), .isNotMountPoint)
        let rootFD = open("/", O_RDONLY | O_DIRECTORY)
        defer { close(rootFD) }
        XCTAssertEqual(HelperService.mountStatus(ofDescriptor: rootFD), .isMountPoint)
    }

    /// The walk's result must be acted on through the descriptor, not by rebuilding the path.
    /// A child on a different device is a grafted mount; `removeItem`'s `REMOVEFILE_RECURSIVE`
    /// would descend into it, and this must not.
    func testTheVerbCountsOnlyWhatItActuallyDeleted() throws {
        let (base, target) = try cleanupFixture("verb-bytes")
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: target + "/x.bin", contents: Data(repeating: 0x7F, count: 8192))
        let r = service().doRemoveRegenerableSystemDirectoryContents(target: "coreSimulatorDyldCache", under: base)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertGreaterThanOrEqual(r.bytesFreed, 8192, "an 8 KiB file must be accounted for")
    }

    /// A symlinked child is refused rather than followed, and refusing counts as a failure so the
    /// verb cannot report a clean sweep it did not perform.
    func testASymlinkedChildIsRefusedAndReportedRatherThanFollowed() throws {
        let (base, target) = try cleanupFixture("verb-symlink")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside + "/precious", contents: Data("keep me".utf8))
        try FileManager.default.createSymbolicLink(atPath: target + "/link", withDestinationPath: outside)

        let r = service().doRemoveRegenerableSystemDirectoryContents(target: "coreSimulatorDyldCache", under: base)

        XCTAssertFalse(r.ok, "a symlinked child must be reported, not silently skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/precious"), "nothing may be deleted through a symlink")
    }

    /// Absence is "nothing to do"; an unknown target is refused before any filesystem access.
    func testAbsenceIsNothingToDoAndAnUnknownTargetIsRefused() throws {
        let base = try tempDir("verb-absent")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let absent = service().doRemoveRegenerableSystemDirectoryContents(target: "coreSimulatorDyldCache", under: base)
        XCTAssertTrue(absent.ok)
        XCTAssertEqual(absent.message, "nothing to do")
        XCTAssertEqual(absent.bytesFreed, 0)

        let unknown = service().doRemoveRegenerableSystemDirectoryContents(target: "not-a-target", under: base)
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.message, "unknown target")
    }

    /// A raw 0x2F byte hidden inside what Swift counts as one Character.
    ///
    /// `split(separator: "/")` compares graphemes. `"/" + U+0301` is one extended grapheme
    /// cluster and is not equal to `"/"`, so a grapheme split leaves the segment intact — and
    /// `contains("/")` on it is *false*, so a grapheme-level rejection misses it too. The kernel
    /// splits on the byte regardless. Handed whole to `openat`, `O_NOFOLLOW` would then constrain
    /// only the part after the embedded slash, and everything before it would resolve through
    /// symlinks unchecked.
    ///
    /// The tree here makes that concrete: `a` is a symlink. Under grapheme splitting the walk
    /// opens `"a/\u{0301}b"` in one call and follows `a`; splitting on the byte makes `a` a
    /// component in its own right, where `O_NOFOLLOW` refuses it.
    func testASlashByteHiddenInsideOneCharacterCannotSmuggleAComponentPastNOFOLLOW() throws {
        let root = try tempDir("slash-byte")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let elsewhere = root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere + "/\u{0301}b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/a", withDestinationPath: elsewhere)

        let segment = "a\u{2F}\u{0301}b"
        XCTAssertFalse(segment.contains("/"), "precondition: a grapheme-level check cannot see this slash")
        XCTAssertTrue(Array(segment.utf8).contains(0x2F), "precondition: the byte is really there")

        switch HelperService.openGuardedDirectory(root + "/" + segment, under: root, requiredOwner: getuid()) {
        case .success(let fd):
            close(fd)
            XCTFail("the walk followed a symlink it should have refused: the slash byte was not split")
        case .failure(let f):
            // Split on the byte, `a` is its own component and O_NOFOLLOW refuses the symlink.
            XCTAssertEqual(f.component, "a", "the refusal must land on the symlinked component, not the whole segment")
        }
    }

    // MARK: - Guards a second review found surviving mutation

    /// The whole stated defence for removing `requiredOwner` from the verb is "production's
    /// anchor is `/`, so the derived owner is root". A review pointed out that nothing failed if
    /// that refusal was deleted, which made the defence an assertion rather than a control.
    func testAnchoringAtRootWhileDemandingANonRootOwnerIsRefused() {
        switch HelperService.openGuardedDirectory("/Library", under: "/", requiredOwner: 501) {
        case .success(let fd):
            close(fd)
            XCTFail("walking from / while demanding a non-root owner must be refused outright")
        case .failure(let f):
            XCTAssertEqual(f.component, "/")
            XCTAssertTrue(f.reason.contains("not 0"), "unexpected reason: \(f.reason)")
        }
    }

    /// A path outside the trust anchor must be refused before anything is opened.
    func testAPathOutsideTheTrustAnchorIsRefused() throws {
        let root = try tempDir("anchor")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A sibling whose name merely starts the same must not be mistaken for a child.
        for outside in ["/etc", root + "-sibling/x"] {
            switch HelperService.openGuardedDirectory(outside, under: root, requiredOwner: getuid()) {
            case .success(let fd): close(fd); XCTFail("\(outside) is not under \(root)")
            case .failure(let f): XCTAssertTrue(f.reason.contains("trust anchor"), "unexpected: \(f.reason)")
            }
        }
    }

    /// The recursion is depth-limited. Without the limit a deep or cyclic tree exhausts
    /// descriptors instead of reporting a failure.
    func testTheRecursionStopsAtItsDepthLimitAndReportsIt() throws {
        let root = try tempDir("depth")
        defer { try? FileManager.default.removeItem(atPath: root) }
        var p = root
        for i in 0..<70 { p += "/d\(i)" }
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let outcome = HelperService.removeContents(of: fd)
        XCTAssertGreaterThan(outcome.failures, 0, "exceeding the depth limit must be reported, not ignored")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/d0"), "the tree must not be half-eaten silently")
    }

    /// Bytes are counted only after the unlink succeeds. Staged with a `uchg`-flagged file, which
    /// its owner can set and then cannot unlink — so one child fails while another succeeds.
    ///
    /// The test that was supposed to cover this (`testTheVerbCountsOnlyWhatItActuallyDeleted`)
    /// could not: every unlink in it succeeds, so counting before and counting after give the
    /// same answer. A review caught that.
    func testBytesAreNotCountedForAChildThatFailedToUnlink() throws {
        let root = try tempDir("bytes-fail")
        let locked = root + "/locked.bin"
        FileManager.default.createFile(atPath: locked, contents: Data(repeating: 0xEE, count: 65536))
        FileManager.default.createFile(atPath: root + "/free.bin", contents: Data(repeating: 0xDD, count: 4096))
        XCTAssertEqual(chflags(locked, UInt32(UF_IMMUTABLE)), 0, "could not stage an unlinkable file")
        defer {
            chflags(locked, 0)
            try? FileManager.default.removeItem(atPath: root)
        }

        let fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let outcome = HelperService.removeContents(of: fd)

        XCTAssertGreaterThan(outcome.failures, 0, "the immutable file must be reported as a failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked), "it must still be there")
        XCTAssertLessThan(
            outcome.freed, 65536,
            "a file that could not be unlinked must not be counted as freed (got \(outcome.freed))")
        XCTAssertGreaterThan(outcome.freed, 0, "the file that WAS deleted must still be counted")
    }

    /// A subdirectory that cannot be opened must be a failure, not a silent skip. Staged with
    /// `chmod 000`, which needs no root and no race — so unlike the guards labelled UNPINNED in
    /// the source, this one had no excuse for being untested.
    func testAnUnopenableSubdirectoryIsReportedRatherThanSkipped() throws {
        let root = try tempDir("unopenable")
        let locked = root + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked + "/inside.bin", contents: Data(repeating: 0x11, count: 1024))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: root)
        }

        let fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let outcome = HelperService.removeContents(of: fd)

        XCTAssertGreaterThan(outcome.failures, 0, "an unopenable subtree must be reported, never skipped as if cleaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked), "it must still be there")
    }

    /// A structural gate, not a behavioural test.
    ///
    /// Issue #24 is that after a disconnect the cleanup verb deletes the shadow half of a split
    /// brain and reports routine cleanup. The verb cannot detect that, and the state it would
    /// need does not exist yet. What can be prevented today is the precondition: a path must
    /// never be both a cleanup target and somewhere a strategy may mount. This fails the build
    /// if that ever becomes true, so #24 is discovered here rather than by a user.
    func testNoCleanupTargetIsAlsoSomewhereAStrategyMayMount() {
        let mountable =
            StorageCatalog.all
            .filter { $0.allowedStrategies.contains(.canonicalMount) || $0.isMountGraft }
            .flatMap(\.pathTemplates)
        XCTAssertFalse(mountable.isEmpty, "positive control: the catalog must actually name some mountable paths")

        for target in HelperCleanupTarget.allCases {
            for template in mountable {
                // Templates may carry placeholders; compare on the literal prefix before one.
                let path = template.split(separator: "{", maxSplits: 1).first.map(String.init) ?? template
                let fixed = path.hasSuffix("/") ? String(path.dropLast()) : path
                guard !fixed.isEmpty, fixed != "/" else { continue }
                XCTAssertFalse(
                    target.path == fixed || target.path.hasPrefix(fixed + "/") || fixed.hasPrefix(target.path + "/"),
                    "cleanup target \(target.path) overlaps mountable path \(fixed) — see issue #24")
            }
        }
    }
}
