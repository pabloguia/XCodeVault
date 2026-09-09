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
    public var id: String  // operation id shared across its state transitions
    public var sequence: Int  // monotonically increasing per file
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
        guard flock(fh.fileDescriptor, LOCK_EX) == 0 else {
            throw CommandError(executable: "flock", arguments: [url.path], result: nil, underlying: String(cString: strerror(errno)))
        }
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
        try read().entries
    }

    /// What a read actually saw. `entries()` cannot express any of this: it returns `[]` for a
    /// missing file and `compactMap { try? … }` swallows every undecodable line, so "no operations
    /// were recorded", "the journal is gone" and "every line is corrupt" are the same value.
    ///
    /// That matters wherever the *absence* of a record drives a destructive suggestion — `doctor`'s
    /// unavailable-device rule reads "no offload on record" as "the runtime is gone for good, delete
    /// the devices". Silence from a journal that could not be read must not be mistaken for a fact.
    public struct ReadResult: Sendable {
        public var entries: [JournalEntry]
        /// False when the journal file does not exist yet — normal on a fresh install.
        public var filePresent: Bool
        /// Lines that failed to decode. Non-zero means `entries` is a lower bound.
        public var undecodableLines: Int
        /// True when the journal could be read in full: either absent (nothing has happened yet) or
        /// present with every line decoded.
        public var isComplete: Bool { undecodableLines == 0 }
    }

    /// Reads the journal, distinguishing absent from unreadable from partially corrupt. Throws when
    /// the file exists but cannot be read at all (permissions, I/O) — a case `entries()` reports as
    /// an empty history.
    public func read() throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReadResult(entries: [], filePresent: false, undecodableLines: 0)
        }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [JournalEntry] = []
        var bad = 0
        for line in data.split(separator: 0x0A) {
            if let e = try? dec.decode(JournalEntry.self, from: line) { out.append(e) } else { bad += 1 }
        }
        return ReadResult(entries: out, filePresent: true, undecodableLines: bad)
    }

    /// Operations whose last recorded state is `started` — i.e. interrupted by a crash or kill.
    public func interrupted() throws -> [JournalEntry] {
        var last: [String: JournalEntry] = [:]
        for e in try entries() { last[e.id] = e }
        return last.values.filter { $0.state == .started }.sorted { $0.sequence < $1.sequence }
    }

    /// Convenience: record a transition for an operation.
    @discardableResult
    public func record(
        id: String = UUID().uuidString, kind: JournalEntry.Kind, state: JournalEntry.State, summary: String,
        paths: [String] = [], bytes: UInt64? = nil, detail: [String: String] = [:]
    ) throws -> JournalEntry {
        try append(
            JournalEntry(
                id: id, sequence: 0, timestamp: Date(), kind: kind, state: state, summary: summary,
                paths: paths, bytes: bytes, detail: detail, toolVersion: XCodeVaultVersion.current))
    }
}
