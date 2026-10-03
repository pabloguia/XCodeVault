import XCTest

@testable import xcodevaultctl

/// Color is for a person at a terminal: never piped, never under NO_COLOR, never on a dumb terminal.
final class CLIColorTests: XCTestCase {
    func testWantsColorTruthTable() {
        for tty in [true, false] {
            for noColor in [true, false] {
                for dumb in [true, false] {
                    var env: [String: String] = ["TERM": dumb ? "dumb" : "xterm-256color"]
                    if noColor { env["NO_COLOR"] = "" }
                    XCTAssertEqual(
                        XCodeVaultCTL.wantsColor(environment: env, isTTY: tty), tty && !noColor && !dumb, "tty=\(tty) NO_COLOR=\(noColor) dumb=\(dumb)")
                }
            }
        }
    }

    func testAnUnsetTermStillAllowsColor() {
        XCTAssertTrue(XCodeVaultCTL.wantsColor(environment: [:], isTTY: true))
    }
}
