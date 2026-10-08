import Foundation

/// R8 follow-up (H18): the vault folder made **before** ownership is turned on.
///
/// With ownership on, a volume's root is `root:wheel` and the user cannot create `XCodeVault/` in it; the helper's
/// `createVaultDirectory` opens the volume as root, which macOS privacy protection very likely refuses on a removable
/// volume (SECURITY_MODEL, [LIKELY]). While ownership is still off every file on the volume belongs to the user, so
/// the app — running as the user — makes the one folder then. On a disk image the folder stayed `user:staff` after a
/// remount with ownership on (2026-10-07); on a real drive that is still to be re-tested. While ownership is off `stat`
/// reports every file as the caller's, so the owner checks below cannot see the owner stored on disk.
///
/// This creates exactly one directory, named `folderName` (a single, validated component), directly in a top-level `/Volumes/<name>`
/// root, after asserting that the mount point is the volume the user clicked. It never creates intermediate
/// directories, never follows a symlink, never touches anything that is already there, and never writes to the
/// internal disk: every refusal leaves the disk as it was. It does not register the vault.
public enum VaultFolderPrecreate {
    public enum Outcome: Sendable, Equatable {
        /// The folder was made, and is the caller's.
        case created(String, journalled: Bool = true)
        /// A real directory of the caller's was already there.
        case alreadyThere(String)
        /// Nothing was written, and nothing is wrong: the helper route or the guided command still applies.
        case skipped(String)
        /// Something unexpected; nothing more was written.
        case failed(String)

        /// A sentence for the result the user sees; nil when there is nothing to say.
        public var note: String? {
            switch self {
            case .created(let path, let journalled):
                let base = "Created the vault folder \(path) first, while the drive was still yours to write to."
                return base + (journalled ? "" : " (It could not be written to the journal.)")
            case .alreadyThere: return nil
            case .skipped(let why): return "The vault folder was not created before ownership: \(why)"
            case .failed(let why): return "The vault folder could not be created before ownership: \(why)"
            }
        }
    }

    public static func createBeforeOwnership(
        mountPoint mp: String, volumeUUID uuid: String, journal: Journal = Journal(),
        isMountPoint: (String) -> Bool = { MountStatus.isMountPoint($0) },
        volumeUUIDAt: (String) -> String? = { MountStatus.volumeUUID(at: $0) },
        rootIsWritable: (String) -> Bool = { access($0, W_OK) == 0 }, uid: uid_t = getuid(),
        folderName: String = VaultFolderName.suggested, host: () -> String? = { HostFingerprint.current() },
        volumesRoot: String = "/Volumes"  // only a test passes another
    ) -> Outcome {
        let name = mp.dropFirst(volumesRoot.count + 1)
        guard mp.hasPrefix(volumesRoot + "/"), !name.isEmpty, !name.contains("/"), name != ".", name != "..", UUID(uuidString: uuid) != nil else {
            return .skipped("\(mp) is not a drive mounted directly under /Volumes.")
        }
        // A positive identity assertion that fails closed (the same reasoning as `VaultRegistry.register`): a nil, a
        // different volume or an unmounted directory all refuse.
        guard isMountPoint(mp) else { return .skipped("\(mp) is not mounted.") }
        guard let now = volumeUUIDAt(mp), now.caseInsensitiveCompare(uuid) == .orderedSame else {
            return .skipped("\(mp) is not the volume you chose.")
        }
        if let problem = VaultFolderName.problem(folderName) { return .skipped(VaultFolderName.message(for: problem) ?? "The folder name is not usable.") }
        let dir = mp + "/" + folderName
        var st = stat()
        if lstat(dir, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return .failed("\(dir) exists and is not a directory.") }
            guard st.st_uid == uid else { return .skipped("\(dir) exists and is not yours.") }
            // A drive shared between Macs: a folder that is another Mac's vault is not taken (ADR-0015).
            if let other = VaultVerifier.readSentinel(at: dir)?.hostFingerprint, other != host() {
                return .skipped("\(folderName) is already a vault of another Mac; choose another folder name.")
            }
            return .alreadyThere(dir)
        }
        guard errno == ENOENT else { return .failed("cannot look at \(dir): \(String(cString: strerror(errno)))") }
        guard rootIsWritable(mp) else { return .skipped("the drive's root is already not writable by you.") }
        guard mkdir(dir, 0o755) == 0 else {
            let why = String(cString: strerror(errno))
            _ = try? journal.record(kind: .migration, state: .failed, summary: "vault folder not created before ownership: \(why)", paths: [dir])
            return .failed("\(why) (\(dir))")
        }
        // What was made is what was meant: a real directory, the caller's, and still on the volume asserted above — the
        // checks before `mkdir` and the `mkdir` are separate syscalls, so the identity is asserted again after it.
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else {
            return .failed("\(dir) was made, but is not a directory of yours; check it before going on.")
        }
        guard isMountPoint(mp), let after = volumeUUIDAt(mp), after.caseInsensitiveCompare(uuid) == .orderedSame else {
            _ = try? journal.record(
                kind: .migration, state: .failed, summary: "vault folder made, but the volume could not be confirmed afterwards: \(dir)", paths: [dir],
                detail: [VaultDirectoryRefusal.volumeUUIDKey: uuid])
            return .failed("\(dir) was made, but the drive was not confirmed afterwards; look at it before going on.")
        }
        do {
            try journal.record(
                kind: .migration, state: .completed, summary: "vault folder created before ownership was turned on: \(dir)", paths: [dir],
                detail: [VaultDirectoryRefusal.volumeUUIDKey: uuid])
        } catch {
            return .created(dir, journalled: false)
        }
        return .created(dir)
    }
}
