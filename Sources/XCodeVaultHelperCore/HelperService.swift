// The privileged helper's logic, in a library target so that it can be tested.
//
// Split out of `main.swift` on 2026-09-17, on a security reviewer's recommendation and for a
// concrete reason: the authorization gate below shipped with a defect (`getgrouplist`'s overflow
// contract on Darwin is the opposite of what the code assumed) that a three-line test would have
// caught, and no test could reach it while it lived in an executable target.
//
// **This library is depended on by the helper executable and the test target, and by nothing
// else.** Not the app, not the CLI. The helper checks its own invariants rather than inheriting
// them from a module anyone can link. That property is a convention held by review of
// `Package.swift`, **not** something `scripts/helper-invariants.sh` enforces — the script does not
// read `Package.swift` at all. Do not let a comment stand in for a check.

import Foundation
import XCodeVaultHelperProtocol

// XCodeVault privileged helper — a root LaunchDaemon registered with SMAppService.daemon.
// Every verb is a fixed operation on a fixed resource. There is no Process/shell anywhere in this
// target on purpose: .claude/hooks/helper-guard.sh blocks it, and the security review checks it.

/// All privileged work runs on one serial queue: connections never race each other, and the
/// per-connection caller identity (uid/gid from the audit token) is captured at accept time.
let privilegedWork = DispatchQueue(label: "com.xcodevault.helper.work")

// `@unchecked` and the reason, rather than six compiler warnings nobody reads: one instance per
// connection, every stored property a `let` scalar, and all privileged work serialized on one
// queue, so no shared mutable state is reachable from two connections. The unchecked part is
// `NSObject`, which is not `Sendable` — the reply closures are declared `@escaping @Sendable` in
// the protocol and are not the reason.
final class HelperService: NSObject, XCodeVaultHelperXPC, @unchecked Sendable {
    let callerUID: uid_t
    let callerGID: gid_t
    init(callerUID: uid_t, callerGID: gid_t) { self.callerUID = callerUID; self.callerGID = callerGID }

    /// The caller's name and primary gid. Seams like this one exist so the gate can be tested;
    /// see the target header for why that is not optional here.
    ///
    /// The authorization contract used to be pasted here as well, which attributed it to a
    /// `getpwuid` wrapper that performs no authorization. It lives on `isAdministrator`, the gate
    /// it actually describes.
    static func passwdLookup(_ uid: uid_t) -> (name: String, gid: Int32)? {
        guard let pw = getpwuid(uid) else { return nil }
        return (String(cString: pw.pointee.pw_name), Int32(bitPattern: pw.pointee.pw_gid))
    }

    static func adminGroupID() -> Int32? {
        guard let gr = getgrnam("admin") else { return nil }
        return Int32(bitPattern: gr.pointee.gr_gid)
    }

    /// Every group the account belongs to, or nil when that cannot be determined.
    ///
    /// Darwin's `getgrouplist` does **not** report the needed size on overflow: it sets `*ngroups`
    /// to the truncated count, which is exactly the capacity that was passed in. Measured on
    /// macOS 26.7 (25G229):
    ///
    ///     cap=1  -> rc=-1 n=1      cap=4  -> rc=-1 n=4      cap=64 -> rc=0 n=17
    ///
    /// The first version of this function grew the buffer only when `n > capacity`, which therefore
    /// never happened: the retry was unreachable and any administrator with more than 64 group
    /// memberships — the directory-bound account this is meant to serve — was refused outright.
    /// Growth is driven by `rc < 0` instead, which is the documented failure signal.
    /// `seedCapacity` exists only so a test can drive the growth path on a machine with fewer than
    /// 64 groups, which is every machine this will ever run on and every CI runner. Without it the
    /// retry is untested — which is exactly the state that produced the defect it replaced.
    static func groupList(_ name: String, _ baseGID: Int32, seedCapacity: Int32 = 64) -> [Int32]? {
        var capacity = max(seedCapacity, 1)
        while capacity <= 4096 {
            var buf = [Int32](repeating: 0, count: Int(capacity))
            var n = capacity
            let rc = name.withCString { getgrouplist($0, baseGID, &buf, &n) }
            if rc >= 0 { return Array(buf.prefix(Int(max(n, 0)))) }
            capacity *= 4
        }
        return nil
    }

    /// Every state-changing verb requires the caller to be an administrator.
    ///
    /// The code-signing requirement decides which *binary* may connect. It says nothing about which
    /// *user* is driving that binary — and the shipped CLI is a Developer-ID-signed, world-executable
    /// client that satisfies the requirement by construction. Without this check the caller set was
    /// every local account, including non-admin and service accounts, for verbs that delete files as
    /// root and change ownership. `callerUID >= 500` further down is a "not a system account" filter,
    /// which is not the same question and does not stop a perfectly ordinary user.
    ///
    /// **Admin-group membership is not user consent.** There is no prompt: any process already
    /// running as a logged-in administrator passes silently. This strictly shrinks the caller set
    /// and is proportionate to these two verbs, but do not read it as an authorization dialogue.
    /// A real right would have to arrive as an externalized authorization reference from a client,
    /// and no client exists yet. Group membership rather than the Security framework's rights API:
    /// `SECURITY_MODEL.md` forbids the null-authorization form outright (the CVE-2025-65842
    /// pattern), so `AuthorizationCopyRights(NULL, …)` is not an option here, not merely a weaker
    /// one.
    ///
    /// **Fails closed.** Any failure to resolve the caller, the admin group, or the group list
    /// refuses; "I cannot tell whether you are an administrator" is not a yes.
    static func isAdministrator(
        uid: uid_t,
        passwd: (uid_t) -> (name: String, gid: Int32)? = HelperService.passwdLookup,
        adminGroup: () -> Int32? = HelperService.adminGroupID,
        groups: (String, Int32) -> [Int32]? = { HelperService.groupList($0, $1) }
    ) -> Bool {
        if uid == 0 { return true }
        guard let pw = passwd(uid), let admin = adminGroup() else { return false }
        if pw.gid == admin { return true }
        guard let list = groups(pw.name, pw.gid) else { return false }
        return list.contains(admin)
    }

    /// The one message `authorize()` refuses with, as a constant rather than a literal.
    ///
    /// It is a constant so the audit can classify an outcome from the result the caller actually
    /// received, instead of evaluating the gate a second time. A reviewer found the second
    /// evaluation: the dispatch called `authorize()` to label the record and the verb called it
    /// again to enforce, and the two can disagree — a transient directory-service failure on the
    /// first and success on the second means the verb **performs the work** while the log records
    /// `refused-unauthorized`. That is the line this trail exists for, wrong in the direction that
    /// conceals a performed action.
    ///
    /// Comparing against this constant is a string comparison, which is ordinarily a poor way to
    /// carry a decision — but the string is owned by this file, produced at exactly one site, and
    /// `HelperAuditAndVolumeTests` fails if any other refusal in this target adopts it.
    static let unauthorizedMessage = "not authorized: this operation requires an administrator account"

    /// Returns a refusal when the caller may not perform a state-changing operation, `nil` when it may.
    private func authorize() -> HelperResult? {
        guard Self.isAdministrator(uid: callerUID) else {
            return HelperResult(ok: false, message: Self.unauthorizedMessage)
        }
        return nil
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        // Audited too, though it changes nothing and needs no gate. A reviewer asked why it was
        // the one verb with no record: reconstructing an incident is easier when the trail shows
        // that a client connected and probed at all, and "the only unlogged verb" is a gap a
        // future change could widen without noticing. It stays synchronous — there is no
        // privileged work to serialise — so it is exempt from the dispatch rule in
        // `scripts/helper-invariants.sh`, which reads the verb list from the protocol minus
        // `version`.
        HelperAudit.emit(
            .from(verb: "version", callerUID: callerUID, validatedArguments: [:], result: HelperResult(ok: true, message: "version"), wasUnauthorized: false))
        reply(HelperIdentity.version)
    }

    // Both verbs are audited **here**, at the dispatch, rather than inside the `do…` functions
    // (issue #4). Two reasons, and the second is the one that matters:
    //
    //   - This is the only place every invocation passes through, including one that returns
    //     early. A record written inside the verb is a record the early returns can skip.
    //   - The `do…` functions are called directly by tests with injected seams. Auditing there
    //     would put test invocations in the machine's real unified log, and a log whose entries
    //     are partly synthetic is worse for reconstructing an incident than one that is empty.
    //
    // The audit is written after the reply is computed and before it is sent, so nothing can be
    // returned to a caller that was not first recorded.

    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async {
            let result = self.doRemoveRegenerableSystemDirectoryContents(target: target)
            HelperAudit.emit(
                .from(
                    verb: "removeRegenerableSystemDirectoryContents", callerUID: self.callerUID,
                    // Canonical, never the raw parameter. The field's contract is "the arguments
                    // *after* validation", and passing `target` straight through broke it: a
                    // reviewer pointed out that validation happens inside the verb, so the audit
                    // was being handed the unvalidated client string. Nothing leaked — it is
                    // hashed — but the hash was the only thing between an attacker-chosen
                    // multi-megabyte `target` and a root-owned log.
                    validatedArguments: ["target": HelperCleanupTarget(rawValue: target)?.rawValue ?? "<rejected>"],
                    result: result, wasUnauthorized: Self.wasUnauthorized(result)))
            reply(result)
        }
    }
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async {
            let result = self.doCreateVaultDirectory(volumeUUID: volumeUUID)
            HelperAudit.emit(
                .from(
                    verb: "createVaultDirectory", callerUID: self.callerUID,
                    validatedArguments: ["volumeUUID": UUID(uuidString: volumeUUID)?.uuidString ?? "<rejected>"],
                    result: result, wasUnauthorized: Self.wasUnauthorized(result)))
            reply(result)
        }
    }

    func forgetMountObservation(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async {
            let result = self.doForgetMountObservation(target: target)
            HelperAudit.emit(
                .from(
                    verb: "forgetMountObservation", callerUID: self.callerUID,
                    validatedArguments: ["target": HelperCleanupTarget(rawValue: target)?.rawValue ?? "<rejected>"],
                    result: result, wasUnauthorized: Self.wasUnauthorized(result)))
            reply(result)
        }
    }

    /// Whether this result is the authorization gate's refusal — read from the result the caller
    /// actually received, so the record and the enforcement cannot come from two evaluations that
    /// disagree. See `unauthorizedMessage`.
    static func wasUnauthorized(_ result: HelperResult) -> Bool {
        !result.ok && result.message == unauthorizedMessage
    }

    /// `base` is a test seam. Production passes nothing and walks from `/`.
    ///
    /// Stated precisely, because an earlier version of this comment flattered it: `base` is not
    /// *only* a trust anchor. It prefixes the target (`base + t.path`) and it determines the
    /// required owner (whoever owns the anchor). One parameter therefore does everything the
    /// `requiredOwner` knob this change removed did, plus choosing where the deletion happens —
    /// and measured against the parent commit, where this verb was `private`, that widens the
    /// in-module surface of a root deletion verb.
    ///
    /// What makes it acceptable rather than a worse version of what it replaced: it is not
    /// reachable from a client (the XPC protocol has one parameter, `target`, and the dispatch
    /// at the top of this type passes only that), `XCodeVaultHelperCore` is depended on by the
    /// helper executable and the test target and nothing else, and anchoring at `/` while
    /// demanding a non-root owner is refused outright. The alternative was leaving both guards
    /// of this verb unkillable by mutation, which is the condition this change exists to end.
    ///
    /// `mount` is injected for the same reason `isAdministrator` injects its three lookups: the
    /// `.undetermined` answer is the one this verb must refuse on, and it cannot be staged from a
    /// unit test — an open descriptor keeps answering even after its directory is unlinked, and
    /// making a real mount point needs a volume. Left uninjectable, the arm that *is* issue #2's
    /// fix would be unkillable by mutation, which is the condition this whole change exists to
    /// end. It is a function, not a value: nothing on the XPC wire can supply it.
    func doRemoveRegenerableSystemDirectoryContents(
        target: String,
        under base: String = "/",
        mount: (Int32) -> MountAnswer = HelperService.mountStatus(ofDescriptor:)
    ) -> HelperResult {
        if let denied = authorize() { return denied }
        guard let t = HelperCleanupTarget(rawValue: target) else { return HelperResult(ok: false, message: "unknown target") }
        let dir = base == "/" ? t.path : base + t.path
        // Absence is still "nothing to do" — the caches are regenerable and may simply not exist.
        // Everything past this point is a real directory, and the walk decides whether it is one
        // this daemon is willing to stand on. Note the contract change: a target that exists but
        // is not a directory used to land here too and report "nothing to do"; it now reaches the
        // walk and is refused by name. Tightening, but a change a client renders.
        var probe = stat()
        guard lstat(dir, &probe) == 0 else { return HelperResult(ok: true, message: "nothing to do", bytesFreed: 0) }

        // Every component from the anchor, not just the last one, and mode as well as owner. See
        // openGuardedDirectory for what this closes and why nothing had gone wrong without it.
        let fd: Int32
        switch Self.openGuardedDirectory(dir, under: base) {
        case .success(let d): fd = d
        case .failure(let f): return HelperResult(ok: false, message: "refusing \(dir): component '\(f.component)' \(f.reason)")
        }
        defer { close(fd) }

        // Asked of the DESCRIPTOR, not the name. Fail closed on an unanswerable question: this
        // used to call `isMountPoint`, which returned false both for "not a mount point" and for
        // "could not tell", and proceeded on both.
        // The seam is closed on the shipping path. A review pointed out that `mount:` was open
        // to exactly the objection this change used to delete `requiredOwner` — "a default
        // argument is not a defence against a future in-module caller" — and that an in-module
        // caller passing `{ _ in .isNotMountPoint }` would disable issue #2's fix outright. When
        // the anchor is `/`, which is the only thing production ever passes, the real query is
        // used and the parameter is ignored.
        //
        // UNPINNED, unavoidably: reverting this to a bare `mount(fd)` fails no test, because the
        // branch it protects is the one no test can enter — a test anchored at `/` would walk the
        // real `/Library/Developer/CoreSimulator` and delete it.
        let answer = base == "/" ? Self.mountStatus(ofDescriptor: fd) : mount(fd)

        // What this verb has seen here before (issue #24). Read before acting on `answer`, because
        // the interesting case is the one where `answer` is a truthful `.isNotMountPoint`.
        let history = HelperMountHistory.read(target: t, under: base)
        if case .unreadable(let why) = history {
            // Fail closed. `.none` means "never seen, proceed"; this means "there may be an
            // observation saying stop", and the two must not collapse — the defect this project
            // has now found four times.
            return HelperResult(ok: false, message: "could not read what was previously observed at \(dir) (\(why)); refusing")
        }

        switch answer {
        case .isMountPoint:
            // Record before refusing. This is the observation the whole mechanism turns on, and a
            // refusal that forgets what it saw teaches the next run nothing.
            //
            // **The return value is checked, and the first version of this discarded it.** A
            // reviewer pointed out the asymmetry: the cheap `.wasPlainDirectory` write was guarded
            // and the load-bearing one was not, so an ENOSPC or an EACCES here refused *this* call
            // — which it was going to do anyway — recorded nothing, and let the next call after the
            // disconnect read `.none`, meaning "never seen, proceed", and delete. That is the
            // issue #24 deletion reached with no attacker involved, through the arm that exists to
            // prevent it. On a near-full disk it is not hypothetical.
            if !HelperMountHistory.write(.wasMountPoint, target: t, under: base) {
                return HelperResult(
                    ok: false,
                    message:
                        "\(dir) is a mount point, and this could not be recorded. Nothing was removed — but until the record can "
                        + "be written, a later disconnect will not be told apart from an ordinary cache here.")
            }
            return HelperResult(ok: false, message: "target is a mount point")
        case .undetermined:
            return HelperResult(ok: false, message: "could not determine whether \(dir) is a mount point; refusing")
        case .isNotMountPoint:
            // **The composition this issue is about.** Every check above passed, truthfully. If this
            // path was a mount point when last seen, a plain directory here now is the local half of
            // a split brain — the mount point left in place after a disconnect — and deleting it is
            // exactly what rule 6 forbids: shadow data auto-resolved by removing a copy.
            if case .observed(.wasMountPoint) = history {
                return HelperResult(
                    ok: false,
                    message:
                        "\(dir) was a mount point when last seen and is a plain directory now. That is shadow data left by a "
                        + "disconnect, not a cache. Reconnect the volume and run `xcodevaultctl doctor`; if that volume is gone "
                        + "for good, the helper's `forgetMountObservation` verb clears this record and lifts the refusal. "
                        + "Nothing was removed.")
            }
            // Reached with `history` either `.none` or `.observed(.wasPlainDirectory)` — an earlier
            // comment here said only `.none`, which the ternary below already handled correctly and
            // the prose did not. In this codebase the prose is the review artifact.
            //
            // Recording the ordinary observation is what makes the *next* run able to see a change.
            // A failed write is reported rather than swallowed: it does not endanger this call, but
            // it silently disables the guard for the following one.
            if !HelperMountHistory.write(.wasPlainDirectory, target: t, under: base) {
                return HelperResult(
                    ok: false,
                    message:
                        "could not record what was observed at \(dir), so a later disconnect could not be told apart from an "
                        + "ordinary cache. Nothing was removed.")
            }
        }

        // Everything below is descriptor-relative. The children come from the directory this call
        // walked to and verified — a fixed, root-owned, non-mount-point directory named by an enum
        // and never a client path — not from re-resolving that name a second time.
        // The descriptor is the one the walk verified and has not left this function.
        // helper-invariants: allow deletion
        let outcome = Self.removeContents(of: fd)
        // The success message says what was *checked*, not just what was done (issue #24). A bare
        // "cleaned" is the sentence a shadow-data deletion would also produce, and the issue's
        // minimum ask is that those two cannot render identically. Reached with `history` either
        // `.none` or `.observed(.wasPlainDirectory)` — the `.observed(.wasMountPoint)` branch above
        // returned and the other two were refused earlier — which is why the ternary below has an
        // else at all. An earlier version of this comment said `.none` and so declared that else
        // unreachable, while a test in the same change asserted it. The identical slip was corrected
        // twenty lines up and left standing here.
        let checked = history == .none ? " (no prior mount ever observed here)" : " (previously observed as a plain directory)"
        return HelperResult(
            ok: outcome.failures == 0,
            message: outcome.failures == 0 ? "cleaned \(dir)\(checked)" : "\(outcome.failures) item(s) could not be removed",
            bytesFreed: outcome.freed)
    }

    /// Clears the cleanup verb's record for one target (issue #24).
    ///
    /// This re-enables deletion at a path the verb is currently refusing, so it is gated like every
    /// other state-changing verb and audited before the reply is sent — the trail has to show the
    /// permission being lifted, not only the deletion that follows it.
    ///
    /// It does **not** delete anything itself, and it deliberately does not chain into the cleanup
    /// verb. Two calls means the user states the intent while the data is still there, and it means
    /// no single message can both forget a mount observation and act on having forgotten it.
    ///
    /// `base` is the same test seam `doRemoveRegenerableSystemDirectoryContents` documents, with the
    /// same argument for why it is acceptable: no client can reach it — the XPC protocol declares
    /// one parameter and the dispatch above passes only that.
    func doForgetMountObservation(target: String, under base: String = "/") -> HelperResult {
        if let denied = authorize() { return denied }
        guard let t = HelperCleanupTarget(rawValue: target) else { return HelperResult(ok: false, message: "unknown target") }
        let dir = base == "/" ? t.path : base + t.path
        switch HelperMountHistory.forget(target: t, under: base) {
        case .success(let removed):
            // The two outcomes are reported apart. "There was nothing to forget" and "a refusal has
            // been lifted" are different facts about the machine, and a single cheerful message
            // covering both would let a user believe they had cleared a block they had not.
            return HelperResult(
                ok: true,
                message: removed
                    ? "forgot what was previously observed at \(dir). The next cleanup there will be treated as a first run."
                    : "nothing was recorded for \(dir); no change.")
        case .failure(let f):
            return HelperResult(ok: false, message: "could not forget what was observed at \(dir) (\(f.reason)); nothing was changed.")
        }
    }

    func doCreateVaultDirectory(volumeUUID: String) -> HelperResult {
        if let denied = authorize() { return denied }
        guard UUID(uuidString: volumeUUID) != nil else { return HelperResult(ok: false, message: "invalid UUID") }
        guard callerUID >= 500, callerGID >= 20 else { return HelperResult(ok: false, message: "caller must be a regular user") }
        // Resolve the UUID to a mount point ourselves (getattrlist ATTR_VOL_UUID over getmntinfo_r_np):
        // no client-supplied path, no diskutil parsing, no shared static buffer.
        guard let mp = Self.mountPoint(forVolumeUUID: volumeUUID) else { return HelperResult(ok: false, message: "volume not mounted") }
        // Shape only. The mount-ness of `mp` is asserted below, through the descriptor — asking it
        // of the *path* here and then re-resolving the same name in `open()` was check-and-use on
        // two resolutions, which is exactly what the rest of this function was rewritten to remove
        // (issue #5). A reviewer caught it surviving inside the function that was hardened.
        guard mp.hasPrefix("/Volumes/"), mp.split(separator: "/").count == 2 else {
            return HelperResult(ok: false, message: "only top-level volumes under /Volumes are eligible")
        }
        // The last path component is validated HERE even though it is a compile-time constant no
        // client can influence. Containment of the created directory inside the approved mount point
        // is a property this function is responsible for, and moving the value into
        // XCodeVaultHelperProtocol moved that property out of this file. A leading ".." is the
        // dangerous shape and it is not hypothetical: `mp + "/.."` resolves to /Volumes, lstat sees a
        // directory so mkdir is skipped, O_NOFOLLOW does not constrain "..", and the fchown below
        // would hand /Volumes itself to the caller. A CI assertion in another target is not a
        // substitute for the helper checking its own invariant.
        // Validated on BYTES, not on Characters: `String.contains("/")` compares graphemes, so a
        // "/" carrying a combining mark does not match it — while the kernel splits on the 0x2F
        // byte regardless and the path escapes the mount point. An embedded NUL is the same class:
        // it passes every String-level check and then truncates the C string, leaving `dir` as the
        // volume root, which the fchown below would hand to the caller wholesale.
        let name = VaultDirectory.name
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, !bytes.contains(0x2F), !bytes.contains(0x00), name != ".", name != ".." else {
            return HelperResult(ok: false, message: "invalid vault directory name")
        }
        let dir = mp + "/" + name

        // Everything below goes through a descriptor for the **parent**, never through the path
        // again (issue #5). The previous version did `mkdir(dir)` then `open(dir)`, and between
        // those two calls the name is free: a writer on that volume can rename a different
        // directory into it, and root then `fchown`s whatever it opened. `O_NOFOLLOW` does not
        // help — the thing renamed in is a real directory, not a symlink.
        //
        // `openat` relative to a parent descriptor removes the parent from the race: `mp` is
        // resolved once, and every later step names one component relative to a descriptor that
        // cannot be swapped underneath us. The window between `mkdirat` and `openat` still exists
        // — POSIX offers no create-and-open for directories — so it is closed by *verification*
        // rather than by exclusion, with `fstat` on the descriptor, never `stat` on the path.
        let parentFD = open(mp, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard parentFD >= 0 else { return HelperResult(ok: false, message: "open of volume root failed: \(String(cString: strerror(errno)))") }
        defer { close(parentFD) }
        var parentST = stat()
        guard fstat(parentFD, &parentST) == 0, (parentST.st_mode & S_IFMT) == S_IFDIR else {
            return HelperResult(ok: false, message: "volume root is not a directory")
        }
        // The mount question, asked of the descriptor this function will actually act through.
        // Three-valued, and `.undetermined` refuses: a `/Volumes/<name>` that cannot answer is not
        // a volume this verb may hand to a caller. The sibling cleanup verb was hardened the same
        // way under issue #2 and for the same reason — see `mountStatus(ofDescriptor:)`.
        switch Self.mountStatus(ofDescriptor: parentFD) {
        case .isMountPoint: break
        case .isNotMountPoint:
            return HelperResult(ok: false, message: "only top-level volumes under /Volumes are eligible")
        case .undetermined:
            return HelperResult(ok: false, message: "could not determine whether \(name) sits on a mounted volume; refusing")
        }

        return claimDirectory(inParent: parentFD, named: name, reportedAs: dir)
    }

    /// Creates `name` under an **already-verified** parent descriptor — or adopts it when it is
    /// already there and belongs to the caller — checks that what it opened is what it expected, and
    /// hands it over. The two branches differ: on the create path the check is that the directory is
    /// root-owned, empty and on the parent's device; on the adopt path only the device comparison
    /// applies, and `mayTakeOwnership` carries the rest.
    ///
    /// **Why this is a separate function (issue #28).** Everything it does was inline in
    /// `doCreateVaultDirectory`, below a mount lookup that needs a real volume under `/Volumes` — so
    /// no test could reach it, and both `isTheObjectThisCallJustCreated` and `mayTakeOwnership` were
    /// exhaustively covered *as predicates* while the lines that consult them were covered by
    /// nothing. Deleting either call passed the build, the suite and the invariants script. This
    /// project has already written down why that distinction matters: testing a guard does not pin
    /// the site that reads it.
    ///
    /// **Why a descriptor and not a path, and why this is not the `requiredOwner` knob that was
    /// rejected.** It takes no owner and no device: the uid it grants to is this service's
    /// `callerUID`, and the parent's device number is read from `parentFD` here rather than accepted
    /// from the caller. A descriptor is narrower than a path for the *parent*: an in-module caller
    /// must already hold an open directory to pass one, and nothing on the XPC wire can supply one.
    ///
    /// `parentDevice` **was** a parameter, and a reviewer pointed out the diff contained its own
    /// proof that it should not be: a test passed `0x7FFF_FFFF` and the function accepted it. The
    /// cross-device arm of `isTheObjectThisCallJustCreated` is what catches a volume mounted onto
    /// the name between `mkdirat` and `openat` — the reason any of this runs under `/Volumes` — and
    /// a second caller passing a stale or child device would have disabled it with every test green.
    /// That is the `requiredOwner` shape this paragraph disclaims, in a different field.
    ///
    /// **`name` is the part that is not narrow, and it is validated here rather than trusted.** An
    /// earlier version of this comment claimed the function "takes no path", which was false —
    /// `name` reaches `fstatat`/`mkdirat`/`openat` directly, and a reviewer demonstrated that
    /// `"../OUTSIDE"` creates a directory outside the anchor subtree while `"../VICTIM"` returns
    /// `ok: true` having `fchown`ed one. `O_NOFOLLOW` does not constrain `..`, and intermediate
    /// components in `"link/inner"` resolve through symlinks.
    ///
    /// The caller does validate — `doCreateVaultDirectory` checks the same bytes, under a comment
    /// saying containment "is a property this function is responsible for". Extracting the syscalls
    /// out of that function left the property in one place and its enforcement in another, which is
    /// the split that comment exists to prevent. `openGuardedDirectory`, the precedent this seam
    /// leans on, re-validates every component inside the callee even though its callers validate
    /// too; a non-validating seam cannot borrow a validating seam's argument.
    ///
    /// **What this function does NOT re-check, and therefore what a second caller would owe.** The
    /// argument above — that a non-validating seam cannot borrow a validating seam's argument — was
    /// applied to `name` and, a reviewer noted, silently not applied to anything else.
    /// `doCreateVaultDirectory` still owns all of it: the authorization gate, the `callerUID >= 500`
    /// / `callerGID >= 20` floor, the `/Volumes/<one component>` shape, and the descriptor being a
    /// mount point (`mountStatus(ofDescriptor:)`). This function verifies only that the descriptor
    /// is a directory and that `name` is one safe component. A second caller that skips those is the
    /// trap this extraction invites, and naming them is cheaper than discovering it.
    ///
    /// `reportedAs` is echoed in the success message and is never resolved or acted on.
    ///
    /// **Neither it nor `name` appears in any refusal string**, and that is load-bearing rather than
    /// stylistic: decline messages reach `HelperAudit` and go out `privacy: .public`. An earlier
    /// version interpolated `name` into four of them, which was safe only because the single caller
    /// passes a constant — the byte check above blocks NUL and `/` but not newlines, and that is the
    /// log-injection shape `SECURITY_MODEL.md` already records once. There is exactly one vault
    /// directory name, so the messages lose nothing by not quoting it.
    func claimDirectory(inParent parentFD: Int32, named name: String, reportedAs reportedPath: String) -> HelperResult {
        // On bytes, and for the reason `doCreateVaultDirectory` gives where it does the same: a "/"
        // carrying a combining mark does not match `String.contains("/")` while the kernel splits on
        // the 0x2F byte regardless, and an embedded NUL truncates the C string.
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, !nameBytes.contains(0x2F), !nameBytes.contains(0x00), name != ".", name != ".." else {
            return HelperResult(ok: false, message: "invalid vault directory name")
        }
        var parentST = stat()
        guard fstat(parentFD, &parentST) == 0, (parentST.st_mode & S_IFMT) == S_IFDIR else {
            return HelperResult(ok: false, message: "the parent descriptor is not a directory")
        }
        let parentDevice = parentST.st_dev
        var created = false
        var st = stat()
        if fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "the vault directory name exists and is not a directory") }
        } else if mkdirat(parentFD, name, 0o755) == 0 {
            created = true
        } else {
            return HelperResult(ok: false, message: "mkdir failed: \(String(cString: strerror(errno)))")
        }

        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { return HelperResult(ok: false, message: "open failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "not a directory") }

        switch Self.isTheObjectThisCallJustCreated(
            created: created, directoryDevice: fst.st_dev, parentDevice: parentDevice,
            linkCount: fst.st_nlink, directoryUID: fst.st_uid)
        {
        case .yes: break
        case .differentFilesystem:
            return HelperResult(ok: false, message: "the vault directory is on a different filesystem than the volume root; refusing")
        case .notWhatWeCreated:
            return HelperResult(
                ok: false, message: "the vault directory is not the one this call just created; refusing to take ownership of it")
        }

        guard Self.mayTakeOwnership(created: created, directoryUID: fst.st_uid, callerUID: callerUID) else {
            return HelperResult(ok: false, message: "the vault directory already exists and belongs to uid \(fst.st_uid); refusing to take ownership of it")
        }
        guard fchown(fd, callerUID, callerGID) == 0 else { return HelperResult(ok: false, message: "chown failed: \(String(cString: strerror(errno)))") }
        return HelperResult(ok: true, message: reportedPath)
    }

    // MARK: helpers (no shell, no Process)

    /// Whether the descriptor just opened refers to the object this call created, or to something
    /// that arrived in the meantime.
    ///
    /// Extracted for the reason `mayTakeOwnership` below was, and the file's own note on that one
    /// says it best: *a guard no test can fail is a guard the next refactor deletes.* A reviewer
    /// pointed out that both of these checks were unkillable — no test calls
    /// `doCreateVaultDirectory`, so deleting either passed the build, the suite and the invariants
    /// script. As a pure function over four integers the truth table is exhaustible.
    ///
    /// The three facts, and what each one is actually claiming:
    ///
    /// - **Same filesystem as the parent.** Without it, a volume mounted onto the name between the
    ///   `mkdirat` and the `openat` would be chowned to the caller — and `/Volumes` is precisely
    ///   where a mount appears under a name that was a plain directory a moment earlier. Checked
    ///   whether or not this call created the directory.
    /// - **Exactly two links**, when this call created it: `.` plus the parent's entry and nothing
    ///   else. An empty directory.
    /// - **Owned by root**, when this call created it: root is what created it a moment ago.
    ///
    /// The last two together are a claim about *identity*, not about permissions: a directory
    /// renamed into the name is a directory that existed before, and would have to be both empty
    /// and root-owned to pass.
    ///
    /// **This is a verification, not an exclusion**, and two caveats belong with it rather than in
    /// a commit message. An attacker who can place an empty root-owned directory on that volume
    /// defeats it — which needs root on an ordinary filesystem, and was measured: on a `noowners`
    /// volume an unprivileged `chown 0:0` is `EPERM`, and root reads the true on-disk uid because
    /// XNU applies the `MNT_IGNORE_OWNERSHIP` substitution only for non-superuser callers. But a
    /// userspace filesystem (macFUSE) can fabricate `st_uid`, `st_nlink` and `st_dev` freely, so
    /// there "requires root" is too strong. It buys such an attacker nothing — the verb only
    /// creates and chowns inside that filesystem and reads no content — but the claim is narrower
    /// than it first reads.
    enum CreatedObjectIdentity: Equatable {
        case yes
        case differentFilesystem
        case notWhatWeCreated
    }

    static func isTheObjectThisCallJustCreated(
        created: Bool, directoryDevice: dev_t, parentDevice: dev_t, linkCount: nlink_t, directoryUID: uid_t
    ) -> CreatedObjectIdentity {
        guard directoryDevice == parentDevice else { return .differentFilesystem }
        // A pre-existing directory is not claimed to be ours; `mayTakeOwnership` is what decides
        // whether it may be adopted, and it refuses anything not already owned by the caller.
        guard created else { return .yes }
        guard linkCount == 2, directoryUID == 0 else { return .notWhatWeCreated }
        return .yes
    }

    /// Whether this call may hand `dir` to the caller. A pure decision over three facts, separated
    /// from the filesystem so the truth table can be tested exhaustively — which is the whole
    /// point, because this one guard is the difference between an idempotent re-registration and
    /// root handing one user another user's vault root.
    ///
    /// Only chown what THIS call created. The pre-existing branch used to fall through to the same
    /// `fchown`, so on a volume with ownership enforced any administrator account could name a
    /// volume UUID it does not own and have root hand it the vault root of whoever does — an
    /// ownership change the caller could never perform itself. (`authorize()` restricts both verbs
    /// to administrators, so "any local account" — as this was previously worded — overstated the
    /// reach.) Re-registration by the same user is idempotent and still allowed; anything else is
    /// refused.
    ///
    /// `created` alone is not enough: between `mkdir` returning and `open` succeeding, someone with
    /// write access to that volume can rename a different directory into the path, and the create
    /// branch would then hand it to the caller. A directory this call just made is owned by root,
    /// so requiring that **narrows** the window — it does not close it. `rename(2)` needs write on
    /// the two parent directories, not ownership of the thing moved, so renaming an *already
    /// root-owned* directory into the path still yields `created == true`, `directoryUID == 0`,
    /// and a `true` here. This predicate cannot tell that case from the legitimate one, by
    /// construction: they differ only in provenance, which a uid does not record. Closing it for
    /// real needs what issue #5 asks for — `mkdirat`/`openat` against a descriptor for the parent
    /// and an `fstat` on *that* descriptor — which is why #5 stays open.
    ///
    /// Extracted 2026-09-18. It was previously inline, and a helper-security review confirmed that
    /// replacing it with `true` passed every gate the project has — `swift build`, `swift test`,
    /// `helper-invariants.sh` and `check-doc-mirror.sh`. A guard no test can fail is a guard the
    /// next refactor deletes.
    static func mayTakeOwnership(created: Bool, directoryUID: uid_t, callerUID: uid_t) -> Bool {
        (created && directoryUID == 0) || directoryUID == callerUID
    }

    /// Why a guarded walk refused, so a caller can say which component failed rather than "no".
    struct GuardFailure: Error, Equatable {
        let component: String
        let reason: String
        /// Whether the walk stopped because the component is simply not there.
        ///
        /// A flag rather than something a caller infers from `reason`, because a caller did infer it
        /// from `reason` and got it wrong: `HelperMountHistory` treated "the store does not exist" as
        /// "nothing has ever been recorded, proceed" by matching the suffix `"does not exist"` — the
        /// wording of *its own* message for a missing owned component. An absent trust anchor comes
        /// out of `openat` as `strerror(ENOENT)`, i.e. "No such file or directory", which did not
        /// match, so every cleanup refused permanently on a machine without
        /// `/Library/Application Support`. Nine tests caught it; a user would have seen a verb that
        /// never worked.
        var isAbsence: Bool = false
    }

    /// Opens `path` one component at a time from the root, refusing at any level that is not owned
    /// by `requiredOwner` or that is writable by group or other. Returns an open descriptor on the
    /// final directory, which the caller must close.
    ///
    /// The verb this exists for used to `lstat` only the FINAL component, and check its owner but
    /// not its mode. Both halves were gaps. An intermediate component that is a symlink, or that is
    /// group-writable, lets an unprivileged user redirect or populate a tree that root then walks
    /// and deletes. On a stock machine the whole `/Library/Developer/CoreSimulator` chain is
    /// `root:wheel` or `root:admin` and `0755`, which is why nothing had gone wrong — the safety
    /// property was inherited from the environment rather than enforced here. Measured 2026-09-18.
    ///
    /// `O_NOFOLLOW` on every `openat` is what makes this a walk rather than a resolution: a symlink
    /// at any level fails the open instead of being followed. The descriptor returned here is the
    /// result — callers must act **through** it (`fstatat`/`openat`/`unlinkat`) and must not rebuild
    /// the path, or the check and the use are on two different resolutions of the same name and
    /// this walk buys nothing. `removeContents(of:)` is the worked example.
    ///
    /// `base` is a seam so a test can walk its own temporary tree; production passes nothing and
    /// gets `/`. It is not a relaxation of what is checked — the rule exercised is the rule that
    /// runs — but it is a genuine narrowing of *scope*, and the limits are worth stating:
    ///
    /// - Everything **above** `base` is unvalidated. `open(base)` below resolves `base`'s own
    ///   intermediate components through the ordinary resolver, and `O_NOFOLLOW` constrains only
    ///   `base`'s final component. `base` must therefore be a trusted, already-resolved path.
    /// - `base` is exempt from the `.`/`..`/NUL/slash rejection that every later component gets;
    ///   it is only `fstat`-checked. The `precondition`s below are what stands in for that.
    ///
    /// It has to be a parameter rather than always `/`: a test's temporary directory lives under
    /// `/var`, which on macOS is a symlink to `private/var`, so a walk from `/` correctly refuses
    /// to reach it — the guard working as designed making itself untestable. The tests found that.
    ///
    /// `requiredOwner` is **derived from the anchor** when not given, rather than being a parameter
    /// a caller chooses. That is deliberate: an independent owner knob on a walk that feeds a root
    /// deletion verb is a way to ask root to delete a tree owned by someone else, and a default
    /// argument is not much of a defence. Deriving it means the identity demanded is whoever owns
    /// the trust anchor — root under production's `/`, the test user under a test's own directory —
    /// so there is no way to widen the owner without also moving the anchor. Tests pass it
    /// explicitly only to exercise the *refusal*.
    static func openGuardedDirectory(_ path: String, under base: String = "/", requiredOwner: uid_t? = nil) -> Result<Int32, GuardFailure> {
        precondition(base.hasPrefix("/"), "the trust anchor must be absolute")
        precondition(!base.split(separator: "/").contains(".."), "the trust anchor must not contain '..'")

        // Containment is tested on BYTES for the same reason the split below is. `hasPrefix`
        // compares with canonical equivalence, so "/tmp/cafe\u{301}" prefixes "/tmp/caf\u{e9}"
        // while the byte slice that follows would cut in the wrong place and name a component
        // that was never in the path. Fail-closed either way, but the refusal would lie.
        let pathBytes = Array(path.utf8)
        let baseBytes = Array(base.utf8)
        let anchorBytes = base.hasSuffix("/") ? baseBytes : baseBytes + [0x2F]
        guard pathBytes == baseBytes || pathBytes.starts(with: anchorBytes) else {
            return .failure(GuardFailure(component: path, reason: "is not under the trust anchor \(base)"))
        }
        // Split on the 0x2F BYTE, not on Characters. `split(separator: "/")` compares graphemes, so
        // a "/" carrying a combining mark is not equal to "/" and is not split here — while the
        // kernel splits on the byte regardless. The segment would then reach `openat` containing a
        // slash, where O_NOFOLLOW constrains only its own final component and everything before it
        // resolves through symlinks, unchecked. This is the same lesson `doCreateVaultDirectory`
        // already carries for `VaultDirectory.name`; only its NUL half had been brought across.
        let components = pathBytes.dropFirst(anchorBytes.count).split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }

        var fd = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let e = errno
            // **`ENOENT` only.** `ENOTDIR` was in this test until a reviewer measured what Darwin
            // actually returns: with `O_DIRECTORY` set, `openat` evaluates the type before the
            // symlink rule, so a symlinked component comes back `ENOTDIR`, not `ELOOP` (Darwin
            // 25.6.0 — symlink→dir, symlink→file and a dangling symlink all give `ENOTDIR`; `ELOOP`
            // appears only without `O_DIRECTORY`). Calling that absence tells
            // `HelperMountHistory.read` "nothing was ever recorded here, proceed", which is the
            // deletion this whole mechanism exists to stop — and it contradicted the comment beside
            // the check that promised a symlinked ancestor would refuse. Nothing needs `ENOTDIR`
            // here: a genuinely missing component is `ENOENT`.
            return .failure(GuardFailure(component: base, reason: String(cString: strerror(e)), isAbsence: e == ENOENT))
        }

        // Whoever owns the anchor is the identity every component must match.
        var anchor = stat()
        guard fstat(fd, &anchor) == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            return .failure(GuardFailure(component: base, reason: "fstat failed: \(e)"))
        }
        let owner = requiredOwner ?? anchor.st_uid
        // A machine whose `/` is not root-owned is already lost, but deriving the requirement means
        // saying so rather than inheriting it silently.
        if base == "/" && owner != 0 {
            close(fd)
            return .failure(GuardFailure(component: "/", reason: "root directory is owned by uid \(owner), not 0"))
        }

        func check(_ descriptor: Int32, _ name: String) -> GuardFailure? {
            var st = stat()
            guard fstat(descriptor, &st) == 0 else { return GuardFailure(component: name, reason: "fstat failed: \(String(cString: strerror(errno)))") }
            // Unkillable by construction: every open on this path carries O_DIRECTORY, so the
            // fstat can never see a non-directory. Kept as belt-and-braces; do not read the
            // absence of a mutation kill here as missing coverage.
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return GuardFailure(component: name, reason: "not a directory") }
            guard st.st_uid == owner else { return GuardFailure(component: name, reason: "owned by uid \(st.st_uid), not \(owner)") }
            // Group- or world-writable means someone other than the owner can plant entries that
            // root would then walk. Sticky is not accepted as a mitigation here: it stops one user
            // deleting another's entries, not planting their own.
            guard (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                return GuardFailure(component: name, reason: String(format: "mode %04o is writable by group or other", st.st_mode & 0o7777))
            }
            return nil
        }

        if let f = check(fd, base) { close(fd); return .failure(f) }
        for name in components {
            // `.` and `..` would make the walk meaningless: `..` climbs back out of a component
            // already approved, and O_NOFOLLOW does not constrain it. The slash and NUL checks are
            // on BYTES for the reason given at the split above.
            let bytes = Array(name.utf8)
            guard !bytes.isEmpty, !bytes.contains(0x2F), !bytes.contains(0x00), name != ".", name != ".." else {
                close(fd); return .failure(GuardFailure(component: name, reason: "refusing an empty, relative, slash-bearing or NUL-bearing component"))
            }
            // `O_NONBLOCK` is belt-and-braces here: `O_DIRECTORY` is what rejects a FIFO, immediately
            // and with `ENOTDIR` (measured, Darwin 25.6.0), so this open cannot block and `check`
            // never sees one. An earlier version of this comment credited the flag with preventing a
            // wedge it does not prevent — see `HelperMountHistory`, where the same flag on an open
            // *without* `O_DIRECTORY` genuinely does.
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            // Read **before** the `close`, which is a syscall that may set `errno`. A successful
            // `close` should not, so this was theoretical — but since this diff the value decides
            // `isAbsence`, i.e. proceed-and-delete versus refuse, and that is not a decision to
            // leave resting on "should not".
            let e = errno
            close(fd)
            guard next >= 0 else {
                // `ENOENT` only — see the anchor open above. This is the reachable site: a symlink at
                // `/Library` or `/Library/Application Support` arrives here as `ENOTDIR`.
                return .failure(GuardFailure(component: name, reason: String(cString: strerror(e)), isAbsence: e == ENOENT))
            }
            fd = next
            if let f = check(fd, name) { close(fd); return .failure(f) }
        }
        return .success(fd)
    }

    /// Three answers, because two was a fail-open. `isMountPoint` returned `false` both for "this
    /// is not a mount point" and for "the attribute could not be read", and the cleanup verb read
    /// that as permission to proceed — so a `getattrlist` failure on a real mount point was
    /// indistinguishable from an ordinary directory. The same helper is used fail-*closed*
    /// elsewhere in this file, which is what made the asymmetry a defect rather than a choice.
    enum MountAnswer: Equatable {
        case isMountPoint
        case isNotMountPoint
        /// The question could not be answered. Never treat this as "no".
        case undetermined
    }

    static func mountStatus(_ path: String) -> MountAnswer {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        var buffer = [UInt32](repeating: 0, count: 2)
        let rc = buffer.withUnsafeMutableBytes { raw in getattrlist(path, &attrList, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) }
        // A short reply means the attribute was not returned, which is not the same as a cleared
        // flag — the same class as parsing ATTR_VOL_UUID without ATTR_CMN_RETURNED_ATTRS.
        guard rc == 0, buffer[0] >= 8 else { return .undetermined }
        return (buffer[1] & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 ? .isMountPoint : .isNotMountPoint
    }

    /// The same question asked of an open descriptor instead of a name, which is the only form
    /// that is safe to act on. A path-based answer describes whatever the name resolved to at the
    /// moment it was asked; by the time the caller deletes something, the name may resolve
    /// elsewhere. `simdiskimaged` grafts nested mounts inside the CoreSimulator tree
    /// (`HYPOTHESES.md`), and `Caches/dyld` — one of the two allowlisted cleanup targets — is
    /// exactly the path a canonical-mount strategy would target, so this is not a theoretical
    /// race for this project.
    static func mountStatus(ofDescriptor fd: Int32) -> MountAnswer {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        var buffer = [UInt32](repeating: 0, count: 2)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlistat(fd, ".", &attrList, raw.baseAddress, raw.count, UInt(FSOPT_NOFOLLOW))
        }
        guard rc == 0, buffer[0] >= 8 else { return .undetermined }
        return (buffer[1] & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 ? .isMountPoint : .isNotMountPoint
    }

    /// Convenience for callers where an unanswerable question is not a safety decision.
    ///
    /// **Two callers, and one of them is a guard.** `allocatedBytes` is the accounting use this
    /// exists for, where guessing wrong costs a wrong number rather than a wrong deletion.
    /// `doCreateVaultDirectory` also uses it in a `guard`, and that is safe only because the guard
    /// requires `true`: `.undetermined` collapses to `false` and the call is refused. Anything
    /// that needs `.undetermined` to *stop* it must use `mountStatus` and handle the case, because
    /// the collapse is fail-open in that direction.
    ///
    /// In `allocatedBytes` the collapse means "do not skip", i.e. **descend** — which is fail-open,
    /// and is held closed there only by `FTS_XDEV`.
    static func isMountPoint(_ path: String) -> Bool { mountStatus(path) == .isMountPoint }

    /// Deletes the contents of the directory `fd` refers to, never the directory itself
    /// (CoreSimulator recreates the caches in place).
    ///
    /// Everything here is descriptor-relative: `fstatat`, `openat` and `unlinkat` against `fd`,
    /// never a rebuilt path. That is the whole point. The previous implementation walked to the
    /// target with `openat`, closed the descriptor, and then did the work with
    /// `FileManager.removeItem(atPath:)` on a freshly resolved string — so the walk proved
    /// something about an inode and the deletion acted on a name. Two independent reviews found
    /// it; the guard was decorative.
    ///
    /// `st_dev` is compared against the parent on every entry, so the recursion cannot cross a
    /// mount point. `removeItem` uses `removefile(3)` with `REMOVEFILE_RECURSIVE`, which descends
    /// across mounts — while `allocatedBytes` right below sets `FTS_XDEV` and refuses to. Being
    /// careful about counting bytes across a mount and careless about deleting across one was the
    /// asymmetry.
    ///
    /// Names are collected before anything is unlinked: POSIX leaves `readdir` unspecified for
    /// entries not yet returned when the directory is modified during the scan.
    ///
    /// The byte count is an **upper bound on space reclaimed**, not a measurement of it.
    /// `st_blocks * 512` is the file's logical allocation, so an APFS clone is credited in full
    /// to every copy although deleting one frees nothing — and CoreSimulator clones runtime
    /// files heavily into exactly these caches. A hard-linked file is likewise credited in full
    /// although space comes back only with the last link. Do not present it as space recovered.
    static func removeContents(of fd: Int32, depthRemaining: Int = 64) -> (freed: UInt64, failures: Int) {
        // The `1` is belt-and-braces rather than the signal: hitting the limit leaves the deep
        // tree in place, so every enclosing `AT_REMOVEDIR` up the spine fails ENOTEMPTY and the
        // verb reports `ok: false` regardless. Mutating it to `0` changes no observable outcome.
        guard depthRemaining > 0 else { return (0, 1) }

        // UNPINNED, knowingly (this and the `dup`/`fdopendir` failures below): all three are
        // fail-closed in behaviour but indistinguishable in the reply — "1 item(s) could not be
        // removed" also means "nothing was enumerated and nothing was deleted".
        var parent = stat()
        guard fstat(fd, &parent) == 0 else { return (0, 1) }

        // fdopendir takes ownership of the descriptor it is given and closedir closes it, so it
        // gets a duplicate; `fd` remains the caller's.
        let scan = dup(fd)
        guard scan >= 0, let dir = fdopendir(scan) else {
            if scan >= 0 { close(scan) }
            return (0, 1)
        }
        // The `String(cString:)` round-trip is exact on the filesystems this verb's targets
        // live on: APFS and HFS+ reject filenames that are not valid UTF-8, so creating one
        // fails with EILSEQ (measured 2026-09-18) and a name out of `readdir` re-encodes to the
        // bytes it went in as. That is a property of those filesystems, not of this function —
        // it takes any descriptor, and on exFAT, FAT or SMB the premise does not hold. Callers
        // outside the two allowlisted `HelperCleanupTarget` paths must not assume it.
        var names: [String] = []
        // `readdir` returns NULL for both end-of-stream and error, and only errno tells them
        // apart. Without this, an I/O error part-way through truncates the listing, the loop
        // finishes with no failures, and the verb replies "cleaned" over contents still on disk —
        // the same fail-open this change closed at `fdopendir` and left open one line later.
        errno = 0
        var readFailure = 0
        while let entry = readdir(dir) {
            var e = entry.pointee
            let name = withUnsafePointer(to: &e.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        // UNPINNED, knowingly: reaching it needs a real I/O error mid-enumeration.
        if errno != 0 { readFailure = 1 }
        closedir(dir)

        var freed: UInt64 = 0
        var failures = readFailure
        for name in names {
            var st = stat()
            // A child that cannot be stat'd is a failure, not a skip: silently continuing let an
            // unreadable or vanished entry produce `ok: true, "cleaned"`.
            //
            // UNPINNED, knowingly. Removing the `failures += 1` here passes every test. Reaching
            // it needs the entry to disappear between `readdir` and `fstatat`, which is a race no
            // fixture can stage deterministically — the obvious lever, an invalid-UTF-8 name, is
            // refused by the filesystem itself (EILSEQ, see above).
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { failures += 1; continue }
            // Never follow or delete through a symlink.
            if (st.st_mode & S_IFMT) == S_IFLNK { failures += 1; continue }
            // A different device means a mount is grafted here. Refuse rather than delete it.
            //
            // UNPINNED, knowingly. Removing this check passes every test: staging it needs a real
            // mount inside the fixture, which a unit test cannot make without a volume. It is the
            // check that stops this recursion doing what `removeItem`'s REMOVEFILE_RECURSIVE does
            // — descend across a mount — so its being unpinned is worth saying out loud rather
            // than leaving for the next mutation run to rediscover.
            guard st.st_dev == parent.st_dev else { failures += 1; continue }

            let size = UInt64(st.st_blocks) * 512
            if (st.st_mode & S_IFMT) == S_IFDIR {
                // UNPINNED, knowingly: `O_NOFOLLOW` here survives its own removal because the
                // `S_IFLNK` check above catches the symlink first. It is not redundant — it is
                // the only defence against the entry being swapped for a symlink between that
                // `fstatat` and this `openat` — and redundant-looking but load-bearing is the
                // state most likely to be deleted by a later cleanup.
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { failures += 1; continue }
                // The check above was on a NAME; this one is on the descriptor actually opened.
                // Without it the guard is the very defect this whole change exists to remove: a
                // mount grafted onto `name` between the `fstatat` and the `openat` is descended
                // into, and because the recursion re-derives `parent` from this new descriptor,
                // every entry inside the mounted volume then matches its own device and is
                // deleted. `simdiskimaged` grafts mounts inside this exact tree, unattended.
                //
                // UNPINNED, knowingly: staging it needs a mount to appear between the `fstatat`
                // and the `openat`, which no fixture can arrange.
                var cst = stat()
                guard fstat(child, &cst) == 0, cst.st_dev == parent.st_dev else {
                    close(child)
                    failures += 1
                    continue
                }
                // `child` was opened O_NOFOLLOW from an already-verified descriptor and
                // re-checked above for the same device.
                // helper-invariants: allow deletion
                let inner = removeContents(of: child, depthRemaining: depthRemaining - 1)
                close(child)
                freed += inner.freed
                failures += inner.failures
                // `name` is re-resolved here: Darwin has no `funlinkat(2)`, so a descriptor
                // cannot be unlinked directly. `AT_REMOVEDIR` is `rmdir(2)`, which refuses a
                // non-empty directory, so the worst case is removing an empty directory planted
                // in the window rather than the one just emptied.
                //
                // UNPINNED, knowingly: the `failures += 1` is near-unreachable, because any
                // surviving child already left the directory non-empty and propagated a failure.
                // helper-invariants: allow deletion
                if unlinkat(fd, name, AT_REMOVEDIR) == 0 { freed += size } else { failures += 1 }
            } else {
                // Bytes are counted only once the unlink has succeeded; accumulating first made
                // `bytesFreed` include items that failed to delete.
                // helper-invariants: allow deletion
                if unlinkat(fd, name, 0) == 0 { freed += size } else { failures += 1 }
            }
        }
        return (freed, failures)
    }

    static func allocatedBytes(_ path: String) -> UInt64 {
        var total: UInt64 = 0
        let cPath = strdup(path); defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_D, ent.pointee.fts_level > 0, isMountPoint(String(cString: ent.pointee.fts_path)) { fts_set(fts, ent, FTS_SKIP); continue }
            if info == FTS_F || info == FTS_D || info == FTS_SL, let sp = ent.pointee.fts_statp { total += UInt64(sp.pointee.st_blocks) * 512 }
        }
        return total
    }

    /// The all-zero UUID. A filesystem that succeeds without supplying `ATTR_VOL_UUID` used to
    /// yield exactly this, and it is a perfectly valid `UUID` value — so it compared equal to a
    /// caller who passed the all-zero UUID and acted as a wildcard over every such filesystem.
    /// Rejected on both sides now: never produced from a reply, never accepted as input.
    static let nilVolumeUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Reads one mounted filesystem's volume UUID, or nil when it does not have one.
    ///
    /// Split out so the parsing can be tested against every mounted filesystem on the machine
    /// without going through the verb. Issue #3: the previous version asked for `ATTR_VOL_UUID`
    /// and then parsed bytes 4..<20 of the reply **without asking the kernel whether that
    /// attribute was actually supplied**. `getattrlist` returning 0 does not mean every requested
    /// attribute came back; a filesystem that answers the call without supporting the attribute
    /// left the buffer's zeros in place, and the zeros parse as a valid UUID.
    ///
    /// The fix is the mechanism the kernel provides for exactly this. `ATTR_CMN_RETURNED_ATTRS`
    /// makes the reply lead with an `attribute_set_t` saying which attributes it actually
    /// contains, so "did I get a UUID" becomes a question with an answer instead of an assumption.
    ///
    /// The reply layout that follows from requesting it:
    ///
    ///     offset  0  u_int32_t        length of the whole reply
    ///     offset  4  attribute_set_t  which attributes were returned (5 × u_int32 = 20 bytes)
    ///     offset 24  uuid_t           ATTR_VOL_UUID — present only if the set above says so
    ///
    /// The offset is fixed because `ATTR_VOL_UUID` is the only data attribute requested
    /// (`ATTR_VOL_INFO` is a marker bit and packs nothing). Without `FSOPT_PACK_INVAL_ATTRS` an
    /// unsupported attribute is simply not packed — which is why the flag check has to come first
    /// and why reading offset 24 unconditionally would be reading whatever happened to be there.
    static func volumeUUID(ofMountPoint mp: String) -> UUID? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrList.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw in getattrlist(mp, &attrList, raw.baseAddress, raw.count, 0) }
        guard rc == 0 else { return nil }

        // The reply must be long enough to hold the returned-attribute set at all, and must not
        // claim to be longer than the buffer it was written into.
        let replyLength = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard replyLength >= 24, Int(replyLength) <= buffer.count else { return nil }

        // `attribute_set_t` is { commonattr, volattr, dirattr, fileattr, forkattr }; volattr is
        // the second word, so it starts at offset 4 + 4.
        let returnedVolAttr = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: attrgroup_t.self) }
        guard returnedVolAttr & attrgroup_t(ATTR_VOL_UUID) != 0 else { return nil }
        guard replyLength >= 40 else { return nil }

        let b = Array(buffer[24..<40])
        let volUUID = UUID(
            uuid: (
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
            ))
        // Belt and braces. A filesystem that reports the attribute *and* fills it with zeros is
        // not a volume whose identity happens to be zeros; it is a volume with no identity.
        return volUUID == nilVolumeUUID ? nil : volUUID
    }

    static func mountPoint(forVolumeUUID uuid: String) -> String? {
        // Refused before any filesystem is examined, so the all-zero UUID cannot match by any
        // route — including one that does not go through `volumeUUID(ofMountPoint:)`.
        guard let wanted = UUID(uuidString: uuid), wanted != nilVolumeUUID else { return nil }
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&mounts, MNT_NOWAIT)  // reentrant: caller-owned buffer, no shared static state
        guard n > 0, let mounts else { return nil }
        defer { free(mounts) }
        for i in 0..<Int(n) {
            var fs = mounts[i]
            let mp = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            guard let volUUID = volumeUUID(ofMountPoint: mp) else { continue }
            if volUUID == wanted { return mp }
        }
        return nil
    }
}

public final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String
    /// Takes the team id, never the requirement itself. The split made this type public, and a
    /// public `init(requirement:)` would let a caller outside this module hand the listener
    /// `"anchor apple generic"` — which accepts any Developer-ID binary from any team, and is the
    /// entire peer-validation control. The string is built here and nowhere else.
    public init(teamID: String) { self.requirement = HelperIdentity.clientRequirement(teamID: teamID) }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Code-signing requirement is enforced by the kernel/XPC layer for this connection — set
        // BEFORE resume(), never validated by PID (SECURITY_MODEL.md).
        //
        // No `do/catch`: this method does not throw. A malformed requirement raises an Objective-C
        // exception, which Swift cannot catch and which terminates the daemon — fail-closed, but not
        // by the mechanism the old `catch` implied. The string is validated once at startup with
        // SecRequirementCreateWithString so it cannot be malformed by the time we are here.
        connection.setCodeSigningRequirement(requirement)
        // Caller identity comes from the connection's audit credentials, never from request payloads.
        let uid = connection.effectiveUserIdentifier, gid = connection.effectiveGroupIdentifier
        connection.exportedInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
        connection.exportedObject = HelperService(callerUID: uid, callerGID: gid)
        connection.resume()
        return true
    }
}
