import XCTest

/// Lints the experiment harness from inside the test suite, because `swift test` is this repo's
/// commit gate and a shell script that nothing runs on every commit is a script nobody checks.
///
/// Written after a real near-miss on 2026-09-15. `e18-simctl-log-erase.sh` exists to run
/// `log erase --all` *inside a simulator device*; the same command on the host erases the user's
/// own Mac system logs. The script's header says so at length. It then contained this line:
///
///     echo "!! `log erase --all` failed inside the device. …"
///
/// Backticks inside double quotes are command substitution, so that line would have run the
/// host-wide erase — introduced by writing readable prose in an error message, in the one script
/// whose entire safety argument is "the dangerous command only ever appears behind a UDID".
/// Reviewing for it is not a defence; it arrives through the part of the file that reads like text.
final class ExperimentScriptSafetyTests: XCTestCase {
    private var experimentsDirectory: String {
        // …/Tests/XCodeVaultCoreTests/<this file> → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/experiments").path
    }

    /// True when the line contains a `` ` `` the shell would execute. `` \` `` is quoting and fine.
    static func hasUnescapedBacktick(_ text: String) -> Bool {
        var previous: Character = " "
        for ch in text {
            if ch == "`" && previous != "\\" { return true }
            previous = ch
        }
        return false
    }

    /// True when the line runs a command through either substitution form. Used only where the
    /// substituted command is itself the hazard, never as a blanket style rule.
    static func hasUnescapedSubstitution(_ text: String) -> Bool {
        var previous: Character = " "
        var iterator = text.makeIterator()
        var current = iterator.next()
        while let ch = current {
            let next = iterator.next()
            if ch == "`" && previous != "\\" { return true }
            if ch == "$" && previous != "\\" && next == "(" { return true }
            previous = ch
            current = next
        }
        return false
    }

    private func scripts() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: experimentsDirectory)
        return names.filter { $0.hasSuffix(".sh") }.sorted().map { experimentsDirectory + "/" + $0 }
    }

    func testTheHarnessIsThereToBeLinted() throws {
        XCTAssertFalse(try scripts().isEmpty, "found no experiment scripts at \(experimentsDirectory); this suite would pass vacuously")
    }

    /// Backticks in an `echo`, which is how the near-miss arrived: someone writes `` `cmd` `` meaning
    /// markdown and the shell reads a call.
    ///
    /// Deliberately NOT extended to `$( … )`. A first attempt did, and went red on
    /// `echo "   $(du -shx …)"` all over the harness — substitution in an echo is ordinary shell and
    /// nobody types it by accident, while a backtick in prose is the accident itself. The dangerous
    /// `$(log erase --all)` form is caught by the rule below, which no longer exempts echo lines.
    /// A lint that cries wolf earns an allowlist, and an allowlisted lint has stopped being one.
    func testNoEchoRunsACommandThroughUnescapedBackticks() throws {
        var offences: [String] = []
        for path in try scripts() {
            let name = (path as NSString).lastPathComponent
            for (i, line) in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("echo ") else { continue }
                if Self.hasUnescapedBacktick(text) { offences.append("\(name):\(i + 1): \(text)") }
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            "backticks inside a double-quoted echo are command substitution, not quoting. Escape them as \\`:\n"
                + offences.joined(separator: "\n"))
    }

    /// The red-run, encoded. "I checked it catches the bug" is a memory; this is the check.
    func testTheRulesGoRedOnBothFormsOfTheBug() {
        let backtick = #"echo "!! `log erase --all` failed inside the device.""#
        let dollar = #"echo "!! $(log erase --all) failed inside the device.""#
        let escaped = #"echo "!! \`log erase --all\` failed inside the device.""#
        XCTAssertTrue(Self.hasUnescapedBacktick(backtick), "the original near-miss was not detected")
        XCTAssertFalse(Self.hasUnescapedBacktick(escaped), "an escaped backtick is quoting, not a call")
        XCTAssertFalse(Self.hasUnescapedBacktick("echo 'plain text, no backticks'"), "false positive on a plain line")
        // The $( ) form is not a backtick, and is caught by the `log erase` rule instead.
        XCTAssertFalse(Self.hasUnescapedBacktick(dollar), "the backtick rule should not claim the $( ) form")
        XCTAssertTrue(Self.hasUnescapedSubstitution(dollar), "the $( ) form was not detected as substitution")
    }

    /// `log erase` must never appear without a `simctl spawn` on the same line. On the host it
    /// erases the user's system logs; the UDID in front of it is the entire safety property.
    func testTheHostWideEraseIsNeverReachable() throws {
        var offences: [String] = []
        for path in try scripts() {
            let name = (path as NSString).lastPathComponent
            for (i, line) in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("#"), text.contains("log erase") else { continue }
                // No exemption for `echo`. An echo that prints the command must have it escaped or
                // single-quoted; an echo that substitutes it RUNS it, which is the whole hazard, and
                // exempting the line the hazard arrives on was the hole in the first version.
                if text.hasPrefix("echo ") && !Self.hasUnescapedSubstitution(text) { continue }
                if !text.contains("simctl") || !text.contains("spawn") {
                    offences.append("\(name):\(i + 1): \(text)")
                }
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            "`log erase` outside `simctl spawn <udid>` erases the host's own logs:\n" + offences.joined(separator: "\n"))
    }

    /// A script that creates, boots or deletes a simulator device must ask first. The user runs
    /// real test suites on the devices in the default set, and a script that mutates one by reflex
    /// is the failure their standing rule exists to prevent.
    ///
    /// Scoped to lines that actually invoke the verb: an earlier version matched `simctl help
    /// create` and a mention in a comment, and flagged two read-only scripts as hazards. A lint
    /// that cries wolf gets an allowlist, and then it stops being a lint.
    func testEveryScriptThatTouchesADeviceAsksFirst() throws {
        var offences: [String] = []
        for path in try scripts() {
            let name = (path as NSString).lastPathComponent
            let body = try String(contentsOfFile: path, encoding: .utf8)
            var mutatingLines: [String] = []
            for (i, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("#"), !text.hasPrefix("echo "), text.contains("simctl") else { continue }
                guard !text.contains("simctl help") else { continue }
                if ["create", "boot", "delete", "erase", "shutdown", "install", "launch", "terminate"]
                    .contains(where: { text.contains(" \($0) ") || text.hasSuffix(" \($0)") }) {
                    mutatingLines.append("\(name):\(i + 1)")
                }
            }
            guard !mutatingLines.isEmpty else { continue }
            // Only the explicit flag counts. `read -r` was accepted as an interactive prompt until
            // a review pointed at `e14a-device-set-static.sh`, where it is a `while read -r f` parse
            // loop — a gate signal that any pipeline can satisfy by accident is not a gate.
            let gated = body.contains("--i-understand")
            if !gated { offences.append("\(name) (first at \(mutatingLines[0]))") }
        }
        XCTAssertTrue(
            offences.isEmpty,
            "these scripts create/boot/delete a simulator device with no confirmation gate:\n" + offences.joined(separator: "\n"))
    }
}
