import Foundation

/// Diagnosing "we cannot write here" on an external vault volume, and saying exactly what
/// privileged command fixes it.
///
/// Why this exists as its own type: enabling ownership on an external volume is **required**
/// (CoreSimulator and Xcode data carry mixed root/user ownership, and `noowners` collapses
/// everything to uid/gid 99 — research finding F5), but enabling it is also precisely what makes
/// the volume root honour its real `root:wheel` ownership and become unwritable by the user. So
/// the qualification the tool demands and the failure the user hits are two faces of the same
/// setting. That deserves an explanation at the point of failure rather than a generic
/// "permission denied", and it deserves the exact one-time command rather than "use Finder".
///
/// XCodeVault never runs these commands itself, and will not gain the ability to run *these* ones:
/// the privileged helper's allowlist has no arbitrary `mkdir`/`chown` on client-supplied paths, and
/// a tool that asks for a password to fix a permission problem is a tool users learn to hand
/// passwords to. `SECURITY_MODEL.md` does anticipate a narrow verb — "perform a narrowly scoped
/// ownership/permission repair on an approved path" — so this text is the stopgap until that verb
/// ships, not an argument that no verb should ever exist.
public enum OwnershipAdvice {
    /// The user's short name and primary group, resolved at runtime — never hardcoded, because the
    /// printed command is meant to be pasted verbatim.
    static func currentUserAndGroup() -> (user: String, group: String) {
        let user = NSUserName()
        let gid = getgid()
        let group = getgrgid(gid).flatMap { String(cString: $0.pointee.gr_name) } ?? "staff"
        return (user, group)
    }

    /// Single-quote a path for safe pasting into a shell, escaping any embedded quote. Volume names
    /// are user-chosen and can contain spaces and apostrophes ("Dev's SSD").
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The one-time privileged step that creates the vault directory already owned by the user.
    ///
    /// `install -d` rather than `mkdir` + `chown` because it is one idempotent command that also
    /// fixes owner/group/mode on a directory that already exists. It is **not** atomic —
    /// `install(1)` does `mkdir(2)` then `chown(2)`/`chmod(2)`, same as doing it by hand — so this
    /// is a usability choice, not a safety one; do not restate it as closing a race.
    ///
    /// `-o/-g/-m` apply to the final component only, so with a nested `--directory` the intermediate
    /// levels stay `root:wheel`. That is harmless for writes inside the leaf, and deliberate: only
    /// the vault directory is handed over, never the volume root.
    public static func createVaultDirectory(_ dir: String) -> String {
        let (user, group) = currentUserAndGroup()
        return """
            The volume root is root-owned (that is normal, and it is what enabling ownership buys you).
            Create the vault directory once, as yourself, with:

              sudo install -d -o \(shellQuoted(user)) -g \(shellQuoted(group)) -m 755 \(shellQuoted(dir))

            Then re-run this command. Nothing after this step needs sudo: everything inside the vault
            will be yours. XCodeVault will not run this for you — read it, then run it if you agree.
            """
    }

    /// Returns a message when `dir` exists but is not usable by us, or nil when it is fine.
    ///
    /// Checked after creation as well as before, because the common failure is not "it does not
    /// exist" but "somebody created it with a bare `sudo mkdir`", leaving a root-owned directory
    /// that fails on the first real write instead of here.
    /// `currentUID` is injectable purely so tests can exercise the not-owned-by-us branches: a test
    /// cannot create a root-owned directory without sudo, and simulating one with permission bits
    /// alone lands in the owned-by-us branch instead. Same seam `Doctor` already has for home/runner.
    public static func writabilityProblem(_ dir: String, currentUID: uid_t = getuid()) -> String? {
        var st = stat()
        guard lstat(dir, &st) == 0 else { return nil }  // absence is the caller's problem, not ours
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            // Includes a symlink, deliberately. `PathSafety.isContained` compares strings, so a
            // symlink here pointing back at the internal disk would produce a "vault" that is local
            // shadow data wearing a canonical path — refuse it rather than follow it.
            let kind = (st.st_mode & S_IFMT) == S_IFLNK ? "a symlink" : "not a directory"
            return "\(dir) exists but is \(kind). The vault directory must be a real directory on the volume itself."
        }
        guard access(dir, W_OK | X_OK) != 0 else { return nil }
        let (user, group) = currentUserAndGroup()
        let mode = String(format: "%o", st.st_mode & 0o7777)
        let ownerName = getpwuid(st.st_uid).flatMap { String(cString: $0.pointee.pw_name) } ?? String(st.st_uid)

        // A directory that is already ours is never an ownership problem — changing the owner to the
        // owner it already has is a no-op. Diagnose it here, BEFORE the emptiness refusal below, so a
        // real vault of ours (which is non-empty, it holds the sentinel) that develops a deny ACE is
        // not told to "point --directory somewhere else".
        if st.st_uid == currentUID {
            // Split the two access bits: a missing execute bit is a `chmod`, not an ACL, and telling
            // someone to hunt for an ACE that is not there is worse than saying nothing.
            let missing = [access(dir, R_OK) != 0 ? "r" : "", access(dir, W_OK) != 0 ? "w" : "", access(dir, X_OK) != 0 ? "x" : ""]
                .joined()
            let ownerBitsSayItShouldWork = (st.st_mode & S_IWUSR) != 0 && (st.st_mode & S_IXUSR) != 0
            if ownerBitsSayItShouldWork {
                return """
                    \(dir) is yours (mode \(mode)) and the owner bits allow writing, yet \(missing.isEmpty ? "access" : missing) is denied —
                    an ACL, an immutable flag, or a read-only mount. Inspect it with `ls -lXde \(shellQuoted(dir))`.
                    A `deny` entry needs `chmod -a`, an `uchg` flag needs `chflags nouchg`; no change of ownership lifts either.
                    """
            }
            return """
                \(dir) is yours but its own permission bits (mode \(mode)) deny \(missing) to the owner.
                This is a `chmod`, not an ownership problem — for example `chmod u+rwx \(shellQuoted(dir))`.
                No `sudo` and no change of ownership is needed.
                """
        }

        // Below here the directory belongs to somebody else. Only offer to change ownership when it is
        // EMPTY *and we could actually see that it is*. A populated directory the user pointed us at is
        // not ours: `--directory` is free-form, so this could be `Backups.backupdb` or any folder that
        // happens to live on the volume. Changing its ownership is irreversible (nothing records what
        // the ownership was), it flattens exactly the mixed root/user ownership MIGRATION_ENGINE says
        // to preserve, and BSD `chown` has no `-x` so it would cross into any nested mount. Recursion
        // buys nothing anyway: the failing operation is creating an entry *in* this directory.
        //
        // `try? ... ?? []` here would fail OPEN — and this is the third time that exact pattern has
        // produced a "this is empty" claim about a directory nobody could read. Reaching this line
        // means `access` already failed, so unreadable is the COMMON case, not the edge one.
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return """
                \(dir) exists, is owned by \(ownerName) (mode \(mode)), and could not be read — so whether it
                holds anything is unknown. XCodeVault will not suggest an ownership change for a directory it
                cannot inspect. Look inside it as a user who can, or point `--directory` at a new path.
                """
        }
        guard contents.isEmpty else {
            return """
                \(dir) exists, is not writable by you (owned by \(ownerName), mode \(mode)), and is not empty
                — it holds \(contents.count) item(s). XCodeVault will not suggest changing the ownership of a
                directory it did not create: that is irreversible, and this may not be a vault at all.
                Point `--directory` at an empty or new path instead, or inspect this one yourself.
                """
        }
        return """
            \(dir) exists but is not writable by you (owned by \(ownerName), mode \(mode)).
            A bare `sudo mkdir` leaves the directory owned by root, which fails on the first real write
            rather than here. It is empty, so handing over just the directory is enough:

              sudo chown \(shellQuoted(user)):\(shellQuoted(group)) \(shellQuoted(dir))

            Then re-run this command. Note this is deliberately not recursive.
            """
    }

    /// `noowners` is a blocker rather than a warning: with ownership ignored the volume reports every
    /// file as uid/gid 99, so a migration cannot preserve the ownership it is supposed to preserve,
    /// and a later `diskutil enableOwnership` would make previously-writable data unwritable.
    public static func enableOwnership(_ mountPoint: String) -> String {
        """
        Ownership is ignored on this volume, so every file reports as uid/gid 99 and a migration
        cannot preserve what it is meant to preserve. Enable it once with:

          sudo diskutil enableOwnership \(shellQuoted(mountPoint))

        Note this changes what you can write: with ownership enabled the volume root honours its real
        root ownership, so the vault directory has to be created as a separate privileged step.
        """
    }
}
