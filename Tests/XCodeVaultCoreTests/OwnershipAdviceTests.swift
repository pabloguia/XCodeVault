import XCTest

@testable import XCodeVaultCore

/// The value of this type is entirely in the text it emits: a command the user pastes into a root
/// shell. A wrong path, a broken quote, or a hardcoded user name turns "helpful" into "dangerous",
/// so the assertions here are about the exact string, not about behaviour.
final class OwnershipAdviceTests: XCTestCase {
    func testShellQuotingSurvivesVolumeNamesWithSpacesAndApostrophes() {
        XCTAssertEqual(OwnershipAdvice.shellQuoted("/Volumes/Simple/XcodeVault"), "'/Volumes/Simple/XcodeVault'")
        XCTAssertEqual(OwnershipAdvice.shellQuoted("/Volumes/My SSD/XcodeVault"), "'/Volumes/My SSD/XcodeVault'")
        // "Dev's SSD" is the case that breaks naive single-quoting: the embedded quote has to
        // close, escape, and reopen or the pasted command is unbalanced.
        XCTAssertEqual(OwnershipAdvice.shellQuoted("/Volumes/Dev's SSD/XcodeVault"), "'/Volumes/Dev'\\''s SSD/XcodeVault'")
    }

    func testCreateCommandUsesTheRealUserAndQuotesThePath() {
        let advice = OwnershipAdvice.createVaultDirectory("/Volumes/Dev's SSD/XcodeVault")
        let (user, group) = OwnershipAdvice.currentUserAndGroup()
        XCTAssertTrue(
            advice.contains(
                "sudo install -d -o \(OwnershipAdvice.shellQuoted(user)) -g \(OwnershipAdvice.shellQuoted(group)) -m 755 '/Volumes/Dev'\\''s SSD/XcodeVault'"),
                      "the pasted command must be correct verbatim: \(advice)")
        XCTAssertFalse(user.isEmpty)
        XCTAssertFalse(group.isEmpty)
        // `install -d` over `mkdir`+`chown` for idempotency, NOT atomicity: install(1)
        // does mkdir then chown, so the root-owned window exists either way.
        XCTAssertFalse(advice.contains("mkdir"), "one idempotent command beats mkdir + chown")
        XCTAssertTrue(advice.contains("XCodeVault will not run this for you"),
                      "must be explicit that the tool does not run privileged commands itself")
    }

    func testWritableDirectoryIsNotReportedAsAProblem() {
        let t = TempDir()
        let dir = t.dir("vault")
        XCTAssertNil(OwnershipAdvice.writabilityProblem(dir))
    }

    func testMissingPathIsTheCallersProblemNotOurs() {
        let t = TempDir()
        XCTAssertNil(OwnershipAdvice.writabilityProblem(t.path + "/does-not-exist"),
                     "absence is handled by the create path; this check is only about usability")
    }

    func testAFileWhereTheVaultDirectoryShouldBeIsReported() {
        let t = TempDir()
        let f = t.file("vault", bytes: 4)
        XCTAssertEqual(
            OwnershipAdvice.writabilityProblem(f),
            "\(f) exists but is not a directory. The vault directory must be a real directory on the volume itself.")
    }

    func testEnableOwnershipAdviceWarnsAboutTheSideEffectItCauses() {
        let advice = OwnershipAdvice.enableOwnership("/Volumes/My SSD")
        XCTAssertTrue(advice.contains("sudo diskutil enableOwnership '/Volumes/My SSD'"))
        // The whole point: enabling ownership is what makes the volume root unwritable, and a user
        // who is not told that reads the next failure as the tool being broken.
        XCTAssertTrue(advice.contains("root ownership"), "must explain the consequence: \(advice)")
    }

    /// Blocking finding from review: `chown -R` on a user-supplied `--directory` is an irreversible
    /// privileged mutation of data XCodeVault did not create, and it flattens exactly the mixed
    /// root/user ownership MIGRATION_ENGINE says to preserve. A populated directory gets no command.
    func testPopulatedUnwritableDirectoryGetsNoOwnershipCommandAtAll() throws {
        try XCTSkipIf(getuid() == 0, "root can write a 000 directory")
        let t = TempDir()
        let dir = t.dir("someone-elses-data")
        _ = t.file("someone-elses-data/precious.db", bytes: 16)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir, currentUID: getuid() + 1))
        XCTAssertFalse(problem.contains("chown"), "never offer to take ownership of a populated directory: \(problem)")
        XCTAssertFalse(problem.contains("-R"), "and certainly not recursively: \(problem)")
        XCTAssertTrue(problem.contains("is not empty"), "must say why it refuses: \(problem)")
        XCTAssertTrue(problem.contains("did not create"), "must name the reason, not just decline")
    }

    /// The `sudo mkdir` case: an empty, root-owned directory. Non-recursive chown is the whole fix,
    /// because the failing operation is creating an entry *in* it, not touching its contents.
    func testEmptyUnwritableDirectoryGetsANonRecursiveChown() throws {
        try XCTSkipIf(getuid() == 0, "root can write a 000 directory")
        let t = TempDir()
        let dir = t.dir("empty-vault")
        // 0o500 on purpose: readable and listable but not writable. Mode 000 would also be
        // unreadable and would (correctly) take the "could not be read" branch instead.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir, currentUID: getuid() + 1))
        // Presented as somebody else's directory (see the currentUID seam), which is the shape a
        // bare `sudo mkdir` leaves: empty, not ours, so handing over the directory itself is the fix.
        XCTAssertTrue(problem.contains("sudo chown"), "\(problem)")
        XCTAssertFalse(problem.contains("chown -R"), "must not be recursive: \(problem)")
        XCTAssertTrue(problem.contains("deliberately not recursive"), "must say so out loud: \(problem)")
    }

    /// A symlink at the vault path would produce a "vault" that is local shadow data wearing a
    /// canonical path, because PathSafety.isContained compares strings.
    func testSymlinkAtTheVaultPathIsRefused() {
        let t = TempDir()
        t.dir("real-elsewhere")
        let link = t.symlink("vault-link", to: t.path + "/real-elsewhere")
        let problem = OwnershipAdvice.writabilityProblem(link)
        XCTAssertEqual(problem, "\(link) exists but is a symlink. The vault directory must be a real directory on the volume itself.")
    }

    /// BLOCKING regression: `try? … ?? []` failed open, so a directory we could not read was called
    /// empty and offered a `chown`. Reaching that code means `access` already failed, so unreadable
    /// is the common case, not the edge one. Third appearance of this exact pattern in one session.
    func testUnreadableDirectoryHoldingDataGetsNoOwnershipCommand() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory")
        let t = TempDir()
        let dir = t.dir("opaque")
        _ = t.file("opaque/precious.db", bytes: 16)
        // 000 makes it both unwritable and unlistable — the shape a `sudo mkdir -m 700` leaves.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        // Owned by us at 000 would take the chmod branch, so make the ownership check fail too by
        // asserting on the message rather than the uid: what matters is that no chown is offered.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir, currentUID: getuid() + 1))
        XCTAssertFalse(problem.contains("sudo chown"), "never offer a chown for a directory we could not inspect: \(problem)")
        XCTAssertFalse(problem.contains("It is empty"), "must not claim emptiness it could not observe: \(problem)")
    }

    /// A directory that is already ours is never an ownership problem — `chown me:staff` is a no-op.
    /// A missing execute or write bit is a `chmod`, and saying "an ACL is denying writes" sends the
    /// user hunting for an ACE that is not there.
    func testOurOwnDirectoryWithMissingBitsIsAChmodNotAnACLNorAChown() throws {
        try XCTSkipIf(getuid() == 0, "root ignores the permission bits")
        for mode in [0o600, 0o500] {
            let t = TempDir()
            let dir = t.dir("mine")
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
            let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir), "mode \(String(mode, radix: 8))")
            XCTAssertTrue(problem.contains("chmod"), "mode \(String(mode, radix: 8)) should point at chmod: \(problem)")
            XCTAssertFalse(problem.contains("sudo chown"), "changing owner to the current owner is a no-op: \(problem)")
            XCTAssertFalse(problem.contains("ACL"), "the owner bits explain this; do not blame an ACL: \(problem)")
            XCTAssertTrue(problem.contains("No `sudo`"), "this one needs no privilege at all: \(problem)")
        }
    }

    /// A genuine deny ACE on a directory whose owner bits say the write should succeed. `chmod +a`
    /// works unprivileged inside the test's own temp directory.
    func testDenyACLIsDiagnosedAsAnACLRatherThanOwnership() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses ACLs")
        let t = TempDir()
        let dir = t.dir("acl-denied")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "\(NSUserName()) deny write,add_file,add_subdirectory,delete_child", dir]
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "could not set an ACL on this filesystem")
        defer {
            let r = Process(); r.executableURL = URL(fileURLWithPath: "/bin/chmod")
            r.arguments = ["-N", dir]; try? r.run(); r.waitUntilExit()
        }
        let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir))
        XCTAssertTrue(problem.contains("ACL"), "owner bits allow writing, so an ACL is the explanation: \(problem)")
        XCTAssertTrue(problem.contains("chmod -a"), "must name how to remove a deny entry: \(problem)")
        XCTAssertFalse(problem.contains("sudo chown"), "ownership cannot lift a deny ACE: \(problem)")
    }

    /// The regression finding D described: a real vault OF OURS is non-empty (it holds the
    /// sentinel), so if the emptiness refusal ran before the ownership check it would be told to
    /// "point --directory somewhere else" for what is plainly its own vault.
    func testOurOwnPopulatedVaultWithADenyACEIsDiagnosedAsAnACLNotRedirected() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses ACLs")
        let t = TempDir()
        let dir = t.dir("XcodeVault")
        _ = t.file("XcodeVault/.xcodevault-volume.json", bytes: 32)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "\(NSUserName()) deny write,add_file,add_subdirectory,delete_child", dir]
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "could not set an ACL on this filesystem")
        defer {
            let r = Process(); r.executableURL = URL(fileURLWithPath: "/bin/chmod")
            r.arguments = ["-N", dir]; try? r.run(); r.waitUntilExit()
        }
        let problem = try XCTUnwrap(OwnershipAdvice.writabilityProblem(dir))
        XCTAssertTrue(problem.contains("ACL"), "a populated vault of ours must still be diagnosed: \(problem)")
        XCTAssertFalse(problem.contains("did not create"), "this IS ours — must not redirect us elsewhere: \(problem)")
        XCTAssertFalse(problem.contains("--directory"), "must not tell us to pick another path: \(problem)")
    }
}
