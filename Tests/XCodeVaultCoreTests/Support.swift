import Foundation
import XCTest

@testable import XCodeVaultCore

/// A `CommandRunning` that replays canned results keyed by executable basename + first args.
/// A `FakeRunner` that remembers what it was asked to run.
///
/// The plain `FakeRunner` below answers but records nothing, so a test can assert what a verb
/// *returned* and never what it *invoked*. A review used that gap to survive five mutations on
/// the offload path at once — `--dry-run` and `--keep-asset` silently appended to a 12 GB
/// deletion, and the `hdiutil` check pointed at the wrong file — all with a green suite.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    /// One command as it was started: the full executable path and the environment added to it.
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private let lock = NSLock()
    private var _invocations: [String] = []
    private var _calls: [Call] = []
    var responses: [String: CommandResult]
    /// Commands, matched as `responses` are, that cannot be started: `run` throws, as `ProcessCommandRunner` does
    /// when there is nothing to run at the path. The attempt is still recorded.
    var unstartable: [String] = []

    init(responses: [String: CommandResult] = [:]) { self.responses = responses }

    /// Every command as it would read on a command line, in order.
    var invocations: [String] { lock.withLock { _invocations } }
    /// The same commands with their full paths and environments, which `invocations` drops: two Xcodes'
    /// `xcodebuild` read the same there, and `DEVELOPER_DIR` decides which Xcode `xcrun` runs (F3).
    var calls: [Call] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        let key = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
        lock.withLock {
            _invocations.append(key)
            _calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        }
        for k in unstartable where key.hasPrefix(k) {
            throw CommandError(executable: executable, arguments: arguments, result: nil, underlying: "RecordingRunner: \(key) cannot be started")
        }
        for (k, v) in responses where key.hasPrefix(k) { return v }
        return CommandResult(status: 127, stdout: "", stderr: "RecordingRunner: no response for \(key)")
    }
}

struct FakeRunner: CommandRunning {
    var responses: [String: CommandResult]
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        let key = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
        for (k, v) in responses where key.hasPrefix(k) { return v }
        return CommandResult(status: 127, stdout: "", stderr: "FakeRunner: no response for \(key)")
    }
}

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }
    static func string(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}

/// Temporary directory that is removed at the end of the test.
final class TempDir {
    let path: String
    init() {
        path = NSTemporaryDirectory() + "xcv-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    @discardableResult
    func file(_ rel: String, bytes: Int) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 0x41, count: bytes))
        return p
    }
    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    @discardableResult
    func symlink(_ rel: String, to target: String) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }
}
