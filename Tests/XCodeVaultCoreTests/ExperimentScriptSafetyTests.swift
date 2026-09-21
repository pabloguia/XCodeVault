import XCTest

@testable import XCodeVaultHelperProtocol

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
                    .contains(where: { text.contains(" \($0) ") || text.hasSuffix(" \($0)") })
                {
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

    // MARK: the evidence ledger (issue #23)

    private var evidenceDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/research/evidence").path
    }

    /// Every script writes through `common.sh`, which is where the header and the redactor live.
    ///
    /// A script that writes evidence by hand is a script whose output nothing redacted. Checked
    /// here rather than by reading, because the 2026-09-19 audit that first established this was a
    /// one-off, and a one-off audit of a growing directory is a fact with an expiry date.
    func testEveryExperimentScriptGoesThroughTheSharedHeaderAndRedactor() throws {
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: experimentsDirectory).sorted()
        where name.hasPrefix("e") && name.hasSuffix(".sh") {
            let body = try String(contentsOfFile: experimentsDirectory + "/" + name, encoding: .utf8)
            guard body.contains("common.sh") else {
                offenders.append("\(name): does not source common.sh")
                continue
            }
            guard body.contains("xcv_redact") || body.contains("xcv_header") || body.contains("xcv_out") else {
                offenders.append("\(name): sources common.sh but uses none of its header/redaction helpers")
                continue
            }
        }
        XCTAssertTrue(offenders.isEmpty, "evidence written outside the redactor:\n" + offenders.joined(separator: "\n"))
    }

    /// No committed evidence file names this machine.
    ///
    /// Runs against the *running* machine's identity, so it is a real check on a contributor's
    /// laptop and a near-vacuous one on a CI runner whose home is `/Users/runner`. That asymmetry
    /// is the point: the leak this prevents happens when a person runs an experiment locally and
    /// commits the output, and that person's machine is exactly where this test then runs.
    ///
    /// Deliberately not checked: CoreSimulator runtime and device identifiers, and Apple's APFS
    /// partition-type GUID. `Redaction.swift` says at length why those survive — several findings
    /// are unreadable without them, and none identifies a person.
    /// Volume names that identify nobody, and would otherwise make this test fail on a machine
    /// that merely happens to have one mounted.
    ///
    /// Added after the first CI run of this test went red. The property being asserted is "no
    /// evidence file names *this developer's* drive", and a volume called `Data` or `Recovery` is
    /// a macOS system volume, not a drive anyone named. The committed evidence legitimately
    /// contains `/Volumes/Data` — it came out of `diskutil list` on the machine that ran the
    /// experiment — and on a host where a volume by that name is mounted, comparing by name alone
    /// reads that as a leak of the host's identity. It is not: the string carries no information
    /// about either machine.
    ///
    /// This is a list, and a list is a thing that rots. The residual is stated rather than hidden:
    /// a developer whose external drive is called `Data` gets no protection from this test. That is
    /// an acceptable trade for a check whose whole purpose is catching the ordinary case, and the
    /// redaction in `common.sh` — which substitutes by value at write time — is the real control.
    /// Account names that belong to a machine nobody owns.
    ///
    /// Same shape as `genericVolumeNames`, added for the same reason and after the same symptom: CI
    /// went red on committed evidence that legitimately contains the phrase `swift test
    /// --scratch-path (second runner)`, because the GitHub Actions account is called `runner` and the
    /// word-bounded match fired. The property under test is "no evidence file names *this
    /// developer's* machine", and `runner` names a disposable VM — the string carries no information
    /// about either machine, which is exactly the argument the volume list already makes.
    ///
    /// The residual, stated rather than hidden: a developer whose account is called `ci` or `admin`
    /// gets no protection from this test. That is the same acceptable trade, and the redaction in
    /// `common.sh`, which substitutes by value at write time, remains the real control.
    static let genericAccountNames: Set<String> = [
        "runner", "runneradmin", "ci", "build", "builder", "jenkins", "travis", "circleci", "admin", "administrator",
    ]

    static let genericVolumeNames: Set<String> = [
        "Data", "Preboot", "Recovery", "Update", "VM", "xarts", "iSCPreboot", "Hardware", "Macintosh HD",
    ]

    /// The rule, as a function of its inputs rather than of the machine running it.
    ///
    /// Extracted after a CI failure this test could not be reproduced locally for: the rule read
    /// `NSUserName()` directly, so "does it fire for the account name `runner`?" was a question only
    /// a CI run could answer, and each answer cost a push. A check whose behaviour cannot be
    /// examined except by triggering it is one nobody can reason about.
    static func machineIdentityLeaks(in text: String, fileName: String, home: String, user: String, mountedVolumes: [String]) -> [String] {
        var leaks: [String] = []
        if !home.isEmpty, text.contains(home) { leaks.append("\(fileName): contains the home directory") }
        // Word-bounded, for the reason `Redaction.swift` records: an account called `dev`
        // unanchored turns `devicectl` into a false positive.
        if !user.isEmpty, user != "root", !genericAccountNames.contains(user.lowercased()) {
            let pattern = "(^|[^A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: user) + "([^A-Za-z0-9_]|$)"
            if let re = try? NSRegularExpression(pattern: pattern),
                re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            {
                leaks.append("\(fileName): contains the account name as a bare word")
            }
        }
        // Volume names only in their `/Volumes/` form — the same rule and the same reason
        // `Redaction.swift` gives: a boot volume called `MacOS` appears inside every app
        // bundle's `Contents/MacOS`.
        for volume in mountedVolumes where !volume.hasPrefix(".") && !genericVolumeNames.contains(volume) {
            if text.contains("/Volumes/" + volume) { leaks.append("\(fileName): names the mounted volume '\(volume)'") }
        }
        return leaks
    }

    func testNoEvidenceFileNamesThisMachine() throws {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        var leaks: [String] = []

        for name in try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory).sorted() where !name.hasPrefix(".") {
            let text = try String(contentsOfFile: evidenceDirectory + "/" + name, encoding: .utf8)
            leaks += Self.machineIdentityLeaks(in: text, fileName: name, home: home, user: user, mountedVolumes: volumes)
        }
        XCTAssertTrue(
            leaks.isEmpty,
            """
            Evidence files are written to be pasted into a public issue. These name this machine:

            \(leaks.joined(separator: "\n"))
            """)
    }

    /// The CI case, asserted from any machine. GitHub's macOS runners run as `runner`, and the
    /// committed evidence legitimately contains `swift test --scratch-path (second runner)` — the
    /// word-bounded match fired on all three files and CI was red on every push for three commits
    /// while the suite passed locally.
    func testTheCheckDoesNotFireOnAGenericCIAccountName() throws {
        let realEvidence = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory)
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, text: try String(contentsOfFile: evidenceDirectory + "/" + $0, encoding: .utf8)) }
        XCTAssertTrue(
            realEvidence.contains { $0.text.contains("second runner") },
            "precondition: the committed evidence really does contain the word that broke CI")

        for file in realEvidence {
            XCTAssertEqual(
                Self.machineIdentityLeaks(in: file.text, fileName: file.name, home: "/Users/runner", user: "runner", mountedVolumes: []),
                [], "a disposable CI VM's account name is not this developer's identity")
        }
    }

    /// The control, and the reason the test above is not simply a hole. A real account name is still
    /// caught — including one that appears only as a bare word, with no home directory in the text.
    func testTheCheckStillFiresForANonGenericAccountName() {
        let text = "--- swift test --scratch-path (second runner) ---\nwrote /Users/octavia/out.txt as octavia\n"
        XCTAssertEqual(
            Self.machineIdentityLeaks(in: text, fileName: "e.txt", home: "/Users/octavia", user: "octavia", mountedVolumes: []),
            ["e.txt: contains the home directory", "e.txt: contains the account name as a bare word"])
        XCTAssertEqual(
            Self.machineIdentityLeaks(in: "owner: octavia\n", fileName: "e.txt", home: "", user: "octavia", mountedVolumes: []),
            ["e.txt: contains the account name as a bare word"],
            "the account rule must stand on its own, not only alongside the home-directory rule")
        XCTAssertEqual(
            Self.machineIdentityLeaks(
                in: "mounted at /Volumes/Octavia-SSD\n", fileName: "e.txt", home: "", user: "runner", mountedVolumes: ["Octavia-SSD", "Data"]),
            ["e.txt: names the mounted volume 'Octavia-SSD'"],
            "and a named drive is still caught on a CI account, while a generic system volume is not")
    }

    /// `xcv_e6b_target` is an allowlist protecting a `mount` under sudo, and its comment claims the
    /// set "mirrors `HelperCleanupTarget` … the same two paths the privileged cleanup verb allows".
    ///
    /// That claim is the whole safety argument — these scripts mount a donor filesystem OVER the
    /// path and later force-unmount it — and it is written in two places, which is where rules
    /// drift. Add a case to the enum, or change a path, and the shell copy silently stops
    /// mirroring: the experiment could then stage over something the product no longer treats as
    /// regenerable, or refuse a target the product does allow. Nothing else checks it.
    func testTheE6bTargetAllowlistStillMirrorsTheHelpersCleanupTargets() throws {
        let common = try String(contentsOfFile: experimentsDirectory + "/common.sh", encoding: .utf8)
        guard
            let body = common.range(of: "xcv_e6b_target() {").map({ String(common[$0.upperBound...]) })?
                .components(separatedBy: "\n}").first
        else { return XCTFail("xcv_e6b_target is gone; this rule and the E6b scripts need updating together") }

        // Every absolute path the shell function can print.
        let shellPaths = Set(
            body.components(separatedBy: "printf ")
                .dropFirst()
                .compactMap { chunk -> String? in
                    guard let open = chunk.firstIndex(of: "'"),
                        let close = chunk[chunk.index(after: open)...].firstIndex(of: "'")
                    else { return nil }
                    return String(chunk[chunk.index(after: open)..<close])
                }
                .filter { $0.hasPrefix("/") })

        let helperPaths = Set(HelperCleanupTarget.allCases.map(\.path))
        XCTAssertFalse(shellPaths.isEmpty, "parsed no paths out of xcv_e6b_target — the parser, not the set, is what broke")
        XCTAssertEqual(
            shellPaths, helperPaths,
            "the E6b allowlist and HelperCleanupTarget have drifted. The scripts mount over these paths under sudo, "
                + "so the shell set must not name one the helper would refuse, nor miss one it allows.")
    }
}
