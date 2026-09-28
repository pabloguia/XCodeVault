import Foundation
import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// The CLI's side of F3 (ADR-0009): the runtime verbs run only the selected Xcode's tools, and `xcode list` says
/// which Xcodes were not probed instead of showing every capability of theirs as missing.
final class CLIXcodeSelectionTests: XCTestCase {
    private func xcode(_ path: String, selected: Bool, probed: Bool, capabilities: XcodeCapabilities = XcodeCapabilities()) -> XcodeInstallation {
        XcodeInstallation(
            path: path, developerDirectory: path + "/Contents/Developer", version: "26.5", build: "17F42", isSelected: selected,
            capabilities: capabilities, capabilitiesProbed: probed)
    }

    private let planted = "/Users/u/Applications/Xcode-planted.app"

    func testTheRuntimeVerbsUseTheSelectedXcode() throws {
        let chosen = xcode("/Applications/Xcode.app", selected: true, probed: true)
        // Found first, as a bundle in ~/Applications can be.
        XCTAssertEqual(try Runtime.selected([xcode(planted, selected: false, probed: false), chosen]), chosen)
    }

    /// Until 2026-09-28 the first Xcode found was used when none was selected. The refusal counts what was found and
    /// prints none of it: a folder's name is chosen by whoever made the folder, and can hold a newline or a terminal
    /// escape, right above the advice to run `sudo xcode-select -s` (helper-security review of F3, round 1).
    func testTheRuntimeVerbsRefuseWhenNoXcodeIsSelected() {
        let found = [xcode(planted, selected: false, probed: false), xcode("/Applications/Xcode-beta.app", selected: false, probed: false)]
        XCTAssertThrowsError(try Runtime.selected(found)) {
            XCTAssertTrue("\($0)".contains("No Xcode is selected"), "\($0)")
            XCTAssertTrue("\($0)".contains("none of the Xcodes found (2;"), "\($0)")
            XCTAssertFalse("\($0)".contains("Xcode-planted") || "\($0)".contains("Xcode-beta"), "no path printed: \($0)")
        }
        XCTAssertThrowsError(try Runtime.selected([])) { XCTAssertTrue("\($0)".contains("No Xcode found"), "\($0)") }
    }

    func testXcodeListSaysWhichXcodesWereNotProbed() throws {
        var caps = XcodeCapabilities()
        caps.downloadPlatform = true
        let text = Xcode.List.render([
            xcode("/Applications/Xcode.app", selected: true, probed: true, capabilities: caps),
            xcode("/Applications/Xcode-beta.app", selected: false, probed: false),
        ])
        let lines = text.split(separator: "\n").map(String.init)
        let selectedAt = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("— /Applications/Xcode.app") }, text)
        let otherAt = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("— /Applications/Xcode-beta.app") }, text)
        XCTAssertLessThan(selectedAt, otherAt, text)
        // Positive control: the probed Xcode shows its rows, a ✓ where its help named the flag and a ✗ where not.
        let probedRows = lines[(selectedAt + 1)..<otherAt]
        XCTAssertTrue(probedRows.contains("    ✓ downloadPlatform"), text)
        XCTAssertTrue(probedRows.contains("    ✗ downloadAllPlatforms"), text)
        XCTAssertFalse(probedRows.contains { $0.contains("not probed") }, text)
        // The other says it was not probed, and shows no row: a ✗ would say "unsupported" about what was never asked.
        XCTAssertEqual(Array(lines[(otherAt + 1)...]), ["    capabilities not probed: only the xcode-select'ed Xcode's tools are run"], text)
    }

    /// The selected Xcode is not probed when its `xcodebuild -help` could not be started; the reason differs.
    func testXcodeListSaysWhyTheSelectedXcodeWasNotProbed() {
        let text = Xcode.List.render([xcode("/Applications/Xcode.app", selected: true, probed: false)])
        XCTAssertEqual(
            text.split(separator: "\n").map(String.init),
            ["* Xcode 26.5 (17F42) — /Applications/Xcode.app", "    capabilities not probed: its `xcodebuild -help` could not be run"])
    }
}
