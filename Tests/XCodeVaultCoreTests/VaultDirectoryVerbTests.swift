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
/// **What this can and cannot reach, stated rather than implied.** Everything past the mount
/// lookup needs a real volume mounted under `/Volumes`, which a unit test cannot create without
/// privilege this project refuses to take. So these cover the four refusals that precede it, and
/// the `mayTakeOwnership` call site remains unpinned — deliberately, and now visibly, rather than
/// behind a sentence in a document. The E-series runbooks are where that half is exercised.
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
}
