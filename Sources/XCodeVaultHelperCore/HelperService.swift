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

    /// Returns a refusal when the caller may not perform a state-changing operation, `nil` when it may.
    private func authorize() -> HelperResult? {
        guard Self.isAdministrator(uid: callerUID) else {
            return HelperResult(ok: false, message: "not authorized: this operation requires an administrator account")
        }
        return nil
    }

    func version(reply: @escaping @Sendable (String) -> Void) { reply(HelperIdentity.version) }

    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doRemoveRegenerableSystemDirectoryContents(target: target)) }
    }
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doCreateVaultDirectory(volumeUUID: volumeUUID)) }
    }

    /// `base` is a test seam and nothing else: production passes nothing and walks from `/`, which
    /// is what makes the required owner root. It injects the *trust anchor*, not an owner or a
    /// target — the target is still `HelperCleanupTarget`'s compile-time path and still cannot
    /// come from a client. An earlier draft of this took `requiredOwner` instead; two reviews
    /// pointed out that an owner knob on a root deletion verb is a way to ask root to delete
    /// somebody else's tree, and that a default argument is not a defence against a future
    /// in-module caller.
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
        switch mount(fd) {
        case .isMountPoint: return HelperResult(ok: false, message: "target is a mount point")
        case .undetermined: return HelperResult(ok: false, message: "could not determine whether \(dir) is a mount point; refusing")
        case .isNotMountPoint: break
        }

        // Everything below is descriptor-relative. The children come from the directory this call
        // walked to and verified — a fixed, root-owned, non-mount-point directory named by an enum
        // and never a client path — not from re-resolving that name a second time.
        let outcome = Self.removeContents(of: fd)
        return HelperResult(
            ok: outcome.failures == 0,
            message: outcome.failures == 0 ? "cleaned \(dir)" : "\(outcome.failures) item(s) could not be removed",
            bytesFreed: outcome.freed)
    }

    func doCreateVaultDirectory(volumeUUID: String) -> HelperResult {
        if let denied = authorize() { return denied }
        guard UUID(uuidString: volumeUUID) != nil else { return HelperResult(ok: false, message: "invalid UUID") }
        guard callerUID >= 500, callerGID >= 20 else { return HelperResult(ok: false, message: "caller must be a regular user") }
        // Resolve the UUID to a mount point ourselves (getattrlist ATTR_VOL_UUID over getmntinfo_r_np):
        // no client-supplied path, no diskutil parsing, no shared static buffer.
        guard let mp = Self.mountPoint(forVolumeUUID: volumeUUID) else { return HelperResult(ok: false, message: "volume not mounted") }
        guard mp.hasPrefix("/Volumes/"), mp.split(separator: "/").count == 2, Self.isMountPoint(mp) else {
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
        // O_NOFOLLOW|O_DIRECTORY open of a freshly created (or existing, non-symlink) directory, then
        // fchown on the descriptor: no path-based TOCTOU between check and chown.
        var st = stat()
        var created = false
        if lstat(dir, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "\(name) exists and is not a directory") }
        } else if mkdir(dir, 0o755) == 0 {
            created = true
        } else {
            return HelperResult(ok: false, message: "mkdir failed: \(String(cString: strerror(errno)))")
        }
        let fd = open(dir, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { return HelperResult(ok: false, message: "open failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "not a directory") }
        guard Self.mayTakeOwnership(created: created, directoryUID: fst.st_uid, callerUID: callerUID) else {
            return HelperResult(ok: false, message: "\(name) already exists and belongs to uid \(fst.st_uid); refusing to take ownership of it")
        }
        guard fchown(fd, callerUID, callerGID) == 0 else { return HelperResult(ok: false, message: "chown failed: \(String(cString: strerror(errno)))") }
        return HelperResult(ok: true, message: dir)
    }

    // MARK: helpers (no shell, no Process)

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

        guard path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            return .failure(GuardFailure(component: path, reason: "is not under the trust anchor \(base)"))
        }
        // Split on the 0x2F BYTE, not on Characters. `split(separator: "/")` compares graphemes, so
        // a "/" carrying a combining mark is not equal to "/" and is not split here — while the
        // kernel splits on the byte regardless. The segment would then reach `openat` containing a
        // slash, where O_NOFOLLOW constrains only its own final component and everything before it
        // resolves through symlinks, unchecked. This is the same lesson `doCreateVaultDirectory`
        // already carries for `VaultDirectory.name`; only its NUL half had been brought across.
        let rest = Array(path.utf8).dropFirst(base.hasSuffix("/") ? base.utf8.count : base.utf8.count + 1)
        let components = rest.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }

        var fd = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return .failure(GuardFailure(component: base, reason: String(cString: strerror(errno)))) }

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
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else { return .failure(GuardFailure(component: name, reason: String(cString: strerror(errno)))) }
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
    static func removeContents(of fd: Int32, depthRemaining: Int = 64) -> (freed: UInt64, failures: Int) {
        guard depthRemaining > 0 else { return (0, 1) }

        var parent = stat()
        guard fstat(fd, &parent) == 0 else { return (0, 1) }

        // fdopendir takes ownership of the descriptor it is given and closedir closes it, so it
        // gets a duplicate; `fd` remains the caller's.
        let scan = dup(fd)
        guard scan >= 0, let dir = fdopendir(scan) else {
            if scan >= 0 { close(scan) }
            return (0, 1)
        }
        // The `String(cString:)` round-trip is safe here because APFS and HFS+ reject filenames
        // that are not valid UTF-8: creating one fails with EILSEQ (measured 2026-09-18), so a
        // name that came out of `readdir` re-encodes to the same bytes it went in as.
        var names: [String] = []
        while let entry = readdir(dir) {
            var e = entry.pointee
            let name = withUnsafePointer(to: &e.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(dir)

        var freed: UInt64 = 0
        var failures = 0
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
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { failures += 1; continue }
                let inner = removeContents(of: child, depthRemaining: depthRemaining - 1)
                close(child)
                freed += inner.freed
                failures += inner.failures
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

    static func mountPoint(forVolumeUUID uuid: String) -> String? {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&mounts, MNT_NOWAIT)  // reentrant: caller-owned buffer, no shared static state
        guard n > 0, let mounts else { return nil }
        defer { free(mounts) }
        for i in 0..<Int(n) {
            var fs = mounts[i]
            let mp = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            var attrList = attrlist()
            attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attrList.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
            var buffer = [UInt8](repeating: 0, count: 64)
            let rc = buffer.withUnsafeMutableBytes { raw in getattrlist(mp, &attrList, raw.baseAddress, raw.count, 0) }
            guard rc == 0 else { continue }
            // Layout: u_int32 length, then uuid_t (16 bytes)
            let bytes = Array(buffer[4..<20])
            let volUUID = UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                    bytes[13], bytes[14], bytes[15]
                ))
            if volUUID.uuidString.caseInsensitiveCompare(uuid) == .orderedSame { return mp }
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
