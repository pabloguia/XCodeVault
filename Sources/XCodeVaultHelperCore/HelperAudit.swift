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
/// **Not rate-limited, and that is a known gap rather than an oversight.** A client that satisfies
/// the code-signing requirement can loop a verb and flood the persisted unified log, evicting older
/// records — including this trail's own. It is mitigated by that requirement and by the
/// administrator check on every state-changing verb, so reaching it means already holding both;
/// recorded here because a trail that can be pushed out of the window is a trail with a failure
/// mode, and the next person should know it rather than discover it.
///
/// Read it with:
///
///     log show --predicate 'subsystem == "com.xcodevault.helper"' --info --last 1h
enum HelperAudit {
    static let log = Logger(subsystem: "com.xcodevault.helper", category: "audit")

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
            return AuditRecord(verb: verb, callerUID: callerUID, validatedArguments: validatedArguments, outcome: outcome)
        }
    }

    /// Writes one record to the unified log.
    ///
    /// Emitted at `.notice` (`.default`) rather than `.info` or `.debug` on purpose: those two are
    /// memory-backed and are dropped rather than persisted unless something has enabled them, so a
    /// daemon that logged its deletions at `.info` would still have nothing to reconstruct from
    /// after a reboot — which is the entire defect this exists to fix. `.notice` persists.
    static func emit(_ record: AuditRecord) {
        // Arguments are joined here rather than interpolated per key, because the privacy
        // qualifier has to be applied to a value and the key set differs per verb. The joined
        // string is `.private`: it is built from caller-supplied input, however well validated.
        let arguments = record.validatedArguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")

        switch record.outcome {
        case .refusedUnauthorized:
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=refused-unauthorized args=\(arguments, privacy: .private(mask: .hash))"
            )
        case .succeeded(let bytes):
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=succeeded bytesFreed=\(bytes, privacy: .public) args=\(arguments, privacy: .private(mask: .hash))"
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
            log.notice(
                "verb=\(record.verb, privacy: .public) uid=\(record.callerUID, privacy: .public) outcome=declined reason=\(why, privacy: .public) args=\(arguments, privacy: .private(mask: .hash))"
            )
        }
    }
}
