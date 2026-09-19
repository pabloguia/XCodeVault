import XCTest

@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// `doCreateVaultDirectory`'s refusal paths, called through the verb itself.
///
/// **Why this file exists.** `docs/process/KNOWN-ISSUES-AT-PUBLICATION.md` recorded that the
/// `mayTakeOwnership` predicate had been extracted and exhausted while *nothing called the verb*,
/// so every call site inside it — the authorization gate included — was unpinned. That is the
/// finding the same document already states in its sharpest form: extracting and testing a guard
/// does not pin the site that consults it, and the first attempt at that change "left all three
/// call sites mutation-clean while looking thoroughly tested".
///
/// **What this reaches, and what it cannot.** The verb's own path needs a real volume mounted under
/// `/Volumes`, which a unit test cannot create without privilege this project refuses to take, so
/// the first group below covers the four refusals that precede the mount lookup.
///
/// Issue #28 then split the region beneath it into `claimDirectory`, which takes a parent
/// **descriptor** the caller has already verified rather than a path — so the second group drives
/// the ownership decision, the create/adopt branches and the `fchown` that had never executed under
/// a test. What remains out of reach is one arm: a directory *created by this call* is required to
/// be root-owned, which unprivileged it never is. That arm is asserted here as the refusal it
/// produces, and its success is exercised only by the E-series runbooks.
final class VaultDirectoryVerbTests: XCTestCase {

    /// The gate, at the call site rather than in isolation. A `doCreateVaultDirectory` that lost
    /// its `authorize()` line would leave `HelperAuditAndVolumeTests`' predicate coverage entirely
    /// green: that suite tests `mayTakeOwnership`, which this verb reaches only much later.
    func testTheVerbRefusesANonAdministratorBeforeAnythingElse() {
        let r = HelperService(callerUID: 99, callerGID: 99)
            .doCreateVaultDirectory(volumeUUID: UUID().uuidString)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(
            r.message, HelperService.unauthorizedMessage,
            "the gate must answer first — a well-formed UUID from an unauthorized caller must not reach the volume lookup")
    }

    /// The UUID is parsed, not pattern-matched, and it is the only thing the client supplies. A verb
    /// that accepted arbitrary text here would be one string-handling bug away from taking a path.
    func testTheVerbRejectsAnythingThatIsNotAUUID() {
        for bad in ["", "not-a-uuid", "/Volumes/VAULT", "../..", "123e4567-e89b-12d3-a456", String(repeating: "a", count: 4096)] {
            let r = service().doCreateVaultDirectory(volumeUUID: bad)
            XCTAssertFalse(r.ok, "accepted \(bad.prefix(40))")
            XCTAssertEqual(r.message, "invalid UUID", "for \(bad.prefix(40))")
        }
    }

    /// Root and the system accounts are refused: this verb hands the created directory to its
    /// caller, and the one caller it must never hand anything to is one that already has it.
    func testTheVerbRefusesASystemCaller() {
        let r = HelperService(callerUID: 0, callerGID: 0).doCreateVaultDirectory(volumeUUID: UUID().uuidString)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, "caller must be a regular user")
    }

    /// A syntactically perfect UUID that names no mounted volume stops here. The path is never
    /// constructed from anything the client said — it is resolved from the UUID by the helper — so
    /// "no such volume" is the only thing an unmatched UUID can produce.
    func testAWellFormedUUIDThatNamesNoMountedVolumeIsRefused() {
        // A v4 UUID with a fixed body: the odds of this naming a volume on the test machine are
        // nil, and fixing it keeps the test from passing for a different reason on a rerun.
        let r = service().doCreateVaultDirectory(volumeUUID: "F0F0F0F0-1111-4222-8333-444444444444")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, "volume not mounted")
    }

    /// The name the verb appends is a compile-time constant, and it is validated on bytes anyway.
    /// This asserts the constant itself is still the shape those checks assume — a future rename to
    /// something containing a separator would be caught by the verb at runtime, which is too late to
    /// be useful and too rare to be noticed.
    func testTheVaultDirectoryNameIsContainableByConstruction() {
        let bytes = Array(VaultDirectory.name.utf8)
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertFalse(bytes.contains(0x2F), "a separator would escape the approved mount point")
        XCTAssertFalse(bytes.contains(0x00), "a NUL truncates the C string and leaves the volume root")
        XCTAssertNotEqual(VaultDirectory.name, ".")
        XCTAssertNotEqual(VaultDirectory.name, "..", "`mp + \"/..\"` resolves to /Volumes, which fchown would hand to the caller")
    }

    private func service() -> HelperService { HelperService(callerUID: getuid(), callerGID: getgid()) }

    // MARK: the ownership decision (issue #28)

    /// Opens a directory the test owns and hands the descriptor over, which is how the region below
    /// the mount lookup becomes reachable at all. Nothing here needs `/Volumes` or privilege.
    private func withParentDirectory(_ body: (Int32, URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        // `guard`, not an assertion that then continues: with `fd == -1` every call below refuses
        // with EBADF, which reads as five confusing failures instead of one fixture problem.
        guard fd >= 0 else { return XCTFail("could not open the fixture's parent directory: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try body(fd, dir)
    }

    /// The create arm, and the guard that makes it root-only.
    ///
    /// When this call is the one that made the directory, `isTheObjectThisCallJustCreated` demands
    /// `linkCount == 2 && directoryUID == 0` — root made it, so root owns it, and it is still empty.
    /// Run unprivileged the new directory belongs to the test user, so the check correctly answers
    /// `.notWhatWeCreated` and nothing is chowned.
    ///
    /// **So this asserts the refusal rather than the success**, and that is the honest shape here:
    /// the success arm cannot be reached without root, and this suite must not skip — CI asserts a
    /// baseline of zero skipped tests, so a test that skips on every ordinary machine would fail the
    /// gate rather than document the gap. What can be proved without privilege is that a directory
    /// this call created but does **not** find root-owned is refused, which is the guard itself.
    func testACreatedDirectoryThatIsNotRootOwnedIsRefused() throws {
        try withParentDirectory { fd, dir in
            let r = service().claimDirectory(inParent: fd, named: "XCodeVault", reportedAs: dir.path + "/XCodeVault")
            XCTAssertFalse(r.ok, "unprivileged, the directory this call just made is not root-owned")
            XCTAssertTrue(r.message.contains("not the one this call just created"), r.message)

            var st = stat()
            XCTAssertEqual(lstat(dir.appendingPathComponent("XCodeVault").path, &st), 0, "it was still created — the refusal is about claiming it")
            XCTAssertEqual(st.st_uid, getuid(), "and nothing was chowned")
        }
    }

    /// **The call site issue #28 is about.** A directory that already exists and belongs to somebody
    /// other than the caller must not be taken over.
    ///
    /// Staged by lying about who is calling rather than by changing who owns the directory: a test
    /// cannot create a file owned by another uid without privilege, but it can ask on behalf of one.
    /// `mayTakeOwnership` then sees `created == false` and `directoryUID != callerUID`, which is the
    /// refusal, and the `fchown` below it is never reached.
    ///
    /// **What this actually pins, stated because this file's whole thesis is guards that look
    /// tested.** Unprivileged, the *effect* assertions cannot distinguish the guard from the kernel:
    /// with the guard removed, `fchown` to another uid returns EPERM, so `r.ok` is still false and
    /// the owner is still unchanged. A reviewer measured that — removing the guard fails exactly one
    /// assertion, the message one. The pin is therefore the refusal text, and rewording it silently
    /// degrades this test to asserting something the kernel already guarantees.
    func testItRefusesToTakeOverADirectoryThatBelongsToSomebodyElse() throws {
        try withParentDirectory { fd, dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("XCodeVault"), withIntermediateDirectories: false)
            let someoneElse = HelperService(callerUID: getuid() + 1, callerGID: getgid())

            let r = someoneElse.claimDirectory(inParent: fd, named: "XCodeVault", reportedAs: dir.path + "/XCodeVault")
            XCTAssertFalse(r.ok, "root must not hand a pre-existing directory to a caller that does not own it")
            XCTAssertTrue(r.message.contains("refusing to take ownership"), r.message)

            var st = stat()
            XCTAssertEqual(lstat(dir.appendingPathComponent("XCodeVault").path, &st), 0)
            XCTAssertEqual(st.st_uid, getuid(), "and the owner must be unchanged")
        }
    }

    /// A pre-existing directory the caller already owns is adopted rather than refused — the other
    /// half of the same predicate, and the one that makes the verb idempotent.
    ///
    /// It also asserts the **`fchown` actually ran**, which asserting `r.ok` alone does not: a
    /// reviewer pointed out that deleting the `fchown` line failed no test, because chowning to the
    /// uid that already owns the directory is invisible. Staged against a *group* instead — an
    /// unprivileged process may chown to any group it belongs to, so a machine where the account has
    /// a second group can observe the change. Where it has only one, the assertion degrades to the
    /// uid, which is honest rather than skipped: this suite runs under a CI gate that forbids skips.
    func testItAdoptsADirectoryTheCallerAlreadyOwnsAndChownsIt() throws {
        try withParentDirectory { fd, dir in
            let claimed = dir.appendingPathComponent("XCodeVault")
            try FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: false)

            var before = stat()
            XCTAssertEqual(lstat(claimed.path, &before), 0)
            let otherGroup = Self.aGroupTheCallerBelongsToOtherThan(before.st_gid)

            let r = HelperService(callerUID: getuid(), callerGID: otherGroup ?? getgid())
                .claimDirectory(inParent: fd, named: "XCodeVault", reportedAs: claimed.path)
            XCTAssertTrue(r.ok, "re-running the verb on its own directory must succeed: \(r.message)")

            var after = stat()
            XCTAssertEqual(lstat(claimed.path, &after), 0)
            XCTAssertEqual(after.st_uid, getuid())
            if let otherGroup {
                XCTAssertEqual(after.st_gid, otherGroup, "the fchown must have run — this is the line that had no test")
                XCTAssertNotEqual(after.st_gid, before.st_gid)
            } else {
                // Says so out loud. A reviewer pointed out that this branch otherwise produces an
                // identical PASS with nothing distinguishing "pinned the fchown" from "asserted a
                // tautology" — so a single-group CI container would silently delete the only
                // coverage of that line.
                XCTContext.runActivity(named: "fchown NOT pinned: this account belongs to one group only") { _ in }
            }
        }
    }

    /// A gid the current process may chown to, other than `excluding`. `nil` when the account
    /// belongs to only one group, which is rare on macOS but not impossible.
    private static func aGroupTheCallerBelongsToOtherThan(_ excluding: gid_t) -> gid_t? {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let n = getgroups(Int32(groups.count), &groups)
        guard n > 0 else { return nil }
        return groups.prefix(Int(n)).first { $0 != excluding }
    }

    /// **The escape a reviewer demonstrated.** `name` reaches `mkdirat`/`openat` directly, and
    /// `O_NOFOLLOW` does not constrain `..`, so before the byte check moved into the callee this
    /// created — and chowned — a directory outside the anchor subtree.
    func testItRefusesANameThatWouldEscapeTheParent() throws {
        try withParentDirectory { fd, dir in
            let outside = dir.deletingLastPathComponent().appendingPathComponent("XCV-ESCAPED-\(UUID().uuidString)")
            for bad in ["../" + outside.lastPathComponent, "..", ".", "", "link/inner", "a\u{0000}b"] {
                let r = service().claimDirectory(inParent: fd, named: bad, reportedAs: dir.path)
                XCTAssertFalse(r.ok, "accepted \(bad.debugDescription)")
                XCTAssertEqual(r.message, "invalid vault directory name", "for \(bad.debugDescription)")
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outside.path),
                "nothing may be created outside the parent the caller verified")
        }
    }

    /// A **file** where the directory should go is refused before anything is created or chowned.
    func testItRefusesANonDirectoryAtTheName() throws {
        try withParentDirectory { fd, dir in
            FileManager.default.createFile(atPath: dir.appendingPathComponent("XCodeVault").path, contents: Data([0]))
            let r = service().claimDirectory(inParent: fd, named: "XCodeVault", reportedAs: dir.path + "/XCodeVault")
            XCTAssertFalse(r.ok)
            XCTAssertTrue(r.message.contains("exists and is not a directory"), r.message)
        }
    }

    /// A **symlink** at the name is refused, and not followed. `fstatat(… AT_SYMLINK_NOFOLLOW)`
    /// reports the link itself, so it is "exists and is not a directory" — the point being that root
    /// never opens or chowns whatever it points at.
    func testItDoesNotFollowASymlinkAtTheName() throws {
        try withParentDirectory { fd, dir in
            let elsewhere = dir.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("XCodeVault"), withDestinationURL: elsewhere)

            let r = service().claimDirectory(inParent: fd, named: "XCodeVault", reportedAs: dir.path + "/XCodeVault")
            XCTAssertFalse(r.ok, "a symlink must never be adopted — root would chown its target")
            XCTAssertTrue(r.message.contains("is not a directory"), r.message)
        }
    }

    /// The cross-device arm of `isTheObjectThisCallJustCreated` — the guard that catches a volume
    /// mounted onto the name between `mkdirat` and `openat`, which is why any of this runs under
    /// `/Volumes` at all.
    ///
    /// **This test was deleted once and had to come back.** It used to be staged by passing a bogus
    /// `parentDevice`, which was itself proof that the parameter should not exist — a caller could
    /// switch the guard off. Removing the parameter was right; removing the test with it was not,
    /// and the comment left in its place said "the device is now read from the descriptor, so there
    /// is nothing to stage". That was false, and a reviewer measured it: any filesystem mounted
    /// inside another gives a pre-existing cross-device directory, unprivileged, with no mount and
    /// no mutation. `/dev` on `/` is one. With the check removed, `case .differentFilesystem`
    /// replaced by `break` compiled and passed the entire suite.
    ///
    /// Nothing is created or written here: the directory exists, so the `fstatat` branch is taken,
    /// the `openat` is read-only, and the refusal happens before `mayTakeOwnership` and long before
    /// `fchown`.
    func testItRefusesADirectoryOnADifferentFilesystemThanItsParent() throws {
        let parent = open("/", O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { return XCTFail("could not open /") }
        defer { close(parent) }

        var rootST = stat()
        var devST = stat()
        XCTAssertEqual(fstat(parent, &rootST), 0)
        XCTAssertEqual(stat("/dev", &devST), 0)
        // Precondition, and it `guard`s rather than merely asserting: an `XCTAssertNotEqual` records
        // a failure and lets the body run on, which on a machine where `/dev` shared `/`'s device
        // would mean calling the verb for no reason. Same idiom as `withParentDirectory`.
        guard rootST.st_dev != devST.st_dev else {
            return XCTFail("/dev is expected to be its own filesystem; this test cannot stage the cross-device arm otherwise")
        }

        let r = service().claimDirectory(inParent: parent, named: "dev", reportedAs: "/dev")
        XCTAssertFalse(r.ok)
        // **The pin is the message, and saying so is the honest version.** With the arm removed the
        // call falls through to the ownership refusal, which also returns `ok: false` — so
        // `XCTAssertFalse(r.ok)` above cannot tell the two apart, exactly as the sibling test's doc
        // says of its own refusal. Rewording this string silently degrades the test.
        XCTAssertTrue(
            r.message.contains("different filesystem"),
            "a cross-device child must be refused by the device check, not fall through to the ownership one: \(r.message)")
    }

}
