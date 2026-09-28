import XCTest
import XCodeVaultHelperProtocol

@testable import XCodeVaultCore

/// The client and the privileged helper agree on a few constants by convention rather than by a
/// shared type: `XCodeVaultCore` is declared with no dependencies ("no UI, no privileged calls, no
/// shell") and the helper links only `XCodeVaultHelperProtocol`, so neither can see the other's
/// literals. These tests are what makes that separation safe instead of merely tidy.
final class HelperContractTests: XCTestCase {
    /// If these two ever disagree, the helper creates one directory under `sudo` and the client
    /// looks for another — and on a case-sensitive volume (the user's actual drive is one) a
    /// single wrong letter is a genuinely different path, so this cannot be caught by inspection.
    func testVaultDirectoryNameMatchesTheHelperContract() {
        XCTAssertEqual(VaultVolume.directoryName, VaultDirectory.name)
    }

    /// Scope note, from the helper security review: this pins the *default*. What the client
    /// actually uses at runtime is `VaultVolume.relativeDirectory`, which `vault init --directory`
    /// can override — and the helper can only ever create `VaultDirectory.name`. So a user who
    /// registers with a custom directory gets a helper-created `XCodeVault` the client never looks
    /// at. The helper refusing a client-supplied path is correct and must not change; the gap is
    /// that the helper-assisted flow simply does not apply to a custom directory.
    ///
    /// Guards the spelling itself, not just the agreement: both sides could be renamed together by
    /// a careless find-and-replace and still match each other while breaking every existing vault.
    func testVaultDirectoryNameIsTheProjectSpelling() {
        XCTAssertEqual(VaultDirectory.name, "XCodeVault", "capital C — matches the project name")
        XCTAssertFalse(VaultDirectory.name.contains("/"), "must be a single path component")
        XCTAssertFalse(VaultDirectory.name.hasPrefix("."), "must not be hidden")
        // These two are not hygiene: the helper builds `<mount>/<name>` and chowns the result to the
        // caller, so a leading ".." would resolve to /Volumes itself. The helper now guards this at
        // the point of use too; this assertion is the second lock, not the only one.
        XCTAssertNotEqual(VaultDirectory.name, "..")
        XCTAssertNotEqual(VaultDirectory.name, ".")
    }

    /// Core names the dyld cache path for Full Disk Access (`PrivilegeRequirement`); the helper owns the
    /// path it will actually empty (`HelperCleanupTarget`). Neither module sees the other, so this is the
    /// one place the two can be held equal.
    func testTheDyldCachePathIsTheOneTheHelperEmpties() {
        XCTAssertEqual(PrivilegeRequirement.coreSimulatorDyldCachePath, HelperCleanupTarget.coreSimulatorDyldCache.path)
    }

    /// `VaultDirectoryRefusal.helperAccepts` decides where `doctor` offers the helper's vault-folder action; the
    /// helper decides where it acts, with a guard inside `createVaultDirectory` that no test can call. A text
    /// check, because the guard is inline: if the helper's shape rule changes, this fails and names the mirror
    /// to update, rather than `doctor` offering an action the helper refuses (or hiding one it would take).
    func testTheVaultFolderActionMirrorsTheHelpersMountPointGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("Sources/XCodeVaultHelperCore/HelperService.swift"), encoding: .utf8)
        XCTAssertEqual(
            service.components(separatedBy: #"guard mp.hasPrefix("/Volumes/"), mp.split(separator: "/").count == 2 else {"#).count - 1, 1,
            "the helper's mount-point guard changed; update VaultDirectoryRefusal.helperAccepts to match")
        XCTAssertTrue(service.contains("guard UUID(uuidString: volumeUUID) != nil"), "the helper's UUID guard changed; update helperAccepts")
    }

    /// The helper and the rest of the product carry their version separately — `HelperIdentity`
    /// lives in the XPC contract module, which by design cannot see `XCodeVaultCore` — so "the
    /// version" has two sources of truth and nothing reconciled them. That matters because the
    /// `version()` verb exists for version-skew checks: a daemon that reports a different version
    /// from the client that shipped with it makes the one mechanism for detecting skew lie.
    ///
    /// Found by the helper-security review of 2026-09-18, after the XPC surface changed (a verb was
    /// removed) while `HelperIdentity.version` stayed put. This assertion is the reconciliation the
    /// module boundary prevents expressing in code.
    func testHelperVersionMatchesTheProductVersion() {
        XCTAssertEqual(
            HelperIdentity.version, XCodeVaultVersion.current,
            "the helper reports a different version from the product it ships inside; the version() verb is the skew check and it must not lie")
    }
}
