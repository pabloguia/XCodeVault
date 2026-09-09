import XCTest

@testable import XCodeVaultCore
import XCodeVaultHelperProtocol

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
}
