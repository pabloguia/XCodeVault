import Foundation

/// What XCodeVault needs from its privileged helper, in Core's terms, so the decisions around it — when to
/// register, how long to wait, when to refuse — live here and are tested with fakes. The app conforms it to
/// `HelperClient`; Core does not import the client (Package.swift).
///
/// Methods, not closures, on purpose: `scripts/public-surface.sh` rule 1 refuses any public declaration
/// shaped `throws -> Void` — the shape of a fault-injection hook — and a protocol method renders without it.
public protocol PrivilegedHelper: Sendable {
    func state() -> HelperState
    func register() throws
    func openApprovalSettings()
    func unregister() async throws
    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply
    /// The same, asking `authorized` once the user's authorization is obtained and just before the request is sent (R8
    /// fix round 2, F2): the runner journals `.started` there, so a crash after the password shows as interrupted. When
    /// it answers false — the record could not be written — nothing is sent, and `PrivilegedActionNotStarted` is thrown
    /// (round 3).
    func perform(_ action: PrivilegedAction, authorized: @escaping @Sendable () -> Bool) async throws -> PrivilegedActionReply
}

extension PrivilegedHelper {
    /// A helper with no authorization step of its own is authorized as soon as it is asked.
    public func perform(_ action: PrivilegedAction, authorized: @escaping @Sendable () -> Bool) async throws -> PrivilegedActionReply {
        guard authorized() else { throw PrivilegedActionNotStarted() }
        return try await perform(action)
    }
}

/// The request was not sent because its `.started` record could not be written (R8 fix round 3): a privileged action
/// whose start the journal cannot show must not run.
public struct PrivilegedActionNotStarted: Error, Equatable, CustomStringConvertible {
    public init() {}
    public var description: String { "The journal could not record the start, so nothing was sent to the helper." }
}

/// The helper's answer in Core's terms: a copy of `HelperResult`, which Core cannot see.
public struct PrivilegedActionReply: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var bytesFreed: UInt64

    public init(ok: Bool, message: String, bytesFreed: UInt64 = 0) {
        self.ok = ok
        self.message = message
        self.bytesFreed = bytesFreed
    }
}

public enum HelperApprovalOutcome: Sendable, Equatable {
    case enabled
    case notAvailableInThisBuild
    case timedOut
    case cancelled
    case failed(String)
}

/// Spec §3: `register()` → open Login Items & Extensions → poll the status → `enabled`. Never run live before
/// M5 (#30); `HelperApprovalFlowTests` drives it with a fake.
public struct HelperApprovalFlow: Sendable {
    let helper: any PrivilegedHelper
    let pollInterval: Duration
    let maxPolls: Int

    /// Five minutes at one poll a second by default: approving needs the user to find the switch and
    /// authenticate. Waiting stops when the caller's task is cancelled.
    public init(helper: any PrivilegedHelper, pollInterval: Duration = .seconds(1), maxPolls: Int = 300) {
        self.helper = helper
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    public func run() async -> HelperApprovalOutcome {
        switch helper.state() {
        case .unavailableInThisBuild:
            return .notAvailableInThisBuild
        case .enabled:
            return .enabled
        case .awaitingApproval:
            break
        case .notInstalled:
            do {
                try helper.register()
            } catch {
                // For a daemon, `register()` is reported to throw while the service lands in approval —
                // unmeasured here (#30). So the outcome is read from the status, not from the throw.
                if helper.state() != .awaitingApproval { return .failed("\(error)") }
            }
            if helper.state() == .enabled { return .enabled }
        }
        helper.openApprovalSettings()
        for _ in 0..<maxPolls {
            do { try await Task.sleep(for: pollInterval) } catch { return .cancelled }
            switch helper.state() {
            case .enabled: return .enabled
            case .awaitingApproval: continue
            case .notInstalled: return .failed("The helper's registration disappeared while waiting for approval.")
            case .unavailableInThisBuild: return .notAvailableInThisBuild
            }
        }
        return .timedOut
    }
}

public enum PrivilegedActionOutcome: Sendable, Equatable {
    case done(PrivilegedActionReply)
    case refused(String)
    case failed(String)
    /// R8: the user cancelled the system password dialog. Not an error, and nothing reached the helper.
    case cancelled
    /// R8 fix round 4: the helper that answered is another version than this build's; nothing was sent to it. The app
    /// reinstalls the helper through the approval flow and tries once more.
    case helperOutdated(String)
}

/// What a `PrivilegedHelper` throws when the helper that answered is another version than this build's (R8 fix round 4).
public struct PrivilegedHelperOutdated: Error, Equatable {
    public let detail: String
    public init(detail: String) { self.detail = detail }
}

/// What a `PrivilegedHelper` throws when the helper did not answer the opening round trip in time (advisory A2): the
/// verb was not sent, so the runner journals the step as skipped and reports a refusal, never a failure.
public struct PrivilegedHelperDidNotAnswer: Error, Equatable {
    public let detail: String
    public init(detail: String) { self.detail = detail }
}

/// What a `PrivilegedHelper` throws when the user cancelled the system password dialog (R8): the runner reports
/// `.cancelled` and journals the step as skipped, never as failed.
public struct PrivilegedActionCancelled: Error, Equatable {
    public init() {}
}

/// Runs one privileged action through the helper, journaled like every change the product makes.
public struct PrivilegedActionRunner: Sendable {
    let helper: any PrivilegedHelper
    let journal: Journal
    let isXcodeRunning: @Sendable () -> Bool
    let isSimulatorWorkRunning: @Sendable () -> Bool

    /// The two defaults are safety checks; `scripts/public-surface.sh` rule 3 pins them to the real ones.
    public init(
        helper: any PrivilegedHelper, journal: Journal = Journal(),
        isXcodeRunning: @escaping @Sendable () -> Bool = CleanExecutor.xcodeIsRunning,
        isSimulatorWorkRunning: @escaping @Sendable () -> Bool = CleanExecutor.simulatorWorkIsRunning
    ) {
        self.helper = helper
        self.journal = journal
        self.isXcodeRunning = isXcodeRunning
        self.isSimulatorWorkRunning = isSimulatorWorkRunning
    }

    public func run(_ action: PrivilegedAction) async -> PrivilegedActionOutcome {
        // Consistency with what the UI showed, not security: `HelperState` is an installation hint, and the
        // peer's replies are checked by the requirement `HelperClient.connect()` sets, whatever this says.
        guard helper.state() == .enabled else { return .refused("The privileged helper is not enabled.") }
        if action.usesTheSimulatorCaches {
            // The helper's cleanup verb has no in-use check of its own, so the client refuses while anything
            // that uses the dyld cache runs. Both checks answer "running" when they cannot tell, and the text says
            // so rather than asserting what was not seen (migration-safety review of deliverable 4, round 2).
            if isXcodeRunning() {
                return .refused(
                    "Xcode is running, or the process list could not be read. Quit Xcode first: it uses the dyld cache while it runs.")
            }
            if isSimulatorWorkRunning() {
                return .refused(
                    "A simulator, simctl, xcodebuild or the dyld cache builder is running, or the process list could not be read. "
                        + "They use the cache: try again when they have stopped.")
            }
        }
        let id = UUID().uuidString
        do {
            try journal.record(
                id: id, kind: action.journalKind, state: action.openingState, summary: "helper: \(action.title)", paths: action.journalPaths,
                detail: action.journalDetail)
        } catch {
            return .refused("The journal could not be written, so nothing was done: \(error)")
        }
        do {
            // `.started` once the request is about to leave: for `enableOwnership` that is after the password dialog, so
            // a cancelled dialog stays a planned-then-skipped record and a crash after it reads as interrupted (F2).
            // Only `enableOwnership` has a password step between its opening record and the request; every other action
            // already opens at its own state, so a second record would duplicate it.
            let journal = self.journal
            let recordsStarted: Bool = { if case .enableOwnership = action { return true } else { return false } }()
            let reply = try await helper.perform(action) {
                guard recordsStarted else { return true }
                // Written, or the request does not leave (round 3).
                return
                    (try? journal.record(
                        id: id, kind: action.journalKind, state: .started, summary: "helper: \(action.title)", paths: action.journalPaths,
                        detail: action.journalDetail)) != nil
            }
            // A failed reply can still have deleted something: the cleanup verb removes what it can, counts only
            // what it removed, and fails when anything is left (`HelperService.removeContents`). The journal says
            // what was deleted, not only whether all of it was (migration-safety review of deliverable 4).
            let bytes: UInt64? = reply.ok || reply.bytesFreed > 0 ? reply.bytesFreed : nil
            // After the fact: a failure to record cannot undo what the helper did, so it is not thrown.
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: reply.ok ? .completed : .failed, summary: "helper: \(action.title): \(reply.message)",
                paths: action.journalPaths, bytes: bytes, detail: action.journalDetail)
            return reply.ok ? .done(reply) : .failed(reply.message)
        } catch let outdated as PrivilegedHelperOutdated {
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: .skipped, summary: "helper: \(action.title): the helper is out of date; nothing was sent",
                paths: action.journalPaths, detail: action.journalDetail)
            return .helperOutdated(outdated.detail)
        } catch let silent as PrivilegedHelperDidNotAnswer {
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: .skipped, summary: "helper: \(action.title): the helper did not answer; nothing was sent",
                paths: action.journalPaths, detail: action.journalDetail)
            return .refused(silent.detail)
        } catch is PrivilegedActionCancelled {
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: .skipped, summary: "helper: \(action.title): cancelled at the password dialog",
                paths: action.journalPaths, detail: action.journalDetail)
            return .cancelled
        } catch {
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: .failed, summary: "helper: \(action.title): \(error)", paths: action.journalPaths,
                detail: action.journalDetail)
            return .failed("\(error)")
        }
    }
}
