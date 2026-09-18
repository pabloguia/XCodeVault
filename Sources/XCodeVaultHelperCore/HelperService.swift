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

    /// Every state-changing verb requires the caller to be an administrator.
    ///
    /// The code-signing requirement decides which *binary* may connect. It says nothing about which
    /// *user* is driving that binary — and the shipped CLI is a Developer-ID-signed, world-executable
    /// client that satisfies the requirement by construction. Without this check the caller set was
    /// every local account, including non-admin and service accounts, for verbs that delete files as
    /// root and change ownership. `callerUID >= 500` further down is a "not a system account" filter,
    /// which is not the same question and does not stop a perfectly ordinary user.
    ///
    /// Group membership, not the Security framework's rights API: SECURITY_MODEL.md forbids the
    /// null-authorization form outright, and a genuine right would have to arrive as an externalized
    /// authorization reference from a client that does not exist yet.
    ///
    /// **Fails closed.** Any failure to resolve the caller, the admin group, or the group list
    /// refuses the operation; "I cannot tell whether you are an administrator" is not a yes.
    /// The caller's name and primary gid. Seams like this one exist so the gate can be tested;
    /// see the target header for why that is not optional here.
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
    /// and is proportionate to these three verbs, but do not read it as an authorization dialogue.
    /// A real right would have to arrive as an externalized authorization reference from a client,
    /// and no client exists yet.
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
    func removeStrandedRuntimeDownload(fileName: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doRemoveStrandedRuntimeDownload(fileName: fileName)) }
    }
    func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doCreateVaultDirectory(volumeUUID: volumeUUID)) }
    }

    private func doRemoveRegenerableSystemDirectoryContents(target: String) -> HelperResult {
        if let denied = authorize() { return denied }
        guard let t = HelperCleanupTarget(rawValue: target) else { return HelperResult(ok: false, message: "unknown target") }
        let dir = t.path
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: true, message: "nothing to do", bytesFreed: 0) }
        guard st.st_uid == 0 else { return HelperResult(ok: false, message: "target is not root-owned; refusing") }
        guard !Self.isMountPoint(dir) else { return HelperResult(ok: false, message: "target is a mount point") }
        var freed: UInt64 = 0
        var failures = 0
        // Remove children, never the directory itself (CoreSimulator recreates the caches in place).
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for n in names {
                let p = dir + "/" + n
                var cst = stat(); guard lstat(p, &cst) == 0 else { continue }
                if (cst.st_mode & S_IFMT) == S_IFLNK { failures += 1; continue }  // never follow/delete through symlinks
                freed += Self.allocatedBytes(p)
                // helper-invariants: allow deletion — `p` is a child name read from a fixed,
                // root-owned, non-mount-point directory named by an enum, never a client path.
                // Symlinked children are skipped above rather than followed.
                do { try FileManager.default.removeItem(atPath: p) } catch { failures += 1 }
            }
        }
        return HelperResult(ok: failures == 0, message: failures == 0 ? "cleaned \(dir)" : "\(failures) item(s) could not be removed", bytesFreed: freed)
    }

    private func doRemoveStrandedRuntimeDownload(fileName: String) -> HelperResult {
        if let denied = authorize() { return denied }
        // Single component, plain ASCII, .dmg, no traversal, no leading dot, no whitespace tricks.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        guard !fileName.isEmpty, fileName.count <= 128, fileName.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }),
            !fileName.hasPrefix("."), !fileName.hasSuffix(" "), fileName.lowercased().hasSuffix(".dmg"), fileName != ".dmg"
        else {
            return HelperResult(ok: false, message: "invalid file name")
        }
        for inbox in HelperInboxDirectory.allCases {
            let p = inbox.rawValue + "/" + fileName
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { return HelperResult(ok: false, message: "not a regular file") }
            let bytes = UInt64(st.st_blocks) * 512
            // unlink(2) on the lstat'ed path: a symlink swapped in after lstat would be unlinked itself, never followed.
            // `p` is a fixed Inbox prefix plus a filename validated byte-by-byte above (ASCII
            // allowlist, no `/`, no NUL, no leading dot, `.dmg` suffix), and `unlink` acts on the
            // lstat'ed path, so a symlink swapped in after the check is removed rather than followed.
            // helper-invariants: allow deletion
            guard unlink(p) == 0 else { return HelperResult(ok: false, message: "unlink failed: \(String(cString: strerror(errno)))") }
            return HelperResult(ok: true, message: "removed \(p)", bytesFreed: bytes)
        }
        return HelperResult(ok: false, message: "no such stranded download")
    }

    private func doCreateVaultDirectory(volumeUUID: String) -> HelperResult {
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
        // Only chown what THIS call created. The pre-existing branch above used to fall through to
        // the same fchown, so on a volume with ownership enforced any local account could name a
        // volume UUID it does not own and have root hand it the vault root of whoever does — an
        // ownership change the caller could never perform itself. Re-registration by the same user
        // is idempotent and still allowed; anything else is refused.
        // `created` alone is not enough: between `mkdir` returning and `open` succeeding, someone
        // with write access to that volume can rename a different directory into the path, and the
        // create branch would then hand it to the caller. A directory we just made is owned by root,
        // so requiring that closes the window without affecting the legitimate case.
        guard (created && fst.st_uid == 0) || fst.st_uid == callerUID else {
            return HelperResult(ok: false, message: "\(name) already exists and belongs to uid \(fst.st_uid); refusing to take ownership of it")
        }
        guard fchown(fd, callerUID, callerGID) == 0 else { return HelperResult(ok: false, message: "chown failed: \(String(cString: strerror(errno)))") }
        return HelperResult(ok: true, message: dir)
    }

    // MARK: helpers (no shell, no Process)

    static func isMountPoint(_ path: String) -> Bool {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        var buffer = [UInt32](repeating: 0, count: 2)
        let rc = buffer.withUnsafeMutableBytes { raw in getattrlist(path, &attrList, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) }
        return rc == 0 && buffer[0] >= 8 && (buffer[1] & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0
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
