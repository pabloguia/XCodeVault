import Foundation

/// The complete privileged API. Every verb names a closed set of resources; nothing here accepts a
/// path, a command, or an argument array from the client (SECURITY_MODEL.md). Both the app/CLI
/// and the daemon link this module and nothing else crosses the XPC boundary.
@objc public protocol XCodeVaultHelperXPC {
    /// Helper build identification, for version-skew checks.
    func version(reply: @escaping @Sendable (String) -> Void)

    /// Opens this connection for the verbs below (M5, ADR-0016). The client states its version; the helper refuses
    /// unless it is exactly its own (`HelperIdentity.version`), and refuses every other verb on a connection where this
    /// has not succeeded. With the client's own check of `version()` first, a mismatched pair is refused from either
    /// side before anything is done: an older app (which never sends this) meets a newer helper, or a newer app an
    /// older one. The version is the client's word, and that is enough here: the client's code signature is already
    /// checked (`clientRequirement`), so whatever sends it is one of our signed builds, and a build cannot be altered
    /// without breaking that signature.
    func begin(clientVersion: String, reply: @escaping @Sendable (HelperResult) -> Void)

    /// Deletes the contents of one root-owned, regenerable directory chosen from
    /// `HelperCleanupTarget`. The helper maps the raw value to a fixed absolute path itself.
    ///
    /// **Not offered by this helper release** (ADR-0016): the verb has no in-use check of its own, so the daemon
    /// refuses it with `verbNotOffered` whoever asks. The app shows the manual route instead.
    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void)

    /// Creates `<mount point>/<VaultDirectory.name>` on a mounted external volume identified by UUID
    /// and hands ownership to the *calling* user (uid/gid taken from the XPC connection's audit
    /// credentials, never from the request). The helper resolves the UUID to a mount point itself;
    /// the client cannot pass a path.
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void)

    /// Forgets what the cleanup verb previously observed at an allowlisted target (issue #24).
    ///
    /// The cleanup verb refuses when a target that was last seen as a mount point is now a plain
    /// directory, because that is the local half of a split brain. When the volume is genuinely gone
    /// for good that refusal is correct and permanent, and this is the only thing that lifts it.
    ///
    /// It takes the same closed enum as the cleanup verb — no path crosses the wire — and it is a
    /// separate call on purpose: forgetting re-enables deletion, so the user's intent is stated, and
    /// audited, before anything is removed.
    ///
    /// Not offered by this helper release either (ADR-0016): it only re-enables the cleanup verb.
    func forgetMountObservation(target: String, reply: @escaping @Sendable (HelperResult) -> Void)

    /// Turns ownership on for one mounted external volume, identified by UUID (R8, ADR-0014). EXPERIMENTAL (rule 10).
    ///
    /// The client sends the volume UUID and the externalized form of an `AuthorizationRef` on which it has just
    /// obtained `HelperIdentity.enableOwnershipRight` (the system password dialog, every call). Nothing else: no path,
    /// no device node, no command text. The helper re-checks the right from that form without any dialog of its own,
    /// resolves the UUID to a volume itself, refuses anything that is not a mounted, local, writable, external APFS or
    /// HFS+ volume — never the boot volume, its container, a disk image or a Time Machine backup — then runs
    /// `/usr/sbin/diskutil enableOwnership <the bare disk identifier of the mount it holds open>` and verifies by reading
    /// the volume again.
    func enableOwnership(volumeUUID: String, authorization: Data, reply: @escaping @Sendable (HelperResult) -> Void)
}

/// The vault directory's name, which is part of the client↔helper contract: the helper creates it,
/// the client expects to find it there. It lives in this module — the only one both sides link —
/// so the two cannot drift into disagreeing about which directory the privileged verb produced.
///
/// The helper deliberately does not depend on `XCodeVaultCore` (minimal, auditable attack surface),
/// and `XCodeVaultCore` is declared with no dependencies at all, so neither can see the other's
/// literals: `VaultVolume.directoryName` repeats this string rather than referencing it. The two are
/// kept honest by `HelperContractTests`, which links both modules and asserts they are equal — the
/// one place in the build where that comparison is possible.
public enum VaultDirectory {
    /// Capital "C", matching the project's own spelling. On a case-sensitive volume this is a
    /// different directory from `XcodeVault`, so the spelling is load-bearing, not cosmetic.
    public static let name = "XCodeVault"
}

/// Allowlisted cleanup targets. The helper owns the path mapping; the enum exists so clients cannot
/// even express another path.
public enum HelperCleanupTarget: String, CaseIterable, Sendable {
    case coreSimulatorDyldCache = "coreSimulatorDyldCache"  // /Library/Developer/CoreSimulator/Caches/dyld
    case cryptexCaches = "cryptexCaches"  // /Library/Developer/CoreSimulator/Cryptex/Caches

    public var path: String {
        switch self {
        case .coreSimulatorDyldCache: return "/Library/Developer/CoreSimulator/Caches/dyld"
        case .cryptexCaches: return "/Library/Developer/CoreSimulator/Cryptex/Caches"
        }
    }
}

/// What a verb's result means, as a closed vocabulary (R8). The message is prose for a person; this is what code reads
/// — the app's fallback decision and the audit trail, which logs it `.public` because no caller text can reach it.
///
/// `none` for the verbs that predate it and for a daemon too old to send it; `unknown` for a value this build does not
/// know (a newer daemon), so a client never mistakes an unfamiliar code for success.
public enum HelperResultCode: String, Sendable, CaseIterable {
    case none = ""
    case unknown
    /// The administrator gate refused the caller.
    case unauthorized
    /// An argument failed validation (an unparsable or all-zero UUID).
    case invalidArgument
    /// The authorization form was not a valid externalized reference.
    case authorizationMalformed
    /// The reference does not hold the right.
    case authorizationDenied
    /// The right's definition could not be put in place, or was wrong and has just been repaired.
    case authorizationUnavailable
    /// No mounted volume has that UUID, or its identity could not be read consistently.
    case volumeNotFound
    /// The volume is one this verb never touches.
    case volumeIneligible
    /// Ownership was already on; nothing was run.
    case alreadyEnabled
    /// Ownership was turned on and verified.
    case enabled
    /// `diskutil` failed, timed out, or could not be started.
    case commandFailed
    /// `diskutil` reported success, and reading the volume again does not show ownership on.
    case notVerified
    /// The user cancelled the system password dialog. Produced by the client only, before anything is sent: the
    /// helper never replies with it.
    case authorizationCanceled
    /// The helper that answered is OLDER than this build (R8 fix rounds 4 and 5): produced by the client only, before
    /// any password is asked; the app reinstalls the helper through the approval flow and tries once more.
    case helperOutdated
    /// The helper that answered is NEWER than this build, or of a version this build cannot order (R8 fix round 5, F2):
    /// produced by the client only, before any password is asked. Never a reason to reinstall — that would put an older
    /// daemon in place of a newer one — so the app falls back to the guided route with the reason.
    case helperNewer
    /// The client's version is not this helper's (M5, ADR-0016): from `begin`, or from a verb sent before `begin`
    /// succeeded on the connection.
    case clientVersionMismatch
    /// The verb is not offered by this helper release (ADR-0016): the cleanup verb and its companion.
    case verbNotOffered
}

/// Result envelope; `NSSecureCoding` so it can cross XPC.
@objc public final class HelperResult: NSObject, NSSecureCoding, Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let ok: Bool
    public let message: String
    public let bytesFreed: UInt64
    public let code: HelperResultCode

    public init(ok: Bool, message: String, bytesFreed: UInt64 = 0, code: HelperResultCode = .none) {
        self.ok = ok; self.message = message; self.bytesFreed = bytesFreed; self.code = code
    }
    public required init?(coder: NSCoder) {
        ok = coder.decodeBool(forKey: "ok")
        message = coder.decodeObject(of: NSString.self, forKey: "message") as String? ?? ""
        bytesFreed = UInt64(coder.decodeInt64(forKey: "bytesFreed"))
        let raw = coder.decodeObject(of: NSString.self, forKey: "code") as String? ?? ""
        code = HelperResultCode(rawValue: raw) ?? .unknown
    }
    public func encode(with coder: NSCoder) {
        coder.encode(ok, forKey: "ok"); coder.encode(message as NSString, forKey: "message"); coder.encode(Int64(bytesFreed), forKey: "bytesFreed")
        coder.encode(code.rawValue as NSString, forKey: "code")
    }
}

public enum HelperIdentity {
    public static let machServiceName = "com.xcodevault.helper"
    public static let plistName = "com.xcodevault.helper.plist"
    public static let bundleIdentifier = "com.xcodevault.helper"
    /// The authorization right `enableOwnership` requires (R8, ADR-0014). The daemon defines it — root, at startup and
    /// again on every call — with its own rule: admin group, a 10-second unshared credential, never root (fix round 4);
    /// the client obtains it with the system password dialog
    /// and sends its externalized form; the daemon re-checks it from that form, never on a reference of its own.
    public static let enableOwnershipRight = "com.xcodevault.helper.enable-ownership"
    /// Code-signing requirement the daemon enforces on every client: Apple-anchored Developer ID
    /// chain (leaf + intermediate marker OIDs), our team, and one of our two client identifiers.
    /// `TEAMID_PLACEHOLDER` is substituted at bundle time by scripts/bundle-app.sh; a helper built without it
    /// refuses every connection. No version predicate here: the minimum version is held by `begin`, which the daemon
    /// requires on every connection before any verb (M5, ADR-0016). A predicate could only compare strings, and the
    /// CLI, a bare Mach-O, has no Info.plist to compare.
    public static func clientRequirement(teamID: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"\(teamID)\" and (identifier \"com.xcodevault.app\" or identifier \"com.xcodevault.xcodevaultctl\")"
    }
    /// Code-signing requirement a **client** must enforce on the daemon it connects to.
    ///
    /// **The asymmetry this closes (issue #30).** The daemon has always validated its clients; until
    /// now nothing described the reverse, because nothing connects yet. A client that resumes a
    /// connection to `machServiceName` without setting this is talking to whatever holds that name
    /// in the global bootstrap namespace, and acts on its replies.
    ///
    /// Stated at its real strength, because an earlier version of this comment overstated it and
    /// this project treats that as the worse error: claiming the name there requires a LaunchDaemon
    /// installed as root, so a *fresh* impostor already presupposes root. What this genuinely
    /// defends against is the stale case — an uninstalled-but-still-registered daemon that keeps
    /// answering — and a downgraded or third-party binary holding the name. Both are ordinary, and
    /// neither needs an attacker.
    ///
    /// **It pins `bundleIdentifier`, and that is coupled to a flag in the build script.** The daemon
    /// is a bare Mach-O with no `Info.plist`, so `codesign` would default its identifier to the
    /// binary's basename; `scripts/bundle-app.sh` passes `--identifier com.xcodevault.helper`
    /// explicitly. Drop that flag and this requirement rejects the real daemon. Nothing else holds
    /// that coupling, which is why it is written down here.
    ///
    /// No version predicate here either. A client's requirement refuses the peer's *reply*, not the request, so an old
    /// daemon still holding the name would act on a verb first (xpc/connection.h:790-793; measured in-process
    /// 2026-09-28, helper-security review of deliverable 4; ours never exits, `main.swift`), predicate or not. What
    /// refuses a downgraded or stale helper is `HelperClient.opening` (M5, ADR-0016): a validated `version()` round
    /// trip, then `begin`, on the connection the verb will use, before the verb; an interruption is a failure.
    ///
    /// Same anchor and same marker OIDs as `clientRequirement`, differing only in the identifier —
    /// deliberately, so that weakening one and not the other is visible as a diff rather than as a
    /// plausible-looking constant. `HelperIdentityRequirementTests` asserts they stay in step.
    ///
    /// **Where the team ID comes from, stated accurately after getting it wrong twice.**
    /// `scripts/bundle-app.sh` substitutes `teamIDPlaceholder` into the *daemon's* `main.swift` and
    /// nowhere else — `grep -rn TEAMID_PLACEHOLDER Sources/` finds it only there. An earlier version
    /// of this paragraph said `TEAMID` (the wrong token — the same confusion that produced a
    /// placeholder detector unable to detect the placeholder) and claimed the client side was
    /// substituted "exactly as" the daemon is. It is not, and the consequence is concrete: the
    /// client M4 writes has no supply of a team ID at all.
    ///
    /// **Both halves of that TODO are now done** (issue #30), and this paragraph says so rather
    /// than being left to be inherited as still-open: `scripts/bundle-app.sh` substitutes the team
    /// ID into `Sources/XCodeVaultHelperClient/HelperClient.swift` as well as the daemon's
    /// `main.swift`, asserting each substitution landed separately; and `HelperClient.connect()`
    /// throws `Failure.unusableTeamID` without touching the connection when `isUsableTeamID` is
    /// false. `HelperClientTests` pins both, including that a refused connection is never resumed.
    ///
    /// `HelperClient` consumes this function. What is still gated on signing is the *live*
    /// connection: no build has had a real Developer ID team ID, which both ends of the connection
    /// require, so no verb has been driven end to end and `COMPATIBILITY_MATRIX.md` records that as
    /// pending, not as working.
    ///
    /// **What the invariants rule does and does not do about that**, stated carefully because an
    /// earlier version of this paragraph described a rule the same change had already replaced. It
    /// is a prohibition: no file outside its allowlist may open a connection to the daemon at all.
    /// So the client cannot land without a line being added to that allowlist in the same diff,
    /// which is where a reviewer sees the peer validation. Nothing in CI requires the client to call
    /// *this function*, or to set any requirement once its file is allowlisted — review holds that.
    public static func helperRequirement(teamID: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleIdentifier)\""
    }

    /// The literal `scripts/bundle-app.sh` substitutes at bundle time, and `main.swift` ships until
    /// it does. Declared here so the three places that must agree on it cannot drift apart —
    /// `HelperIdentityRequirementTests` reads the other two and fails when they do.
    public static let teamIDPlaceholder = "TEAMID_PLACEHOLDER"

    /// Whether a team ID is one this project can actually validate against, or a build artefact.
    ///
    /// **Named for the condition rather than for the string, after getting the string wrong.** The
    /// first version asked whether a requirement contained `"TEAMID"`, and this build system ships
    /// `TEAMID_PLACEHOLDER` — so it answered "fine" for the only unsubstituted state it can produce,
    /// which is a false negative on exactly the condition it is named after. A reviewer caught it;
    /// the test passed only because it synthesised a team `bundle-app.sh` would have rejected.
    ///
    /// It now checks what actually matters: a usable Apple team ID is ten characters of `[A-Z0-9]`,
    /// which `bundle-app.sh` already enforces on the way in. That catches the placeholder, an empty
    /// string, and the likelier failure of a `sed` that matched nothing and left something malformed.
    ///
    /// **Why it exists at all.** On the daemon an unusable team fails safe: no certificate satisfies
    /// the requirement, so every client is refused. On a *client* the temptation runs the other way
    /// — "the requirement looks wrong, connect anyway" — so the condition is a named function rather
    /// than a comparison invented at the call site.
    public static func isUsableTeamID(_ teamID: String) -> Bool {
        teamID.count == 10 && teamID.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    public static let version = "0.3.0-dev"
}
