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

/// The app's scan runs nothing from a discovered Xcode bundle (F3). A bundle is accepted on its Info.plist
/// alone, and anything named `Xcode*.app` in /Applications or ~/Applications is a candidate.
final class XcodeCapabilityExecutionTests: XCTestCase {
    /// A folder that passes `XcodeDiscovery.inspect`: the name and the Info.plist are all it checks.
    private func fakeXcode(in t: TempDir) -> String {
        let app = t.dir("Applications/Xcode-probe.app")
        t.dir("Applications/Xcode-probe.app/Contents/Developer/usr/bin")
        let info: NSDictionary = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "99.0"]
        XCTAssertTrue(info.write(toFile: app + "/Contents/Info.plist", atomically: true))
        return app
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

    func testDiscoveryWithCapabilitiesRunsTheBundlesTools() {
        // The contrast: the CLI's default runs the bundle's own `xcodebuild`, and `simctl` with its developer
        // directory.
        let t = TempDir()
        _ = fakeXcode(in: t)
        let runner = RecordingRunner()
        _ = XcodeDiscovery.discover(runner: runner, searchRoots: [t.path + "/Applications"], detectCapabilities: true)
        XCTAssertEqual(runner.invocations, ["xcode-select -p", "xcodebuild -help", "xcrun simctl runtime"])
    }

    /// The scanner passes its flag through. The bundle is offered as `xcode-select`'s answer, so the result does
    /// not depend on what this machine has in /Applications.
    func testTheScannerPassesTheFlagThrough() {
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
