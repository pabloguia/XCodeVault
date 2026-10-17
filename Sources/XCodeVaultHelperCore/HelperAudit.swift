import Foundation
import XCodeVaultHelperProtocol
import os

/// The root daemon's audit trail.
///
/// Issue #4: a root daemon that deletes files and changes ownership recorded nothing. Its only
/// diagnostics were two `stderr` writes, and under `SMAppService` a daemon's `stderr` goes to a
/// sink no user can find — so an incident had nothing to reconstruct from, and the absence was the
/// item on the known-issues list hardest to fix after the fact, because by then the incident it
/// would have explained has already happened.
///
/// **Why `os_log` and not the project's `Redaction`.** The issue suggested reusing
/// `Redaction.swift` so a log could be attached to a bug report without hand-scrubbing. That type
/// lives in `XCodeVaultCore` and is built from `[Volume]`, and using it here would mean the root
/// daemon depending on all of Core — the one thing the helper's isolation exists to prevent, and
/// the property `scripts/helper-invariants.sh` and the security review are both partly about.
/// `os_log`'s own privacy qualifiers do the same job natively and better: a value logged
/// `.private(mask: .hash)` is stably correlatable across entries while never disclosing itself, so
/// "the same volume as three lines up" survives redaction, which a regex substitution cannot do.
///
/// What is `.public`: the verb, the caller's numeric uid, the authorization outcome, whether the
/// operation succeeded, the byte count, and this project's own fixed refusal messages. Those are
/// the shape of the incident and none of them identifies a person or a machine.
///
/// What is `.private`: every path, every volume UUID, and anything derived from a caller-supplied
/// argument. Hashed rather than suppressed where it is an identifier one wants to correlate.
///
/// **The cheap records are rate-limited per caller** (M5, ADR-0016). A client that satisfies the code-signing
/// requirement could loop a verb and flood the persisted unified log, evicting older records. Now the records
/// that cost a caller nothing — `version`, `begin`, and every refusal before a verb's implementation
/// (unauthorized, not begun, not offered) — are limited to `AuditThrottle.limit` per uid per window. Past that,
/// one `outcome=throttled` line marks where the flood began, those records are dropped until the window ends,
/// and the next one after it is preceded by `outcome=suppressed count=N` — if that uid sends one; a flood that
/// stops dead leaves only the `throttled` line. The dropped records' contents are lost.
///
/// **A verb that reached its implementation is always recorded**, whatever the throttle says: the dispatch's
/// rule is that nothing is returned to a caller that was not first recorded (`HelperService`), and a throttle
/// that could drop those would let 61 cheap calls hide one privileged act (helper-security review of M5, R1).
/// Such a record needs an administrator and a begun connection, which is what limits a flood of them; it is
/// the pre-M5 behaviour for those records.
///
/// Read it with:
///
///     log show --predicate 'subsystem == "com.xcodevault.helper"' --info --last 1h
enum HelperAudit {
    static let log = Logger(subsystem: "com.xcodevault.helper", category: "audit")
    private static let throttleLock = NSLock()
    nonisolated(unsafe) private static var throttle = AuditThrottle()

    /// One verb invocation, from the point the connection handed it over to the point it replied.
    ///
    /// A struct rather than a bare logging call so the decision of *what is recorded* can be
    /// tested. The emission cannot: reading back the unified log from a unit test means shelling
    /// out to `log show`, and there is no `Process` in this target by design. `AuditRecord` is
    /// therefore the seam — `HelperAuditTests` asserts over the record, and the one-line `emit`
    /// below is what review covers.
    struct AuditRecord: Equatable {
        enum Outcome: Equatable {
            /// `authorize()` refused before the verb ran. The most important line in the file.
            case refusedUnauthorized
            /// The verb ran and declined for one of its own reasons.
            case declined(String)
            case succeeded(bytesFreed: UInt64)

            /// Safe to log `.public`: a fixed set of words, not a message built from an argument.
            var label: String {
                switch self {
                case .refusedUnauthorized: return "refused-unauthorized"
                case .declined: return "declined"
                case .succeeded: return "succeeded"
                }
            }
        }

        let verb: String
        let callerUID: uid_t
        /// The arguments **after** validation, never as they arrived. Logging the raw argument
        /// would put an unvalidated caller-supplied string in a root-owned log, and a log is a
        /// place text gets read back later by something that trusts it.
        let validatedArguments: [String: String]
        let outcome: Outcome
        /// The result's code (R8): a closed vocabulary the helper itself produced, so it is safe `.public`. For
        /// `enableOwnership` it carries the authorization outcome — `authorizationDenied`, `authorizationMalformed`,
        /// `authorizationUnavailable` — alongside the gate's own `refused-unauthorized`.
        var code: HelperResultCode = .none

        /// Whether `AuditThrottle` may drop this record (M5, ADR-0016): the read-only verbs and the refusals made before
        /// any implementation ran. Every other record is a verb that reached its implementation, and is always written.
        var isThrottleable: Bool {
            if verb == "version" || verb == "begin" { return true }
            if outcome == .refusedUnauthorized { return true }
            return code == .clientVersionMismatch || code == .verbNotOffered
        }

        /// Derived from a `HelperResult`, so a verb cannot report one thing to the caller and
        /// another to the log. `refusedUnauthorized` is the one case the result alone cannot
        /// distinguish — `authorize()` returns an ordinary `ok: false` — so it is passed in.
        static func from(
            verb: String, callerUID: uid_t, validatedArguments: [String: String],
            result: HelperResult, wasUnauthorized: Bool
        ) -> AuditRecord {
            let outcome: Outcome
            if wasUnauthorized {
                outcome = .refusedUnauthorized
            } else if result.ok {
                outcome = .succeeded(bytesFreed: result.bytesFreed)
            } else {
                outcome = .declined(result.message)
            }
            return AuditRecord(verb: verb, callerUID: callerUID, validatedArguments: validatedArguments, outcome: outcome, code: result.code)
        }
    }

    /// Writes one record to the unified log.
    ///
    /// Emitted at `.notice` (`.default`) rather than `.info` or `.debug` on purpose: those two are
    /// memory-backed and are dropped rather than persisted unless something has enabled them, so a
    /// daemon that logged its deletions at `.info` would still have nothing to reconstruct from
    /// after a reboot — which is the entire defect this exists to fix. `.notice` persists.
    static func emit(_ record: AuditRecord) {
        let decision = throttleLock.withLock { decide(record, with: &throttle, now: Date()) }
        switch decision {
        case .suppress:
            return
        case .startSuppressing:
            log.notice(
                "verb=audit uid=\(record.callerUID, privacy: .public) outcome=throttled limit=\(AuditThrottle.limit, privacy: .public) windowSeconds=\(Int(AuditThrottle.window), privacy: .public)"
            )
            return
        case .emit(let suppressedBefore):
            if suppressedBefore > 0 {
                log.notice("verb=audit uid=\(record.callerUID, privacy: .public) outcome=suppressed count=\(suppressedBefore, privacy: .public)")
            }
        }
        // Arguments are joined here rather than interpolated per key, because the privacy
        // qualifier has to be applied to a value and the key set differs per verb. The joined
        // string is `.private`: it is built from caller-supplied input, however well validated.
        let arguments = record.validatedArguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        // The code is the helper's own fixed vocabulary (`HelperResultCode`); `-` when the verb sets none.
        let code = record.code == .none ? "-" : record.code.rawValue

        switch record.outcome {
        case .refusedUnauthorized:
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=refused-unauthorized code=\(code, privacy: .public) args=\(arguments, privacy: .private(mask: .hash))"
            )
        case .succeeded(let bytes):
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=succeeded bytesFreed=\(bytes, privacy: .public) code=\(code, privacy: .public) args=\(arguments, privacy: .private(mask: .hash))"
            )
        case .declined(let why):
            // The reason is `.public`, and that is a deliberate reversal.
            //
            // It was `.private`, which the unified log suppresses entirely on a default Mac — so
            // an operator reading the trail saw `reason=<private>` and learned nothing, in the
            // common diagnostic case. A reviewer pointed out the mismatch with this file's own
            // header, which says `.public` covers "this project's own fixed refusal messages".
            //
            // It is safe because every decline string these verbs produce is a literal owned by
            // `HelperService` plus, at most, a fixed enum path, an `strerror`, or a uid. **No
            // caller-controlled text reaches it** — the one client-supplied value, the raw
            // argument, goes in `args` and is hashed. If a verb ever interpolates a caller's
            // string into a refusal, this qualifier has to go back.
            //
            // Since issue #24 that invariant spans two files. `HelperMountHistory` reads a file
            // from disk to decide whether to refuse, and its reasons are fixed strings on purpose —
            // its first version put the record's **bytes** in the reason, which arrived here
            // unbounded, with interior newlines, and went out `.public`: log injection into a
            // root-owned trail. The size cap and the contents-free reasons in that file are what
            // keeps this line safe; a reviewer must read both.
            //
            // `args` stays hashed even for the two verbs whose validated value is a closed set
            // (`coreSimulatorDyldCache`, `cryptexCaches`, `<rejected>`). A hash of a three-element
            // set names nothing new to anyone reading the log, and it is stable, so two entries for
            // the same target still correlate — which is what reconstructing an incident needs. An
            // operator who needs the name enables private-data logging. Per-verb privacy rules
            // would buy a word and cost the one property this field has: it is hashed, always.
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=declined reason=\(why, privacy: .public) code=\(code, privacy: .public) args=\(arguments, privacy: .private(mask: .hash))"
            )
        }
    }

    /// What `emit` does with one record: the throttle's answer for a cheap one, always `.emit` for a verb that reached its
    /// implementation (review R1). Pure, so the rule is tested rather than read (review round 2, N6).
    static func decide(_ record: AuditRecord, with throttle: inout AuditThrottle, now: Date) -> AuditThrottle.Decision {
        record.isThrottleable ? throttle.admit(uid: record.callerUID, now: now) : .emit(suppressedBefore: 0)
    }

    /// The daemon's startup step (R8): whether the authorization right's definition was in place, written, or rewritten
    /// over someone else's. A rewrite is the line to look for: it means something defined this right before the helper.
    static func emitStartup(rightDefinition: RightDefinition) {
        let label: String
        switch rightDefinition {
        case .unchanged: label = "unchanged"
        case .defined: label = "defined"
        case .redefined: label = "redefined"
        case .failed(let status):
            log.error("verb=startup right=\(HelperIdentity.enableOwnershipRight, privacy: .public) definition=failed status=\(status, privacy: .public)")
            return
        }
        log.notice("verb=startup right=\(HelperIdentity.enableOwnershipRight, privacy: .public) definition=\(label, privacy: .public)")
    }
}

/// How many audit records one caller may write per window (M5, ADR-0016). A value, so the decision can be
/// tested with a fake clock; `HelperAudit.emit` holds the one live instance under a lock.
///
/// Only the cheap records count (`AuditRecord.isThrottleable`): one verb call writes two of them since M5
/// (`version`, `begin`), so the limit leaves room for thirty calls a minute from one user, and a verb that ran is
/// recorded either way.
struct AuditThrottle {
    static let limit = 60
    static let window: TimeInterval = 60

    enum Decision: Equatable {
        /// Write the record; first say how many were suppressed in the window that just ended, when any were.
        case emit(suppressedBefore: Int)
        /// The limit was just reached: write one line saying so, and not the record.
        case startSuppressing
        case suppress
    }

    private struct Window {
        var start: Date
        var count: Int
        var suppressed: Int
    }
    private var windows: [uid_t: Window] = [:]

    mutating func admit(uid: uid_t, now: Date) -> Decision {
        guard var w = windows[uid], now.timeIntervalSince(w.start) < Self.window, now >= w.start else {
            let before = windows[uid]?.suppressed ?? 0
            windows[uid] = Window(start: now, count: 1, suppressed: 0)
            return .emit(suppressedBefore: before)
        }
        defer { windows[uid] = w }
        if w.count < Self.limit {
            w.count += 1
            return .emit(suppressedBefore: 0)
        }
        w.suppressed += 1
        return w.suppressed == 1 ? .startSuppressing : .suppress
    }
}
