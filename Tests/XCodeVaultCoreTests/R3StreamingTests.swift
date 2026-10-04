import Foundation
import XCTest

@testable import XCodeVaultCore

/// What R3 added to Core: a runner that streams each output line to an observer, a decorator that reports any runner's
/// commands, and the pure decisions behind the sheet (stage, progress, the capped log, the recovery banner). The
/// existing operations take no new parameter: an observer reaches them only as their `runner`, so these tests check
/// that a run through an observing runner journals exactly what a plain run journals and returns the same result.
/// No test here runs ditto, simctl, xcodebuild or defaults: the only real processes are `/bin/sh` and `/bin/echo`.
final class R3StreamingTests: XCTestCase {
    /// Lines an observer saw, in order, from any thread.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [LogLine] = []
        var lines: [LogLine] { lock.withLock { _lines } }
        var observer: LogObserver { { line in self.lock.withLock { self._lines.append(line) } } }
        func of(_ stream: LogLine.Stream) -> [String] { lines.filter { $0.stream == stream }.map(\.text) }
    }

    // MARK: - LineSplitter

    func testTheSplitterHandlesEveryLineEndingAndKeepsAPartialLine() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(Data("a\nb\r\nc\rd".utf8)), ["a", "b", "c"])
        XCTAssertEqual(s.feed(Data("e\n".utf8)), ["de"], "the partial line waits for its end")
        XCTAssertEqual(s.feed(Data("x\r".utf8)), ["x"])
        XCTAssertEqual(s.feed(Data("\ny".utf8)), [], "the \\n of a \\r\\n split across reads ends nothing")
        XCTAssertEqual(s.finish(), "y")
        XCTAssertNil(s.finish())
    }

    func testTheSplitterDecodesACharacterCutAcrossReads() {
        var s = LineSplitter()
        let bytes = Array("é\n".utf8)  // 0xC3 0xA9 0x0A
        XCTAssertEqual(s.feed(Data(bytes[0..<1])), [])
        XCTAssertEqual(s.feed(Data(bytes[1...])), ["é"])
    }

    // MARK: - StreamingCommandRunner

    func testTheStreamingRunnerReturnsWhatTheProcessRunnerReturns() throws {
        let script = ["-c", "printf 'one\\ntwo\\nlast'; printf 'oops\\n' >&2; exit 3"]
        let plain = try ProcessCommandRunner().run("/bin/sh", script)
        let seen = Seen()
        let streamed = try StreamingCommandRunner(observer: seen.observer).run("/bin/sh", script)
        XCTAssertEqual(streamed, plain, "the same result, byte for byte")
        XCTAssertEqual(streamed.status, 3)
        XCTAssertEqual(seen.of(.command), ["/bin/sh -c 'printf '\\''one\\ntwo\\nlast'\\''; printf '\\''oops\\n'\\'' >&2; exit 3'"])
        XCTAssertEqual(seen.of(.stdout), ["one", "two", "last"])
        XCTAssertEqual(seen.of(.stderr), ["oops"])
        XCTAssertEqual(seen.of(.exit), ["3"])
        XCTAssertEqual(seen.lines.first?.stream, .command, "the command line comes before anything it prints")
        XCTAssertEqual(seen.lines.last?.stream, .exit, "and the exit after")
    }

    func testTheStreamingRunnerPassesTheEnvironmentAsTheProcessRunnerDoes() throws {
        let args = ["-c", "printf '%s' \"$XCV_R3\""]
        let env = ["XCV_R3": "value"]
        let streamed = try StreamingCommandRunner(observer: { _ in }).run("/bin/sh", args, environment: env)
        XCTAssertEqual(streamed, try ProcessCommandRunner().run("/bin/sh", args, environment: env))
        XCTAssertEqual(streamed.stdout, "value")
    }

    func testTheStreamingRunnerDrainsLargeOutputWithoutDeadlock() throws {
        let script = ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i; echo err$i >&2; i=$((i+1)); done"]
        let seen = Seen()
        let streamed = try StreamingCommandRunner(observer: seen.observer).run("/bin/sh", script)
        XCTAssertEqual(streamed, try ProcessCommandRunner().run("/bin/sh", script))
        XCTAssertEqual(seen.of(.stdout).count, 20_000)
        XCTAssertEqual(seen.of(.stderr).count, 20_000)
        XCTAssertEqual(seen.of(.stdout).last, "line19999")
    }

    func testALaunchFailureThrowsTheSameErrorAsTheProcessRunner() {
        let missing = "/nonexistent/xcv-r3-tool"
        var plain: CommandError?
        var streamed: CommandError?
        XCTAssertThrowsError(try ProcessCommandRunner().run(missing, ["a"])) { plain = $0 as? CommandError }
        XCTAssertThrowsError(try StreamingCommandRunner(observer: { _ in }).run(missing, ["a"])) { streamed = $0 as? CommandError }
        XCTAssertNotNil(plain)
        XCTAssertEqual(streamed?.description, plain?.description)
        XCTAssertNil(streamed?.result)
    }

    // MARK: - ObservingCommandRunner

    func testTheObservingRunnerReturnsTheBaseResultAndReportsIt() throws {
        let base = RecordingRunner(responses: ["echo hi": CommandResult(status: 0, stdout: "a\nb\n", stderr: "w\n")])
        let seen = Seen()
        let r = try ObservingCommandRunner(base, observer: seen.observer).run("/bin/echo", ["hi", "two words"], environment: ["K": "V"])
        XCTAssertEqual(r, CommandResult(status: 0, stdout: "a\nb\n", stderr: "w\n"))
        XCTAssertEqual(base.calls, [RecordingRunner.Call(executable: "/bin/echo", arguments: ["hi", "two words"], environment: ["K": "V"])])
        XCTAssertEqual(seen.lines.map(\.rendered), ["$ /bin/echo hi 'two words'", "a", "b", "! w", "[exit 0]"])
    }

    func testTheObservingRunnerRethrowsTheBaseError() {
        let base = RecordingRunner()
        base.unstartable = ["echo"]
        let seen = Seen()
        XCTAssertThrowsError(try ObservingCommandRunner(base, observer: seen.observer).run("/bin/echo", ["x"])) { error in
            XCTAssertTrue(error is CommandError)
        }
        XCTAssertEqual(seen.of(.command), ["/bin/echo x"])
        XCTAssertTrue(seen.of(.exit).isEmpty, "a command that never ran has no exit status")
    }

    // MARK: - The operations journal the same through an observer

    private func xcode() -> XcodeInstallation {
        var caps = XcodeCapabilities()
        caps.simctlRuntimeDelete = true
        caps.downloadPlatform = true
        caps.exportPath = true
        return XcodeInstallation(
            path: "/Applications/Xcode.app", developerDirectory: "/Applications/Xcode.app/Contents/Developer", version: "26.5", build: "17F42",
            isSelected: true, capabilities: caps)
    }

    private func host() -> HostEnvironment {
        HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "x", architecture: "x86_64", homeDirectory: "/tmp", dataVolumeFreeBytes: 1 << 40,
            dataVolumeTotalBytes: 1 << 41, userName: "t", isRoot: false)
    }

    /// The journal without what differs between two runs by construction: ids, times and sequence numbers.
    private func shape(_ url: URL) throws -> [String] {
        try Journal(url: url).entries().map { "\($0.kind.rawValue) \($0.state.rawValue) \($0.summary) \($0.paths) \($0.detail.sorted { $0.key < $1.key })" }
    }

    /// Runs `body` twice — once with the plain runner, once with it wrapped — and returns both journals and results.
    private func twice<T: Equatable>(
        _ responses: [String: CommandResult], _ body: (CommandRunning, Journal) throws -> T
    ) throws -> (plain: (T?, [String], [String]), observed: (T?, [String], [String]), seen: Seen) {
        let t = TempDir()
        let seen = Seen()
        func one(_ name: String, wrap: Bool) throws -> (T?, [String], [String]) {
            let url = URL(fileURLWithPath: t.path + "/\(name).jsonl")
            let base = RecordingRunner(responses: responses)
            let runner: CommandRunning = wrap ? ObservingCommandRunner(base, observer: seen.observer) : base
            let value = try? body(runner, Journal(url: url))
            return (value, try shape(url), base.invocations)
        }
        return (try one("plain", wrap: false), try one("observed", wrap: true), seen)
    }

    func testRuntimeDeleteJournalsTheSameThroughAnObserver() throws {
        let ok = ["xcrun simctl runtime delete RT": CommandResult(status: 0, stdout: "Deleted\n", stderr: "")]
        let (plain, observed, seen) = try twice(ok) { runner, journal in
            try RuntimeOperations(runner: runner, journal: journal, xcode: xcode(), host: host()).delete(identifier: "RT")
        }
        XCTAssertNotNil(plain.0)
        XCTAssertEqual(observed.0, plain.0)
        XCTAssertEqual(observed.1, plain.1)
        XCTAssertEqual(observed.2, plain.2, "the same commands, in the same order")
        XCTAssertEqual(plain.1.count, 2)
        XCTAssertEqual(seen.lines.map(\.rendered), ["$ /usr/bin/xcrun simctl runtime delete RT", "Deleted", "[exit 0]"])

        let failing = ["xcrun simctl runtime delete RT": CommandResult(status: 1, stdout: "", stderr: "busy\n")]
        let (p2, o2, _) = try twice(failing) { runner, journal in
            try RuntimeOperations(runner: runner, journal: journal, xcode: xcode(), host: host()).delete(identifier: "RT")
        }
        XCTAssertNil(p2.0)
        XCTAssertNil(o2.0, "a failure stays a failure")
        XCTAssertEqual(o2.1, p2.1)
    }

    func testRuntimeExportJournalsTheSameThroughAnObserver() throws {
        let ok = ["xcodebuild -downloadPlatform iOS": CommandResult(status: 0, stdout: "Downloading\n50%\rDone\n", stderr: "")]
        let req = RuntimeOperations.ExportRequest(platform: "iOS", destination: "/tmp/lib")
        let (plain, observed, seen) = try twice(ok) { runner, journal in
            try RuntimeOperations(runner: runner, journal: journal, xcode: xcode(), host: host()).export(req)
        }
        XCTAssertNotNil(plain.0)
        XCTAssertEqual(observed.0, plain.0)
        XCTAssertEqual(observed.1, plain.1)
        XCTAssertEqual(observed.2, plain.2)
        XCTAssertEqual(seen.of(.stdout), ["Downloading", "50%", "Done"])
        XCTAssertEqual(
            seen.of(.command), ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadPlatform iOS -exportPath /tmp/lib"])
    }

    func testALocationChangeJournalsTheSameThroughAnObserver() throws {
        let ok = [
            "defaults read": CommandResult(status: 0, stdout: "/old\n", stderr: ""),
            "defaults write": CommandResult(status: 0, stdout: "", stderr: ""),
        ]
        let change = XcodeLocations.Change(key: .derivedData, newValue: "/Volumes/V/DD")
        let (plain, observed, seen) = try twice(ok) { runner, journal in
            try XcodeLocations.apply(change, runner: runner, journal: journal)
            return true
        }
        XCTAssertEqual(plain.0, true)
        XCTAssertEqual(observed.0, true)
        XCTAssertEqual(observed.1, plain.1)
        XCTAssertEqual(observed.2, plain.2)
        XCTAssertEqual(
            seen.of(.command),
            [
                "/usr/bin/defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation",
                "/usr/bin/defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string /Volumes/V/DD",
            ])
    }

    // MARK: - Stage, progress, log, recovery

    func testOnlyACommandExitingZeroWhileCopyingMovesTheStage() {
        XCTAssertEqual(OperationStage.after(LogLine(.exit, "0"), from: .copying), .verifying)
        XCTAssertEqual(OperationStage.after(LogLine(.exit, "1"), from: .copying), .copying, "a failed copy is not verifying")
        XCTAssertEqual(OperationStage.after(LogLine(.stdout, "0"), from: .copying), .copying)
        XCTAssertEqual(OperationStage.after(LogLine(.command, "/usr/bin/ditto a b"), from: .copying), .copying)
        for stage in OperationStage.allCases where stage != .copying {
            XCTAssertEqual(OperationStage.after(LogLine(.exit, "0"), from: stage), stage, "\(stage)")
        }
    }

    func testTheFractionIsClampedAndNeedsATotal() {
        XCTAssertEqual(OperationProgress.fraction(done: 50, total: 200), 0.25)
        XCTAssertEqual(OperationProgress.fraction(done: 300, total: 200), 1)
        XCTAssertNil(OperationProgress.fraction(done: 1, total: 0))
        XCTAssertNil(OperationProgress.fraction(done: nil, total: 10))
        XCTAssertNil(OperationProgress.fraction(done: 1, total: nil))
        XCTAssertEqual(OperationProgress.added(baseline: 100, current: 160), 60)
        XCTAssertEqual(OperationProgress.added(baseline: 100, current: 40), 0)
        XCTAssertEqual(OperationProgress.added(baseline: nil, current: 40), 40)
        XCTAssertNil(OperationProgress.added(baseline: 1, current: nil))
    }

    func testTheLogKeepsTheNewestLinesAndCountsTheRest() {
        var log = OperationLog(limit: 3)
        for i in 1...5 { log.append(LogLine(.stdout, "l\(i)")) }
        XCTAssertEqual(log.lines.map(\.text), ["l3", "l4", "l5"])
        XCTAssertEqual(log.droppedCount, 2)
        XCTAssertEqual(log.text, "[2 earlier lines not kept in memory]\nl3\nl4\nl5")
        XCTAssertEqual(OperationLog().limit, 5_000)
        var short = OperationLog()
        short.append(LogLine(.command, "/usr/bin/ditto a b"))
        XCTAssertEqual(short.text, "$ /usr/bin/ditto a b")
    }

    private func entry(_ id: String, _ seq: Int, _ state: JournalEntry.State, kind: JournalEntry.Kind = .migration, phase: String? = nil) -> JournalEntry {
        JournalEntry(
            id: id, sequence: seq, timestamp: Date(timeIntervalSince1970: Double(seq)), kind: kind, state: state, summary: "s", paths: [],
            bytes: nil, detail: phase.map { ["phase": $0] } ?? [:], toolVersion: "t")
    }

    func testTheBannerListsInterruptedMigrationsOnly() {
        let entries = [
            entry("copying", 1, .planned, phase: "PLAN"), entry("copying", 2, .started, phase: "COPY"),
            entry("done", 3, .started, phase: "COPY"), entry("done", 4, .completed, phase: "VERIFIED"),
            entry("export", 5, .started, kind: .runtimeExport),
            entry("planned", 6, .planned, phase: "PLAN"),
            entry("running", 7, .started, phase: "COPY"),
        ]
        XCTAssertEqual(MigrationRecovery.interrupted(entries, running: ["running"]).map(\.id), ["copying"])
        XCTAssertEqual(MigrationRecovery.interrupted(entries).map(\.id), ["copying", "running"])
        // Same rule as the journal's own reader.
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        for e in entries { _ = try? journal.append(e) }
        XCTAssertEqual(
            Set((try? journal.interrupted())?.filter { $0.kind == .migration }.map(\.id) ?? []), Set(MigrationRecovery.interrupted(entries).map(\.id)))
    }

    func testTheRecoveryCommandIsTheOneCoreAcceptsAtThatPhase() {
        let beforeVerify = [entry("A", 1, .planned, phase: "PLAN"), entry("A", 2, .started, phase: "COPY")]
        XCTAssertEqual(MigrationRecovery.commands(for: "A", in: beforeVerify), ["xcodevaultctl migration status", "xcodevaultctl migration abort A"])
        let cleanup = [entry("B", 1, .completed, phase: "VERIFIED"), entry("B", 2, .started, phase: "CLEANUP")]
        XCTAssertEqual(MigrationRecovery.commands(for: "B", in: cleanup), ["xcodevaultctl migration status", "xcodevaultctl migration resume B"])
        let verifiedOnly = [entry("C", 1, .completed, phase: "VERIFIED"), entry("C", 2, .started)]
        XCTAssertEqual(MigrationRecovery.commands(for: "C", in: verifiedOnly), ["xcodevaultctl migration status"])
        XCTAssertFalse(
            MigrationRecovery.commands(for: "B", in: cleanup).joined().contains("--i-confirm"),
            "the deletion's confirmation is typed by the user, never put in a copied command")
    }
}
