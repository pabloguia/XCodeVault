import Foundation
import XCTest

@testable import XCodeVaultCore

/// What every tool the app starts inherits (helper-security review of deliverable 3, F3), measured on real
/// children: `/usr/bin/env`, started both ways `ProcessCommandRunner` starts a process.
final class GrantedToolEnvironmentTests: XCTestCase {
    /// Written out rather than read from `GrantedToolEnvironment.removed`, so dropping a name there fails here.
    private let steering = ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"]
    private var saved: [(name: String, value: String?)] = []

    override func setUp() {
        super.setUp()
        let env = ProcessInfo.processInfo.environment
        saved = (steering + ["PATH"]).map { ($0, env[$0]) }
    }

    override func tearDown() {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        super.tearDown()
    }

    private func child(extraEnvironment: Bool) throws -> [String: String] {
        let r = try ProcessCommandRunner().run("/usr/bin/env", [], environment: extraEnvironment ? ["XCV_EXTRA": "1"] : nil)
        var env: [String: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }

    func testEveryChildInheritsTheEnvironmentWithoutWhatSteersXcrun() throws {
        for name in steering { setenv(name, "/xcv-sentinel/\(name)", 1) }
        setenv("PATH", "/xcv-sentinel/bin:/usr/bin:/bin", 1)
        // Positive control: before the environment is applied a child does see the sentinels, so their absence
        // below is the rule working, not the child failing to inherit anything.
        let before = try child(extraEnvironment: false)
        for name in steering { XCTAssertEqual(before[name], "/xcv-sentinel/\(name)") }
        XCTAssertEqual(before["PATH"], "/xcv-sentinel/bin:/usr/bin:/bin")

        GrantedToolEnvironment.applyToThisProcess()

        for extra in [false, true] {
            let env = try child(extraEnvironment: extra)
            XCTAssertEqual(env["XCV_EXTRA"], extra ? "1" : nil, "the child ran with the environment it was given")
            for name in steering { XCTAssertNil(env[name], "\(name) (extra environment: \(extra))") }
            XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "extra environment: \(extra)")
        }
    }
}

/// Discovery runs tools only from the Xcode `xcode-select` names (F3; ADR-0009). A bundle is accepted on its
/// Info.plist alone, and anything named `Xcode*.app` in /Applications or ~/Applications is a candidate, so any
/// process of the user can put one there; the app's scan runs nothing from any of them.
final class XcodeCapabilityExecutionTests: XCTestCase {
    /// A folder that passes `XcodeDiscovery.inspect`: the name and the Info.plist are all it checks.
    private func fakeXcode(in t: TempDir, name: String = "Xcode-probe.app") -> String {
        let app = t.dir("Applications/" + name)
        t.dir("Applications/" + name + "/Contents/Developer/usr/bin")
        let info: NSDictionary = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "99.0"]
        XCTAssertTrue(info.write(toFile: app + "/Contents/Info.plist", atomically: true))
        return app
    }

    private func selecting(_ developerDir: String) -> [String: CommandResult] {
        ["xcode-select -p": CommandResult(status: 0, stdout: developerDir + "\n", stderr: "")]
    }

    func testDiscoveryWithoutCapabilitiesRunsOnlyXcodeSelect() {
        let t = TempDir()
        let app = fakeXcode(in: t)
        let runner = RecordingRunner()
        let found = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: false)
        // Positive control: the bundle was accepted, so "nothing ran from it" is not "nothing was found".
        XCTAssertEqual(found.map(\.path), [app])
        XCTAssertEqual(runner.invocations, ["xcode-select -p"])
    }

    /// The selected Xcode and one planted beside it. `calls` keeps full paths and environments, so which bundle ran
    /// is visible: `xcodebuild` is started by path, and `xcrun` runs whatever `DEVELOPER_DIR` points into.
    func testOnlyTheSelectedXcodesToolsRun() {
        let t = TempDir()
        let selected = fakeXcode(in: t, name: "Xcode.app")
        let planted = fakeXcode(in: t, name: "Xcode-planted.app")
        var responses = selecting(selected + "/Contents/Developer")
        responses["xcodebuild -help"] = CommandResult(status: 0, stdout: Fixtures.string("xcodebuild-help-xcode26.5.txt"), stderr: "")
        let runner = RecordingRunner(responses: responses)
        let found = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: true)
        XCTAssertEqual(Set(found.map(\.path)), [selected, planted], "both bundles were found")
        let calls = runner.calls
        // Positive control: the selected Xcode's tools ran, so the planted one's absence below is the rule at work.
        XCTAssertTrue(calls.contains { $0.executable == selected + "/Contents/Developer/usr/bin/xcodebuild" && $0.arguments == ["-help"] }, "\(calls)")
        XCTAssertTrue(
            calls.contains { $0.executable == Tools.xcrun && $0.environment?["DEVELOPER_DIR"] == selected + "/Contents/Developer" }, "\(calls)")
        XCTAssertEqual(found.first { $0.path == selected }?.capabilities.downloadPlatform, true, "the selected Xcode's own help was read")
        XCTAssertEqual(found.first { $0.path == selected }?.capabilitiesProbed, true)
        XCTAssertEqual(found.first { $0.path == planted }?.capabilitiesProbed, false, "not probed, which is not 'absent'")
        // What discovery calls selected is what the `runtime` verbs run (`Runtime.selected`).
        XCTAssertEqual(found.first { $0.path == selected }?.isSelected, true)
        XCTAssertEqual(found.first { $0.path == planted }?.isSelected, false)
        // Nothing from the planted bundle, started by path or through `xcrun`.
        XCTAssertFalse(calls.contains { $0.executable.hasPrefix(planted + "/") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.environment?["DEVELOPER_DIR"]?.hasPrefix(planted + "/") == true }, "\(calls)")
    }

    /// No Xcode selected: the Command Line Tools are, or `xcode-select` gave no answer. No bundle's tools run.
    func testNoBundlesToolsRunWhenNoXcodeIsSelected() {
        for answer in [selecting("/Library/Developer/CommandLineTools"), [:]] {
            let t = TempDir()
            let app = fakeXcode(in: t)
            let runner = RecordingRunner(responses: answer)
            let found = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: true)
            // Positive control: the bundle was found, so "nothing ran from it" is the rule, not an empty search.
            XCTAssertEqual(found.map(\.path), [app])
            XCTAssertEqual(runner.invocations, ["xcode-select -p"], "xcode-select answered \(answer)")
            XCTAssertEqual(found.map(\.capabilitiesProbed), [false])
            XCTAssertEqual(found.map(\.isSelected), [false])
        }
    }

    /// `xcode-select -p` echoes `DEVELOPER_DIR` as it is set, a trailing space included, and `xcrun` refuses that
    /// path (both measured 2026-09-28). The answer is taken as printed, less its newline, so no Xcode is selected
    /// either: trimming the space would run the tools of an Xcode the user's own `xcrun` would not.
    func testAnAnswerXcrunWouldRefuseSelectsNoXcode() {
        // Positive control first: the same bundle, answered without the space, is selected and probed.
        for (suffix, selected) in [("", true), (" ", false)] {
            let t = TempDir()
            let app = fakeXcode(in: t)
            let runner = RecordingRunner(responses: selecting(app + "/Contents/Developer" + suffix))
            let found = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: true)
            XCTAssertEqual(found.map(\.path), [app], "answer suffix '\(suffix)'")
            XCTAssertEqual(found.map(\.isSelected), [selected], "answer suffix '\(suffix)'")
            XCTAssertEqual(runner.invocations.contains("xcodebuild -help"), selected, "\(runner.invocations)")
        }
    }

    /// "Probed" means the selected Xcode's `xcodebuild -help` ran. When it cannot be started, the flags are not a
    /// measurement, and `xcode list` would show a ✗ for each (helper-security review of F3, round 1).
    func testASelectedXcodeWhoseXcodebuildCannotStartIsNotProbed() {
        let t = TempDir()
        let app = fakeXcode(in: t)
        for startable in [true, false] {
            let runner = RecordingRunner(responses: selecting(app + "/Contents/Developer"))
            if !startable { runner.unstartable = ["xcodebuild -help"] }
            let found = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: true)
            // Positive control: the selected Xcode's xcodebuild was attempted both times.
            XCTAssertTrue(runner.calls.contains { $0.executable == app + "/Contents/Developer/usr/bin/xcodebuild" }, "\(runner.calls)")
            XCTAssertEqual(found.map(\.isSelected), [true])
            XCTAssertEqual(found.map(\.capabilitiesProbed), [startable], "xcodebuild startable: \(startable)")
        }
    }

    /// The scanner passes its flag through. The bundle is offered as `xcode-select`'s answer, so the result does
    /// not depend on what this machine has in /Applications.
    func testTheScannerPassesTheFlagThrough() throws {
        let t = TempDir()
        let app = fakeXcode(in: t)
        for detect in [false, true] {
            let runner = RecordingRunner(responses: ["xcode-select -p": CommandResult(status: 0, stdout: app + "/Contents/Developer\n", stderr: "")])
            let report = XCodeVaultCore.Scanner(
                runner: runner, home: "/nonexistent", catalog: [StorageCatalog.category("derivedData")!], measureSizes: false,
                detectXcodeCapabilities: detect
            ).scan()
            XCTAssertTrue(report.xcodes.contains { $0.path == app }, "the probe bundle was found (detect: \(detect))")
            XCTAssertEqual(runner.invocations.contains("xcodebuild -help"), detect, "\(runner.invocations)")
            XCTAssertEqual(runner.invocations.contains("xcrun simctl runtime"), detect, "\(runner.invocations)")
            XCTAssertEqual(report.xcodes.first { $0.path == app }?.capabilitiesProbed, detect)
            // This bundle's line only: any Xcode this machine has in /Applications is found too, and is not probed.
            let line = try XCTUnwrap(TextRenderer.scan(report).split(separator: "\n").first { $0.contains("  \(app)  [") })
            XCTAssertEqual(line.contains("capabilities not probed"), !detect, String(line))
        }
    }
}

/// The app target has no tests, so what F3 needs from it is pinned in its source, the way
/// `CLIExperimentalLabelTests` pins the CLI's help: the scan the app runs detects no capabilities, and the tool
/// environment is applied in the app's initializer — the first tool runs later, from the window's task.
final class AppGrantedToolWiringTests: XCTestCase {
    private func appCode() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("Sources/XCodeVault/XCodeVaultApp.swift"), encoding: .utf8)
        // Comment lines dropped: a comment naming the call must not satisfy the pin.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testEveryScannerTheAppBuildsDetectsNoCapabilities() throws {
        let code = try appCode()
        let calls = try NSRegularExpression(pattern: #"Scanner\(([^)]*)\)"#)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range(at: 1), in: code).map { String(code[$0]) } }
        XCTAssertFalse(calls.isEmpty, "the app builds no Scanner any more; this pin is stale")
        for args in calls { XCTAssertTrue(args.contains("detectXcodeCapabilities: false"), "Scanner(\(args))") }
    }

    func testTheAppAppliesTheToolEnvironmentInItsInitializer() throws {
        let code = try appCode()
        let start = try XCTUnwrap(code.range(of: "struct XCodeVaultApp: App {"))
        let end = try XCTUnwrap(code.range(of: "var body: some Scene", range: start.upperBound..<code.endIndex))
        let beforeBody = code[start.upperBound..<end.lowerBound]
        let initializer = try XCTUnwrap(beforeBody.range(of: "init() {"), String(beforeBody))
        XCTAssertTrue(beforeBody[initializer.upperBound...].contains("GrantedToolEnvironment.applyToThisProcess()"), String(beforeBody))
    }
}
