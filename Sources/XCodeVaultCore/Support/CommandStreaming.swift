import Foundation

/// One line of an operation's live log (R3): a command as it starts, a line it printed, how it ended, or a stage the
/// app reached. A record, like the journal: never translated (docs/process/LOCALIZATION.md).
public struct LogLine: Sendable, Equatable {
    public enum Stream: String, Sendable, Equatable {
        /// The command line, before the command runs.
        case command
        case stdout
        case stderr
        /// The command's exit status, after it ran.
        case exit
        /// A stage the operation reached (the app writes these).
        case stage
    }
    public let stream: Stream
    public let text: String
    public init(_ stream: Stream, _ text: String) {
        self.stream = stream
        self.text = text
    }

    /// The line as the log shows it: `$ ditto …` for a command, `[exit 0]`, `== copying`, `! …` for stderr.
    public var rendered: String {
        switch stream {
        case .command: "$ " + text
        case .stdout: text
        case .stderr: "! " + text
        case .exit: "[exit " + text + "]"
        case .stage: "== " + text
        }
    }

    /// A command as it would be typed: the executable and each argument, an argument with a space or a quote in single
    /// quotes. For reading only — nothing ever runs this string (`CommandRunning` takes no shell string).
    public static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(quoted).joined(separator: " ")
    }

    static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" || $0 == "\t" }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a running operation's log lines go. Called on whatever thread produced the line; it returns nothing, so it
/// cannot change what the operation does next.
public typealias LogObserver = @Sendable (LogLine) -> Void

/// Splits a byte stream into lines at `\n`, `\r\n` or a lone `\r` (progress output rewrites its line with `\r`). Bytes
/// are kept until a line ends, so a UTF-8 character cut across two reads is decoded whole.
struct LineSplitter {
    private var pending: [UInt8] = []
    private var lastWasCR = false

    /// The complete lines in `bytes`, in order; a partial last line is kept for the next call.
    mutating func feed(_ bytes: Data) -> [String] {
        var lines: [String] = []
        for b in bytes {
            if b == 0x0A {
                if lastWasCR {
                    lastWasCR = false
                    continue  // the `\n` of a `\r\n`: the line ended at the `\r`
                }
                lines.append(take())
            } else if b == 0x0D {
                lines.append(take())
                lastWasCR = true
                continue
            } else {
                pending.append(b)
            }
            lastWasCR = false
        }
        return lines
    }

    /// The last line when the stream ended without a newline; nil when nothing is left.
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        return take()
    }

    private mutating func take() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// `ProcessCommandRunner` with each output line also handed to an observer as it is printed (R3: the app's live log).
///
/// **Observation only.** The process is configured exactly as `ProcessCommandRunner` configures it — the same
/// executable, arguments, environment merge, a null standard input, and both pipes drained concurrently until EOF —
/// and the `CommandResult` returned is built from the whole of each pipe's bytes, decoded the same way, independently
/// of how the lines were split for the observer. A launch failure throws the same `CommandError`. The observer's
/// return type is `Void`, so nothing it does is read back.
public struct StreamingCommandRunner: CommandRunning {
    let observer: LogObserver
    public init(observer: @escaping LogObserver) { self.observer = observer }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        observer(LogLine(.command, LogLine.commandLine(executable, arguments)))
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
            observer(LogLine(.stderr, error.localizedDescription))
            throw CommandError(executable: executable, arguments: arguments, result: nil, underlying: error.localizedDescription)
        }
        let out = PipeDrain(), err = PipeDrain()
        let group = DispatchGroup()
        let observer = self.observer
        for (pipe, drain, stream) in [(outPipe, out, LogLine.Stream.stdout), (errPipe, err, LogLine.Stream.stderr)] {
            group.enter()
            DispatchQueue.global().async {
                drain.drain(pipe.fileHandleForReading) { observer(LogLine(stream, $0)) }
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        observer(LogLine(.exit, String(process.terminationStatus)))
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self))
    }
}

/// One pipe read to EOF: every byte kept for the result, and each complete line reported as it arrives.
private final class PipeDrain: @unchecked Sendable {
    // Written by the one reading thread, read after `DispatchGroup.wait()`: the group orders the two.
    private(set) var data = Data()

    func drain(_ handle: FileHandle, line: (String) -> Void) {
        var splitter = LineSplitter()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            for l in splitter.feed(chunk) { line(l) }
        }
        if let last = splitter.finish() { line(last) }
    }
}

/// Wraps any runner and reports its commands to an observer: the command line before it runs, then its output lines
/// and exit status once it returns. The base's `CommandResult` is returned unchanged and its errors are rethrown
/// unchanged; the observer returns `Void`. Used where the output does not need to stream, and in tests over a fake
/// runner.
public struct ObservingCommandRunner: CommandRunning {
    let base: CommandRunning
    let observer: LogObserver
    public init(_ base: CommandRunning, observer: @escaping LogObserver) {
        self.base = base
        self.observer = observer
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> CommandResult {
        observer(LogLine(.command, LogLine.commandLine(executable, arguments)))
        let result: CommandResult
        do {
            result = try base.run(executable, arguments, environment: environment)
        } catch {
            observer(LogLine(.stderr, "\(error)"))
            throw error
        }
        for (text, stream) in [(result.stdout, LogLine.Stream.stdout), (result.stderr, .stderr)] {
            var splitter = LineSplitter()
            var lines = splitter.feed(Data(text.utf8))
            if let last = splitter.finish() { lines.append(last) }
            for l in lines { observer(LogLine(stream, l)) }
        }
        observer(LogLine(.exit, String(result.status)))
        return result
    }
}
