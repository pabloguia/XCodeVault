import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// Color is for a person at a terminal: never piped, never under NO_COLOR, never on a dumb terminal; and 24-bit
/// only where the terminal says it can.
final class CLIColorTests: XCTestCase {
    func testColorDepthTruthTable() {
        for tty in [true, false] {
            for noColor in [true, false] {
                for dumb in [true, false] {
                    for colorterm in [nil, "truecolor", "24bit", "TrueColor", "24BIT", "yes"] {
                        var env: [String: String] = ["TERM": dumb ? "dumb" : "xterm-256color"]
                        if noColor { env["NO_COLOR"] = "" }
                        if let colorterm { env["COLORTERM"] = colorterm }
                        let expected: ColorDepth =
                            !tty || noColor || dumb
                            ? .none : (["truecolor", "24bit"].contains(colorterm?.lowercased() ?? "") ? .trueColor : .ansi256)
                        XCTAssertEqual(
                            XCodeVaultCTL.colorDepth(environment: env, isTTY: tty), expected,
                            "tty=\(tty) NO_COLOR=\(noColor) dumb=\(dumb) COLORTERM=\(colorterm ?? "-")")
                    }
                }
            }
        }
    }

    func testAnUnsetTermStillAllowsColor() {
        XCTAssertEqual(XCodeVaultCTL.colorDepth(environment: [:], isTTY: true), .ansi256)
    }
}
