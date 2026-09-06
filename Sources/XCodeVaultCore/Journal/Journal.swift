import Foundation

/// Durable, append-only operation journal (JSON Lines). Every operation that changes the
/// user's machine — deletion, runtime export/import/delete, Xcode setting changes, and later
/// migrations — records `planned → started → completed|failed` here so a crash between any
/// two steps is visible and `doctor`/`journal list` can show what happened
/// (MIGRATION_ENGINE.md: "record every migration in a journal the doctor can read").
public struct JournalEntry: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case clean, runtimeDelete, runtimeExport, runtimeImport, runtimeOffload, xcodeLocationChange, migration
    }
    public enum State: String, Sendable, Codable { case planned, started, completed, failed, rolledBack, skipped }
    public var id: String                 // operation id shared across its state transitions
    public var sequence: Int              // monotonically increasing per file
    public var timestamp: Date
    public var kind: Kind
    public var state: State
    public var summary: String
    public var paths: [String]
    public var bytes: UInt64?
    public var detail: [String: String]
    public var toolVersion: String
}

public struct Journal: Sendable {
    public let url: URL
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/XCodeVault/journal.jsonl")

    public init(url: URL = Journal.defaultURL) { self.url = url }

    /// Appends one entry, fsyncing the file. Returns the entry with its sequence number.
    @discardableResult
    public func append(_ entry: JournalEntry) throws -> JournalEntry {
        var e = entry
        e.sequence = (try? entries().last?.sequence).flatMap { $0 }.map { $0 + 1 } ?? 1
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        var line = try enc.encode(e); line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        // Cross-process exclusion (CLI and GUI may both append).
        guard flock(fh.fileDescriptor, LOCK_EX) == 0 else { throw CommandError(executable: "flock", arguments: [url.path], result: nil, underlying: String(cString: strerror(errno))) }
        defer { flock(fh.fileDescriptor, LOCK_UN) }
        e.sequence = (try? entries().last?.sequence).flatMap { $0 }.map { $0 + 1 } ?? 1
        let enc2 = JSONEncoder(); enc2.dateEncodingStrategy = .iso8601; enc2.outputFormatting = [.sortedKeys]
        var line2 = try enc2.encode(e); line2.append(0x0A)
        try fh.seekToEnd()
        try fh.write(contentsOf: line2)
        try fh.synchronize()
        _ = line
        return e
    }

    public func entries() throws -> [JournalEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? dec.decode(JournalEntry.self, from: $0) }
    }

    /// Operations whose last recorded state is `started` — i.e. interrupted by a crash or kill.
    public func interrupted() throws -> [JournalEntry] {
        var last: [String: JournalEntry] = [:]
        for e in try entries() { last[e.id] = e }
        return last.values.filter { $0.state == .started }.sorted { $0.sequence < $1.sequence }
    }

    /// Convenience: record a transition for an operation.
    @discardableResult
    public func record(id: String = UUID().uuidString, kind: JournalEntry.Kind, state: JournalEntry.State, summary: String,
                       paths: [String] = [], bytes: UInt64? = nil, detail: [String: String] = [:]) throws -> JournalEntry {
        try append(JournalEntry(id: id, sequence: 0, timestamp: Date(), kind: kind, state: state, summary: summary,
                                paths: paths, bytes: bytes, detail: detail, toolVersion: XCodeVaultVersion.current))
    }
}
