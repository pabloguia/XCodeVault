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
    }

    func testTheLogKeepsTheNewestLinesAndCountsTheRest() {
        var log = OperationLog(limit: 3)
        for i in 1...5 { log.append(LogLine(.stdout, "l\(i)")) }
        XCTAssertEqual(log.lines.map(\.text), ["l3", "l4", "l5"])
        XCTAssertEqual(log.droppedCount, 2)
        XCTAssertEqual(log.text, "[2 earlier lines not kept in memory]\nl3\nl4\nl5")
        XCTAssertEqual(log.total, 5, "the total keeps growing past the cap")
        XCTAssertEqual(log.text(fullLogAt: "/tmp/x.log"), "[2 earlier lines not kept in memory; the full log is at /tmp/x.log]\nl3\nl4\nl5")
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

    // MARK: - Review round 1

    func testTheLogDropsInChunksAndKeepsSequenceNumbersStable() {
        var log = OperationLog(limit: 100)
        for i in 0..<110 { log.append(LogLine(.stdout, "l\(i)")) }
        XCTAssertEqual(log.lines.count, 110, "within the slack nothing is dropped")
        log.append(LogLine(.stdout, "l110"))
        XCTAssertEqual(log.lines.count, 100)
        XCTAssertEqual(log.droppedCount, 11)
        XCTAssertEqual(log.total, 111)
        // Line n keeps the sequence number n: lines[i] is droppedCount + i.
        XCTAssertEqual(log.lines[0].text, "l\(log.droppedCount)")
        var bulk = OperationLog(limit: 100)
        bulk.append(contentsOf: (0..<500).map { LogLine(.stdout, "b\($0)") })
        XCTAssertEqual(bulk.total, 500)
        XCTAssertEqual(bulk.lines.last?.text, "b499")
        XCTAssertLessThanOrEqual(bulk.lines.count, 110)
    }

    /// A slow observer delays the run and changes nothing about its result (review L1: it must not block, and cannot
    /// alter results).
    func testASlowObserverDelaysButCannotAlterTheResult() throws {
        let script = ["-c", "printf 'a\\nb\\nc\\n'; exit 4"]
        let seen = Seen()
        let slow: LogObserver = { line in
            Thread.sleep(forTimeInterval: 0.05)
            seen.observer(line)
        }
        let r = try StreamingCommandRunner(observer: slow).run("/bin/sh", script)
        XCTAssertEqual(r, try ProcessCommandRunner().run("/bin/sh", script))
        XCTAssertEqual(seen.of(.stdout), ["a", "b", "c"])
    }

    /// Quitting (review M1): a stop terminates the running child, waits for it, and refuses every later launch.
    func testStoppingTerminatesTheChildWaitsAndRefusesLaterLaunches() throws {
        let children = ChildProcesses()
        let runner = StreamingCommandRunner(observer: { _ in }, children: children)
        let done = expectation(description: "the sleep returned")
        let box = Seen()
        DispatchQueue.global().async {
            let r = try? runner.run("/bin/sleep", ["30"])
            box.observer(LogLine(.exit, r.map { String($0.status) } ?? "threw"))
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while children.count == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(children.count, 1)
        let start = Date()
        XCTAssertTrue(children.stopAndWait(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "terminated, not waited out")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.of(.exit), ["15"], "SIGTERM's status, returned as a result the operation journals")
        XCTAssertEqual(children.count, 0)
        XCTAssertThrowsError(try runner.run("/bin/echo", ["late"])) { error in
            XCTAssertNil((error as? CommandError)?.result, "a refused launch never started")
        }
    }

    func testWithoutAStopTheChildrenChangeNothing() throws {
        let children = ChildProcesses()
        let r = try StreamingCommandRunner(observer: { _ in }, children: children).run("/bin/echo", ["hi"])
        XCTAssertEqual(r, try ProcessCommandRunner().run("/bin/echo", ["hi"]))
        XCTAssertEqual(children.count, 0)
        XCTAssertFalse(children.isStopped)
    }

    func testLeftoverPartialCopiesFollowTheEnginesRule() {
        func e(_ id: String, _ seq: Int, _ state: JournalEntry.State, phase: String, paths: [String] = []) -> JournalEntry {
            JournalEntry(
                id: id, sequence: seq, timestamp: Date(), kind: .migration, state: state, summary: id, paths: paths, bytes: nil,
                detail: ["phase": phase], toolVersion: "t")
        }
        let entries = [
            e("failed", 1, .planned, phase: "PLAN", paths: ["/s", "/d-failed"]), e("failed", 2, .failed, phase: "FAILED"),
            e("gone", 3, .planned, phase: "PLAN", paths: ["/s", "/d-gone"]), e("gone", 4, .failed, phase: "FAILED"),
            e("verified", 5, .planned, phase: "PLAN", paths: ["/s", "/d-verified"]), e("verified", 6, .completed, phase: "VERIFIED"),
            e("cleanup", 7, .planned, phase: "PLAN", paths: ["/s", "/d-cleanup"]), e("cleanup", 8, .failed, phase: "VERIFIED"),
        ]
        let present: (String) -> Bool = { $0 != "/d-gone" }
        XCTAssertEqual(MigrationRecovery.leftoverPartialCopies(entries, mayBePresent: present).map(\.id), ["failed"])
    }

    // MARK: - copyAndVerify and offload journal the same through an observer (review L2)

    /// `ditto` played by FileManager: the source's contents copied into the existing destination.
    struct CopyingRunner: CommandRunning {
        func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
            guard executable == Tools.ditto, arguments.count == 2 else { return CommandResult(status: 127, stdout: "", stderr: "unexpected") }
            for name in try FileManager.default.contentsOfDirectory(atPath: arguments[0]) {
                try FileManager.default.copyItem(atPath: arguments[0] + "/" + name, toPath: arguments[1] + "/" + name)
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
    }

    func testCopyAndVerifyJournalsTheSameThroughAnObserver() throws {
        let t = TempDir()
        t.file("src/a.xcarchive/Info.plist", bytes: 300)
        t.file("src/b.xcarchive/Products/app", bytes: 4_000)
        let seen = Seen()
        func one(_ name: String, wrap: Bool) throws -> (MigrationOutcome, [String]) {
            let url = URL(fileURLWithPath: t.path + "/\(name).jsonl")
            let runner: CommandRunning = wrap ? ObservingCommandRunner(CopyingRunner(), observer: seen.observer) : CopyingRunner()
            let engine = MigrationEngine(
                runner: runner, journal: Journal(url: url), home: t.path, isXcodeRunning: { false }, volumeUUIDAt: { _ in "VAULT-UUID" })
            let plan = MigrationPlan(
                operationID: UUID().uuidString, direction: .externalize, categoryID: "archives", source: t.path + "/src",
                destination: t.path + "/\(name)/archives/src", vaultUUID: "VAULT-UUID", sourceBytes: 4_300, sourceFiles: 2, deepVerify: true,
                warnings: [])
            let outcome = try engine.copyAndVerify(plan)
            return (outcome, try shape(url).map { $0.replacingOccurrences(of: "/\(name)/", with: "/X/") })
        }
        let (plainOutcome, plainJournal) = try one("plain", wrap: false)
        let (observedOutcome, observedJournal) = try one("observed", wrap: true)
        XCTAssertEqual(observedJournal, plainJournal)
        XCTAssertEqual(plainJournal.count, 4, "PLAN, COPY, VERIFY, VERIFIED")
        XCTAssertEqual(observedOutcome.verification, plainOutcome.verification)
        XCTAssertFalse(observedOutcome.sourceRemoved)
        XCTAssertEqual(seen.of(.command), ["/usr/bin/ditto \(t.path)/src \(t.path)/observed/archives/src"])
        XCTAssertEqual(seen.of(.exit), ["0"])
    }

    func testOffloadJournalsTheSameThroughAnObserver() throws {
        let t = TempDir()
        let library = t.dir("lib")
        let installer = RuntimeInstaller(
            path: library + "/iphonesimulator_26.5_23F77.dmg", fileName: "iphonesimulator_26.5_23F77.dmg", sizeBytes: 900_000_000, modifiedAt: Date(),
            platform: "iOS", version: "26.5", build: "23F77")
        let runtime = SimulatorRuntime(
            identifier: "RT", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", platformIdentifier: "com.apple.platform.iphonesimulator",
            version: "26.5", build: "23F77", sizeBytes: 1_000)
        let ok = [
            "hdiutil imageinfo": CommandResult(status: 0, stdout: "Format: UDZO\n", stderr: ""),
            "xcrun simctl runtime delete RT": CommandResult(status: 0, stdout: "", stderr: ""),
        ]
        let (plain, observed, seen) = try twice(ok) { runner, journal in
            let ops = RuntimeOperations(runner: runner, journal: journal, xcode: xcode(), host: host())
            let (plan, _) = try ops.preflightOffload(
                identifier: "RT", library: library, installedRuntimes: [runtime], isMountPoint: { _ in true }, listLibrary: { _ in [installer] },
                imageIsReadable: { _ in true }, volumeUUIDAt: { _ in "VAULT-UUID" })
            return try ops.offload(
                plan, confirmedByUser: .explicitUserIntent(recordedAs: "test"), volumeUUIDAt: { _ in "VAULT-UUID" }, isMountPoint: { _ in true })
        }
        XCTAssertNotNil(plain.0)
        XCTAssertEqual(observed.0, plain.0)
        XCTAssertEqual(observed.1, plain.1)
        XCTAssertEqual(plain.1.count, 4, "offload started, delete started and completed, offload completed")
        XCTAssertEqual(observed.2, plain.2)
        XCTAssertEqual(seen.of(.command).count, 2, "hdiutil, then simctl")
    }

    // MARK: - Final round: failures always journaled, stop never outlives the app

    /// L-A: a runtime delete that cannot start records `failed`, not a `started` left open.
    func testARefusedRuntimeDeleteLaunchIsJournaledAsFailed() throws {
        let t = TempDir()
        let url = URL(fileURLWithPath: t.path + "/j.jsonl")
        let runner = RecordingRunner()
        runner.unstartable = ["xcrun simctl runtime delete"]
        let ops = RuntimeOperations(runner: runner, journal: Journal(url: url), xcode: xcode(), host: host())
        XCTAssertThrowsError(try ops.delete(identifier: "RT"))
        XCTAssertEqual(try Journal(url: url).entries().map(\.state), [.started, .failed])
        XCTAssertEqual(try Journal(url: url).interrupted(), [], "nothing is left looking in flight")
        // A dry run journals nothing, refused or not.
        XCTAssertThrowsError(try ops.delete(identifier: "RT", dryRun: true))
        XCTAssertEqual(try Journal(url: url).entries().count, 2)
    }

    /// L-A: a Locations write that cannot start records `failed`; a read that cannot run records no `previous`.
    func testARefusedLocationsLaunchIsJournaledAsFailedAndClaimsNoPrevious() throws {
        let t = TempDir()
        let url = URL(fileURLWithPath: t.path + "/j.jsonl")
        let runner = RecordingRunner()
        runner.unstartable = ["defaults"]
        XCTAssertThrowsError(try XcodeLocations.apply(.init(key: .derivedData, newValue: "/x"), runner: runner, journal: Journal(url: url)))
        let entries = try Journal(url: url).entries()
        XCTAssertEqual(entries.map(\.state), [.started, .failed])
        XCTAssertNil(entries.first?.detail["previous"], "an unread previous value is not recorded as the default")
        XCTAssertEqual(entries.first?.detail["new"], "/x")

        // A read that ran and found no value still records the default, as before.
        let url2 = URL(fileURLWithPath: t.path + "/j2.jsonl")
        let ok = RecordingRunner(responses: [
            "defaults read": CommandResult(status: 1, stdout: "", stderr: "does not exist"),
            "defaults write": CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        try XcodeLocations.apply(.init(key: .derivedData, newValue: "/x"), runner: ok, journal: Journal(url: url2))
        XCTAssertEqual(try Journal(url: url2).entries().first?.detail["previous"], "")
    }

    /// L-B: a child that ignores SIGTERM is not waited out: SIGKILL ends it.
    func testAChildIgnoringSIGTERMIsKilled() throws {
        let children = ChildProcesses()
        let runner = StreamingCommandRunner(observer: { _ in }, children: children)
        let done = expectation(description: "returned")
        let box = Seen()
        DispatchQueue.global().async {
            let r = try? runner.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"])
            box.observer(LogLine(.exit, r.map { String($0.status) } ?? "threw"))
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while children.count == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.2)  // the trap is set before `exec`
        XCTAssertFalse(children.stopAndWait(timeout: 0.5), "SIGTERM is ignored")
        XCTAssertTrue(children.killAndWait(timeout: 5))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.of(.exit), ["9"])
        XCTAssertEqual(children.count, 0)
    }
}
