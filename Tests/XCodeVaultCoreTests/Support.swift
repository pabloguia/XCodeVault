import Foundation
import XCTest
@testable import XCodeVaultCore

/// A `CommandRunning` that replays canned results keyed by executable basename + first args.
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
