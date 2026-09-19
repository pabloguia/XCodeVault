import Foundation

/// Result of running an external tool.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CommandError: DescribedError, Sendable {
    public let executable: String
    public let arguments: [String]
    public let result: CommandResult?
    public let underlying: String?
    public var description: String {
        let cmd = ([executable] + arguments).joined(separator: " ")
        if let r = result { return "`\(cmd)` exited \(r.status): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return "`\(cmd)` failed: \(underlying ?? "unknown error")"
    }
}

/// The only way XCodeVault runs external tools: a fixed absolute executable and an argument
/// array. There is deliberately no API that takes a shell string. Injectable for tests.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, environment: nil)
    }
    /// Runs and throws unless the tool exits 0.
    @discardableResult
    func check(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> CommandResult {
        let r = try run(executable, arguments, environment: environment)
        guard r.succeeded else { throw CommandError(executable: executable, arguments: arguments, result: r, underlying: nil) }
        return r
    }
}

/// Foundation.Process-backed runner (posix_spawn under the hood, no shell).
public struct ProcessCommandRunner: CommandRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw CommandError(executable: executable, arguments: arguments, result: nil, underlying: error.localizedDescription)
        }
        // Read both pipes concurrently to avoid deadlock on large output.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter();
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter();
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Well-known tool locations. Everything else is resolved through `xcrun` or an Xcode's
/// Developer directory — never through `$PATH` lookup.
public enum Tools {
    public static let xcrun = "/usr/bin/xcrun"
    public static let xcodeSelect = "/usr/bin/xcode-select"
    public static let diskutil = "/usr/sbin/diskutil"
    public static let hdiutil = "/usr/bin/hdiutil"
    public static let defaults = "/usr/bin/defaults"
    public static let swVers = "/usr/bin/sw_vers"
    public static let ditto = "/usr/bin/ditto"
}
