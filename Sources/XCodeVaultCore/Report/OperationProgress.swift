import Foundation

/// What a running operation is doing now (R3: the sheet's stage line). The app shows what this decides.
public enum OperationStage: String, Sendable, Equatable, CaseIterable {
    case planning
    /// `ditto` copying into the vault.
    case copying
    /// The deep (SHA-256) comparison after the copy.
    case verifying
    /// `removeSource`: rename aside, re-verify, delete. One stage, because Core reports none of its steps.
    case removing
    /// Deleting a runtime through simctl (offload, delete).
    case deleting
    /// `xcodebuild -downloadPlatform … -exportPath`.
    case exporting
    /// Writing an Xcode Locations setting through `defaults`.
    case applying
    case done
    case failed

    /// The stage after `line` arrived while at `current`. The only transition a log line causes: a command exiting 0
    /// while copying. `copyAndVerify` runs one command, `ditto`, and verification runs none, so that exit is the copy
    /// finishing and the engine verifying. Every other line leaves the stage alone; the app sets the rest.
    ///
    /// Derived from the log on purpose: `MigrationEngine` takes no observer, so nothing caller-supplied runs inside a
    /// migration, and a wrong stage here can only be wrong about what the sheet shows.
    public static func after(_ line: LogLine, from current: OperationStage) -> OperationStage {
        guard current == .copying, line.stream == .exit, line.text == "0" else { return current }
        return .verifying
    }
}

public enum OperationProgress {
    /// The bar's fraction: `done` of `total`, clamped to 0...1 (a copy's allocated size can pass the source's when the
    /// vault's block size differs). Nil when there is no total — the bar is then indeterminate.
    public static func fraction(done: UInt64?, total: UInt64?) -> Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// Bytes added to a folder since it was first measured: what an export has downloaded so far. Never negative —
    /// a folder that shrank (another installer removed) shows 0, not a wrapped-around number.
    public static func added(baseline: UInt64?, current: UInt64?) -> UInt64? {
        guard let current else { return nil }
        guard let baseline else { return current }
        return current > baseline ? current - baseline : 0
    }
}

/// An operation's log as kept in memory: the newest `limit` lines, and how many older ones were dropped. The app keeps
/// the full log in a file; this bound is what stops a chatty `xcodebuild` from growing the window's memory without end.
public struct OperationLog: Sendable, Equatable {
    public static let defaultLimit = 5_000
    public let limit: Int
    public private(set) var lines: [LogLine] = []
    public private(set) var droppedCount = 0

    public init(limit: Int = OperationLog.defaultLimit) { self.limit = max(1, limit) }

    public mutating func append(_ line: LogLine) {
        lines.append(line)
        if lines.count > limit {
            let excess = lines.count - limit
            lines.removeFirst(excess)
            droppedCount += excess
        }
    }

    /// The kept lines as text, as **Copy log** copies them: a first line saying how many were dropped, if any.
    public var text: String {
        let body = lines.map(\.rendered).joined(separator: "\n")
        return droppedCount == 0 ? body : "[\(droppedCount) earlier lines not kept in memory]\n" + body
    }
}

/// What to tell the user about a migration the journal shows interrupted, and the exact commands that recover it (R3:
/// the banner on Park, Run externally and History). The GUI runs none of them this round.
public enum MigrationRecovery {
    /// Migrations whose last record is `started`: `Journal.interrupted()`'s rule, over records already read, and the
    /// same `.migration` filter as `xcodevaultctl migration status`. `running` names operations this process is running
    /// right now, which are not interrupted.
    public static func interrupted(_ entries: [JournalEntry], running: Set<String> = []) -> [JournalEntry] {
        var last: [String: JournalEntry] = [:]
        for e in entries.sorted(by: { $0.sequence < $1.sequence }) { last[e.id] = e }
        return last.values
            .filter { $0.state == .started && $0.kind == .migration && !running.contains($0.id) }
            .sorted { $0.sequence < $1.sequence }
    }

    /// The commands for one interrupted migration, `migration status` first. The second is the one Core accepts at
    /// the phase reached: `resume` once a CLEANUP has begun (the original may be renamed aside), `abort` before
    /// verification. Between the two (`VERIFIED`, nothing renamed) neither is offered and `status` says why. `resume`
    /// is given without `--i-confirm-deleting-non-regenerable-data`: Core asks for it, and the user types it.
    public static func commands(for id: String, in entries: [JournalEntry]) -> [String] {
        let phases = Set(entries.filter { $0.id == id }.compactMap { $0.detail["phase"] })
        var out = ["xcodevaultctl migration status"]
        if phases.contains("CLEANUP") {
            out.append("xcodevaultctl migration resume \(id)")
        } else if !phases.contains("VERIFIED") {
            out.append("xcodevaultctl migration abort \(id)")
        }
        return out
    }
}
