import Foundation
import XCodeVaultHelperProtocol

/// What the cleanup verb has previously observed at each of its allowlisted targets.
///
/// **The problem this exists for (issue #24).** Every individual check in
/// `removeRegenerableSystemDirectoryContents` is correct, and the composition still erases data.
/// Under the canonical-mount strategy a target such as
/// `/Library/Developer/CoreSimulator/Caches/dyld` is a mount point — `HYPOTHESES.md` names that
/// exact path — so while the volume is connected the verb correctly refuses. After a disconnect the
/// local stub reappears: on a stock machine it is `root:admin 0755`, so the guarded walk passes, the
/// mount query *truthfully* answers `.isNotMountPoint`, and the verb deletes the contents and
/// reports `ok: true, "cleaned …"`. That is the local half of a split brain, presented to the user
/// as a successful cache clean, and `NON_GOALS_AND_SAFETY.md` rule 6 requires shadow data to be
/// **detected and reported**, never auto-resolved by deleting a copy.
///
/// The reviewer's diagnosis names the missing thing exactly: the verb "has no state that would let
/// it distinguish 'a cache directory' from 'the stub of a volume that was mounted here five minutes
/// ago'". This is that state.
///
/// **Why not the vault registry, which is what the issue's remedy sketch suggests.** The registry
/// lives in `XCodeVaultCore`, and the root daemon may not depend on Core — that isolation is a
/// security property, enforced now by `scripts/helper-invariants.sh` reading `Package.swift`. The
/// other suggestion, a list passed in by the client, would put a path on the XPC wire, which the
/// allowlisted-API rule forbids. So the helper records what it observes itself, about paths it
/// already owns by enum. Nothing new crosses the boundary.
///
/// **What this does not do, stated plainly.** It is a record of what the verb has *seen*. If the
/// verb has never run while the volume was mounted, there is nothing recorded and the shadow half
/// is indistinguishable from an ordinary cache — the composition the issue describes is still
/// reachable. It catches the ordinary sequence (clean while mounted, disconnect, clean again),
/// which is the one a user actually performs, and it is a floor rather than a proof. The proof
/// would need the product to declare its mount points to the daemon, and that is a wire change
/// this issue does not justify on its own.
enum HelperMountHistory {
    /// Why the record store could not be opened. A type rather than a bare `String` because
    /// `Result`'s failure must be an `Error`, and because the reason reaches a user-facing refusal.
    struct StoreFailure: Error, Equatable {
        let reason: String
        /// Whether the store is simply not there, as opposed to unreachable or untrustworthy.
        ///
        /// Absence is the one failure that is a real answer: nothing has ever been recorded, so
        /// nothing can be hiding an observation that says stop. Every other failure refuses. This is
        /// a flag and not a string comparison because the string comparison it replaces was wrong —
        /// see `HelperService.GuardFailure.isAbsence`.
        var isAbsence: Bool = false
    }

    /// What was last observed at a target.
    enum Observation: String, Equatable {
        /// A filesystem was mounted here. The important one: seeing this and then finding a plain
        /// directory is the split-brain signature.
        case wasMountPoint
        case wasPlainDirectory
    }

    /// Root-owned, 0700, and under `base` so a test can use its own tree.
    ///
    /// `/Library/Application Support` rather than `/var/db`: it is the conventional place for this,
    /// it exists on every Mac, and it is not covered by SIP, so root can write it without the
    /// project going anywhere near rule 1.
    static func directory(under base: String) -> String {
        precondition(base.hasPrefix("/"), "the trust anchor must be absolute")
        precondition(!base.split(separator: "/").contains(".."), "the trust anchor must not contain '..'")
        return (base == "/" ? "" : base) + "/Library/Application Support/XCodeVault/helper-mount-history"
    }

    /// The part of that path that must already exist and be trustworthy before anything is created.
    private static func anchorDirectory(under base: String) -> String {
        (base == "/" ? "" : base) + "/Library/Application Support"
    }

    /// The two components this type creates beneath the anchor.
    private static let ownedComponents = ["XCodeVault", "helper-mount-history"]

    /// Opens the record directory through a guarded walk, creating the two components this type
    /// owns — descriptor-relative, `O_NOFOLLOW` at every step.
    ///
    /// **Why this is not `createDirectory` plus a path (issue #24 review).** The first version did
    /// exactly that, validating nothing about `/Library`, `/Library/Application Support` or the two
    /// components below. On a stock Mac those are `root:wheel`/`root:admin` `0755`, so an
    /// unprivileged user cannot pre-create them — the reviewer measured it — but that is the
    /// safety property being *inherited from the environment* rather than enforced here, which is
    /// the precise defect `openGuardedDirectory` was written for.
    ///
    /// It breaks the moment an installer loosens `/Library/Application Support`, or a future
    /// XCodeVault component creates `/Library/Application Support/XCodeVault` as the user — an easy
    /// mistake, since `Journal` and the Homebrew cask already use the same name under `$HOME`. And
    /// the failure is not subtle: whoever can write an ancestor writes `wasPlainDirectory` and the
    /// whole guard is off, or writes `wasMountPoint` and the verb is refused forever.
    ///
    /// Symlinks were the second half. `FileManager.fileExists(atPath:isDirectory:)` **follows**
    /// them, so the old `!isDir.boolValue` check passed a symlinked record directory, and root's
    /// write landed wherever it pointed: an attacker-chosen path holding a root-owned `0600` file.
    /// `O_NOFOLLOW` on every `openat` is what makes this a walk rather than a resolution.
    static func openDirectory(under base: String, creating: Bool) -> Result<Int32, StoreFailure> {
        var fd: Int32
        switch HelperService.openGuardedDirectory(anchorDirectory(under: base), under: base) {
        case .success(let d): fd = d
        case .failure(let f):
            return .failure(
                StoreFailure(
                    reason: "\(anchorDirectory(under: base)): component '\(f.component)' \(f.reason)", isAbsence: f.isAbsence))
        }

        // Read once, **through the descriptor the walk just verified**, rather than by `stat`ing
        // the anchor path again on every component. The path form was a second resolution of a name
        // this file's own rules forbid re-resolving, and `stat` follows symlinks. Direction of
        // failure was safe — a failed `stat` demanded root — but "safe by accident" is what the
        // guarded walk exists to replace.
        var anchor = stat()
        guard fstat(fd, &anchor) == 0 else {
            // Bound before the `close`, which is itself a syscall that may set `errno`. The sibling
            // site in `HelperService` already does this; this one was written during the fix for a
            // different finding and reintroduced the same defect one file over.
            let why = String(cString: strerror(errno))
            close(fd)
            return .failure(StoreFailure(reason: "could not read the trust anchor: \(why)"))
        }
        let owner = anchor.st_uid

        for component in ownedComponents {
            var st = stat()
            if fstatat(fd, component, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                let e = errno
                // **Only `ENOENT` is absence.** The first version set `isAbsence: true` for any
                // `fstatat` failure, which is the exact defect this flag was introduced to end — a
                // reviewer demonstrated it with mode `0400` on the `XCodeVault` component: every
                // guard passes (no `w` bits to fail on), the next `fstatat` returns `EACCES`, the
                // store answers "nothing was ever recorded here", and the cleanup verb deletes the
                // shadow half while the record on disk says `wasMountPoint`.
                //
                // Not reachable by an unprivileged attacker today — the daemon is root and only root
                // can chmod a `0700` root-owned directory — but root does not bypass MACF or
                // endpoint-security denials, and `EIO` is not hypothetical either. The point of the
                // flag is to stop inheriting this from the environment.
                guard creating else {
                    close(fd)
                    return .failure(StoreFailure(reason: "\(component): \(String(cString: strerror(e)))", isAbsence: e == ENOENT))
                }
                guard e == ENOENT else {
                    close(fd)
                    return .failure(StoreFailure(reason: "could not stat \(component): \(String(cString: strerror(e)))"))
                }
                guard mkdirat(fd, component, 0o700) == 0 else {
                    let why = String(cString: strerror(errno))
                    close(fd)
                    return .failure(StoreFailure(reason: "could not create \(component): \(why)"))
                }
            }
            // `O_NONBLOCK` because `O_NOFOLLOW` stops symlinks and not FIFOs: opening a FIFO without
            // it blocks until a peer appears, and every verb runs on one serial queue, so a single
            // planted FIFO wedges the whole daemon. The `S_IFDIR` check below then rejects it — but
            // it only runs if the open returns.
            let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
            let openError = errno
            close(fd)
            guard next >= 0 else {
                // With the errno: this is the refusal a permissions problem on the store actually
                // produces, and it was the one failure in this file that dropped its cause.
                return .failure(StoreFailure(reason: "could not open \(component): \(String(cString: strerror(openError)))"))
            }
            fd = next

            // Verified through the descriptor, never by re-reading the name. Root-owned and not
            // writable by group or other: a record anyone else can edit is a record that can be
            // made to say "never mounted" about a path that was.
            var fst = stat()
            guard fstat(fd, &fst) == 0 else {
                let why = String(cString: strerror(errno))
                close(fd)
                return .failure(StoreFailure(reason: "could not stat the open \(component): \(why)"))
            }
            guard (fst.st_mode & S_IFMT) == S_IFDIR else {
                close(fd)
                return .failure(StoreFailure(reason: "\(component) is not a directory"))
            }
            guard fst.st_uid == owner else {
                close(fd)
                return .failure(StoreFailure(reason: "\(component) is owned by uid \(fst.st_uid)"))
            }
            guard (fst.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                close(fd)
                return .failure(StoreFailure(reason: "\(component) is writable by group or other"))
            }
        }
        return .success(fd)
    }

    /// The record's filename for a target.
    ///
    /// Validated on **bytes** even though `HelperCleanupTarget` is a closed enum no client can
    /// extend, for the same reason `doCreateVaultDirectory` validates its compile-time-constant
    /// directory name: containment is a property this file is responsible for, and a value that
    /// becomes client-influenced later must not silently become a path traversal. `String.contains`
    /// compares graphemes, so a "/" carrying a combining mark does not match it while the kernel
    /// splits on the 0x2F byte regardless.
    static func fileName(for target: HelperCleanupTarget) -> String? {
        let name = target.rawValue
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, !bytes.contains(0x2F), !bytes.contains(0x00), name != ".", name != ".." else { return nil }
        return name
    }

    /// Reading has three answers, because two would be the collapse this project keeps finding.
    enum ReadResult: Equatable {
        case none
        case observed(Observation)
        /// The record exists and could not be read, or holds something this version does not
        /// understand. **Never treat this as `none`**: `none` means "never seen, proceed" and this
        /// means "there may be an observation saying stop".
        case unreadable(String)
    }

    static func read(target: HelperCleanupTarget, under base: String) -> ReadResult {
        guard let name = fileName(for: target) else { return .unreadable("invalid target name") }
        // `creating: false` — a read must never bring the store into existence, or the first read
        // on a machine that has never cleaned would create a root-owned directory as a side effect.
        let dirFD: Int32
        switch openDirectory(under: base, creating: false) {
        case .success(let d): dirFD = d
        case .failure(let f):
            // "The store is not there at all" is absence, and absence is a real answer: nothing has
            // ever been recorded, so there is nothing that could say stop. Anything else — a
            // loosened ancestor, a symlink, a wrong owner — is `.unreadable`, which refuses.
            if f.isAbsence { return .none }
            return .unreadable(f.reason)
        }
        defer { close(dirFD) }

        // Descriptor-relative and `O_NOFOLLOW`: the file this opens is inside the directory the
        // walk verified, not whatever the name resolves to on a second pass.
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .none }
            return .unreadable(String(cString: strerror(code)))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable("record could not be stat'd") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("record is not a regular file") }
        // Capped, and the **contents never appear in the reason**.
        //
        // The first version returned `.unreadable("unrecognised record '\(text)'")`, and a reviewer
        // traced where that string goes: into the verb's decline message, into `HelperAudit`, and
        // out through `privacy: .public` — which `HelperAudit`'s own header reserves for "this
        // project's own fixed refusal messages … **No caller-controlled text reaches it**". On-disk
        // bytes are not in that set, the read had no size cap, and trimming leaves interior
        // newlines intact: log injection into a root-owned audit trail, at arbitrary length.
        guard st.st_size > 0, st.st_size <= 64 else { return .unreadable("record is empty or implausibly large") }

        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return .unreadable("record could not be read") }
        guard let text = String(bytes: buffer[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .unreadable("record is not text")
        }
        guard let o = Observation(rawValue: text) else { return .unreadable("unrecognised record") }
        return .observed(o)
    }

    /// Deletes what was observed at a target, so a path that genuinely stopped being a mount point
    /// can be cleaned again.
    ///
    /// **Why this exists (issue #24 review).** The record is deliberately sticky: nothing expires it,
    /// because an expiry would re-open the hole on exactly the timescale a disconnected volume sits
    /// unplugged. The first version of the fix shipped that stickiness with no way out and a refusal
    /// telling the user to "reconnect the volume and run `xcodevaultctl doctor`" — and `doctor` has
    /// no code that clears this. A user who stops using the vault for a target was permanently
    /// unable to clean that cache, following an instruction that could not work. That is the same
    /// unfollowable-remediation defect this project just fixed in issue #26, introduced by the fix
    /// for this one.
    ///
    /// Forgetting restores the pre-#24 behaviour for one target, so it is a second, explicit call
    /// rather than a flag on the cleanup verb: the intent is recorded in the audit trail before any
    /// deletion is asked for, and one call can never both forget and delete.
    ///
    /// An absent store or an absent record is success — there is nothing to forget, and reporting
    /// failure would send a user looking for a problem that does not exist. Anything else the
    /// guarded walk rejects is a failure, for the reason `read` gives: it may be hiding a record.
    static func forget(target: HelperCleanupTarget, under base: String) -> Result<Bool, StoreFailure> {
        guard let name = fileName(for: target) else { return .failure(StoreFailure(reason: "invalid target name")) }
        let dirFD: Int32
        switch openDirectory(under: base, creating: false) {
        case .success(let d): dirFD = d
        case .failure(let f):
            if f.isAbsence { return .success(false) }
            return .failure(f)
        }
        defer { close(dirFD) }

        // The only deletion in this file, and it removes this daemon's **own** bookkeeping, never
        // user data: `name` comes from `fileName(for:)` — a closed enum, byte-validated to contain
        // no separator — and it is unlinked relative to the descriptor the guarded walk verified, so
        // it cannot name anything outside the store. No `AT_REMOVEDIR`: a directory at that name is
        // not a record this wrote, and refusing is the right answer to finding one.
        // helper-invariants: allow deletion
        if unlinkat(dirFD, name, 0) == 0 { return .success(true) }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return .success(false) }
        return .failure(StoreFailure(reason: String(cString: strerror(code))))
    }

    /// Records an observation. Returns false when it could not be written.
    ///
    /// The caller decides what a failed write means; this does not. That is deliberate — the answer
    /// differs by which observation was being recorded, and putting the policy here would hide it.
    /// Both call sites in `doRemoveRegenerableSystemDirectoryContents` refuse on `false`.
    @discardableResult
    static func write(_ observation: Observation, target: HelperCleanupTarget, under base: String) -> Bool {
        guard let name = fileName(for: target) else { return false }
        let dirFD: Int32
        switch openDirectory(under: base, creating: true) {
        case .success(let d): dirFD = d
        case .failure: return false
        }
        defer { close(dirFD) }

        // `O_NOFOLLOW` so a symlink planted at the record name is a failure rather than a redirect,
        // and `0o600` so nothing but the owner of the store can edit what it says.
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // The same `S_IFREG` check the reader applies. An asymmetry between the reader and the
        // writer of one file is the shape of the symlink defect this file was rewritten for: root
        // only needs to be wrong once, and `O_CREAT` on an existing non-regular file opens it.
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG else { return false }
        let bytes = Array((observation.rawValue + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count
    }
}
