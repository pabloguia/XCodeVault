import Foundation

/// The History screen's rows (R4): one per operation, not per journal record. An operation is written as several records
/// sharing its id — opened (`planned` or `started`), any number of steps, closed — and the user wants the operation:
/// what it was, what it ended as, when. The app shows what this decides and decides none of it. The summaries are the
/// journal's own English (LOCALIZATION.md: journal entries are never translated); the kind and the outcome are words
/// the app translates.
public enum JournalTimeline {
    /// What an operation was, for its badge. Coarser than `JournalEntry.Kind` where the journal's kind is shared — the
    /// helper's actions are recorded under `clean` and `migration`, and so is the vault registry — and closed: a record
    /// this does not recognise is `other`, never a guess.
    public enum Kind: String, Sendable, CaseIterable, Hashable {
        case clean, runtimeDelete, runtimeOffload, runtimeExport, runtimeImport, migration, xcodeLocationChange, privileged, other
    }

    /// How an operation ended, as its last record says.
    public enum Outcome: String, Sendable, CaseIterable, Hashable {
        case completed, failed, rolledBack, skipped
        /// The last record opened or continued it and no record closed it: a crash, a kill, or a power cut — the same
        /// rule as `Journal.interrupted()`. An operation the caller knows is running right now is `inProgress` instead.
        case interrupted
        case inProgress
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// The operation id the records share.
        public let id: String
        public let kind: Kind
        public let outcome: Outcome
        /// When the operation began: its first record's time.
        public let started: Date
        /// The first record's summary: what the operation set out to do.
        public let summary: String
        /// The last record's summary when it says something else: how it ended (a count, an error).
        public let endSummary: String?
        /// The last size any record gave; nil when none did.
        public let bytes: UInt64?
        /// How many records the operation has.
        public let recordCount: Int
        /// The first record's sequence number, which orders rows that started at the same time.
        public let sequence: Int
    }

    /// The journal's records as operations, newest start first. `running` names operations the caller knows are in progress.
    public static func rows(_ entries: [JournalEntry], running: Set<String> = []) -> [Row] {
        var order: [String] = []
        var byID: [String: [JournalEntry]] = [:]
        for e in entries.sorted(by: { $0.sequence < $1.sequence }) {
            if byID[e.id] == nil { order.append(e.id) }
            byID[e.id, default: []].append(e)
        }
        return order.compactMap { id -> Row? in
            guard let records = byID[id], let first = records.first, let last = records.last else { return nil }
            return Row(
                id: id, kind: kind(of: records), outcome: outcome(of: last, running: running.contains(id)), started: first.timestamp,
                summary: first.summary, endSummary: last.summary == first.summary ? nil : last.summary,
                bytes: records.last { $0.bytes != nil }?.bytes, recordCount: records.count, sequence: first.sequence)
        }
        // Newest start first, so the day sections run newest first; the sequence breaks ties and orders a journal whose
        // clock went backwards the way it was written.
        .sorted { ($0.started, $0.sequence) > ($1.started, $1.sequence) }
    }

    /// The badge for an operation's records. The helper's actions say so in their summary (`PrivilegedActionRunner`
    /// writes `helper: …`); a migration carries its direction on its plan record; a `migration` record without one is the
    /// vault registry's, which is not a migration.
    public static func kind(of records: [JournalEntry]) -> Kind {
        guard let first = records.first else { return .other }
        if records.contains(where: { $0.summary.hasPrefix("helper: ") }) { return .privileged }
        switch first.kind {
        case .clean: return .clean
        case .runtimeDelete: return .runtimeDelete
        case .runtimeOffload: return .runtimeOffload
        case .runtimeExport: return .runtimeExport
        case .runtimeImport: return .runtimeImport
        case .xcodeLocationChange: return .xcodeLocationChange
        case .migration: return records.contains { $0.detail["direction"] != nil } ? .migration : .other
        }
    }

    static func outcome(of last: JournalEntry, running: Bool) -> Outcome {
        switch last.state {
        case .completed: .completed
        case .failed: .failed
        case .rolledBack: .rolledBack
        case .skipped: .skipped
        case .planned, .started: running ? .inProgress : .interrupted
        }
    }

    /// The rows whose kind is not hidden, in their order.
    public static func filter(_ rows: [Row], hiding hidden: Set<Kind>) -> [Row] {
        hidden.isEmpty ? rows : rows.filter { !hidden.contains($0.kind) }
    }

    /// The kinds the rows have, in `Kind`'s order: what the filter offers.
    public static func kinds(in rows: [Row]) -> [Kind] {
        let present = Set(rows.map(\.kind))
        return Kind.allCases.filter(present.contains)
    }

    /// A section's day, as its header says it.
    public enum Day: Sendable, Hashable {
        case today, yesterday
        /// Any other day: its start, in the calendar's time zone.
        case date(Date)
    }

    public struct DaySection: Sendable, Equatable, Identifiable {
        public let day: Day
        public let rows: [Row]
        public var id: Day { day }
    }

    /// The rows grouped by the day they started, in their order (newest day first when the rows are newest first).
    public static func sections(_ rows: [Row], now: Date, calendar: Calendar) -> [DaySection] {
        var sections: [DaySection] = []
        for row in rows {
            let day = self.day(of: row.started, now: now, calendar: calendar)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = DaySection(day: day, rows: last.rows + [row])
            } else {
                sections.append(DaySection(day: day, rows: [row]))
            }
        }
        return sections
    }

    static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .date(calendar.startOfDay(for: date))
    }
}

extension JournalTimeline.Kind {
    /// The badge's SF Symbol: one per kind, so a kind is never told by color.
    public var symbolName: String {
        switch self {
        case .clean: "trash"
        case .runtimeDelete: "xmark.bin"
        case .runtimeOffload: "externaldrive.badge.minus"
        case .runtimeExport: "square.and.arrow.up"
        case .runtimeImport: "square.and.arrow.down"
        case .migration: "arrow.left.arrow.right"
        case .xcodeLocationChange: "folder.badge.gearshape"
        case .privileged: "lock.shield"
        case .other: "doc.text"
        }
    }

    /// The badge's color in the light appearance, `#RRGGBB`. With `darkColorHex`, a small fixed palette: one hue per
    /// kind, each clearing 3:1 on the window and control backgrounds in its appearance (`HistoryKindPaletteTests`). A
    /// symbol tint and a fill, never text color, and never alone: the symbol and the name are always next to it.
    public var lightColorHex: String {
        switch self {
        case .clean: "#A86A00"
        case .runtimeDelete: "#C4362E"
        case .runtimeOffload: "#2A6FE0"
        case .runtimeExport: "#0E7F8A"
        case .runtimeImport: "#6A4FD6"
        case .migration: "#1E8B5D"
        case .xcodeLocationChange: "#B53C8C"
        case .privileged: "#7A6418"
        case .other: "#6E7385"
        }
    }

    /// The badge's color in the dark appearance.
    public var darkColorHex: String {
        switch self {
        case .clean: "#E39B2D"
        case .runtimeDelete: "#F0685E"
        case .runtimeOffload: "#5B9BF5"
        case .runtimeExport: "#2EB8C4"
        case .runtimeImport: "#9B87F5"
        case .migration: "#3DBE7E"
        case .xcodeLocationChange: "#E06AB8"
        case .privileged: "#C2AE3A"
        case .other: "#9399AB"
        }
    }
}

extension JournalTimeline.Outcome {
    /// The state's SF Symbol, shown beside its word.
    public var symbolName: String {
        switch self {
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .rolledBack: "arrow.uturn.backward.circle"
        case .skipped: "forward.end.circle"
        case .interrupted: "exclamationmark.triangle"
        case .inProgress: "clock"
        }
    }
}
