import Foundation

/// Mount-state primitives. Apple DTS recommends `getattrlist` + `ATTR_DIR_MOUNTSTATUS` as
/// the cheap, race-free "is something mounted here?" check (research F5), preferred over
/// Disk Arbitration for synchronous decisions.
public enum MountStatus {
    /// Three answers, because two was a collapse.
    ///
    /// This is the third instance of one defect, and the third is the reason it is written this
    /// way rather than fixed in place. The helper's own `isMountPoint` failed open inside the
    /// cleanup verb (issue #2); `abort`, `forget` and `leftoverPartialCopies` read a failing
    /// `lstat` as "the partial copy is gone" (issue #8). Both were a question with three answers
    /// written with two, where the missing answer silently took the value of the safe-sounding
    /// one. `isMountPoint` below returned `false` both for "this is not a mount point" and for
    /// "the attribute could not be read", and an `EACCES` on a destination's parent is enough to
    /// produce the second.
    ///
    /// **Why this is not the helper's `MountAnswer`, given that it is the same idea.** Sharing one
    /// type would mean `XCodeVaultHelperCore` importing `XCodeVaultCore`. The helper is a root
    /// daemon whose isolation is a security property: `scripts/helper-invariants.sh` exists partly
    /// to hold the rule that nothing but two permitted targets may depend on `HelperCore`, and
    /// widening the helper's dependency closure to all of Core to save an eight-line enum is the
    /// wrong trade. The duplication is deliberate; the two must be kept in step by hand, and
    /// `MountAnswerTests.testTheTwoMountAnswerSpellingsHaveTheSameCases` fails if their case
    /// sets drift.
    public enum MountAnswer: Equatable, Sendable {
        case isMountPoint
        case isNotMountPoint
        /// The question could not be answered — the path is missing, unreadable, `ELOOP`, on a
        /// filesystem that does not answer `ATTR_DIR_MOUNTSTATUS`, or an I/O error occurred.
        /// **Never treat this as "no".** Which direction it must fail in is a property of the
        /// caller, not of this type, which is the whole reason it is a separate case.
        case undetermined
    }

    /// Whether `path` is a mount point, or that the question could not be answered.
    ///
    /// Prefer this to `isMountPoint` at any site where the answer gates an action on the user's
    /// data. The rule for reading it: a guard that must *stop* on `.undetermined` cannot use the
    /// `Bool` form, because there the collapse is fail-open.
    public static func mountAnswer(_ path: String) -> MountAnswer {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        // Buffer: u_int32 length + u_int32 mount status
        var buffer = [UInt32](repeating: 0, count: 2)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &attrList, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        // A short reply means the attribute was not returned, which is not the same as a cleared
        // flag — the same class as parsing `ATTR_VOL_UUID` without `ATTR_CMN_RETURNED_ATTRS`.
        if rc == 0, buffer[0] >= 8 {
            return (buffer[1] & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 ? .isMountPoint : .isNotMountPoint
        }

        // No answer from the attribute — but for one class of object the question has a definite
        // answer anyway: **only a directory can be a mount point.** `ATTR_DIR_MOUNTSTATUS` is a
        // directory attribute, so every regular file, device node and socket comes back as a short
        // reply, and reading that as "unknown" is wrong twice over. It is wrong on the facts, and
        // it was about to be wrong in the product: `Scanner` asks this of every existing catalog
        // path, so a catalog entry that is a plain file would have been marked
        // `mountStateUndetermined` and then refused by `CleanPlanner` — a regression introduced by
        // the fix for issue #25 and caught by probing what the syscall actually answers for each
        // shape of path, rather than by assuming a short reply means ignorance.
        //
        // The `lstat` is a second syscall on a second resolution of the same name, which is why it
        // is consulted only in the branch that already has no answer, and why it is `lstat` rather
        // than `stat` — matching the `FSOPT_NOFOLLOW` above. Racing it can only turn
        // `.undetermined` into `.isNotMountPoint` for an object that is *now* not a directory, and
        // that object cannot be a mount point either.
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { return .isNotMountPoint }

        // Everything left is genuinely unanswered: the path is missing, the parent is unreadable,
        // an I/O error occurred, or the filesystem does not answer the attribute at all.
        return .undetermined
    }

    /// True if `path` is a directory that is currently a mount point. False for ordinary
    /// directories, for non-directories, **and for a question that could not be answered.**
    ///
    /// That last collapse is why this is a convenience and not the primitive. It is safe only
    /// where `.undetermined` collapsing to `false` fails in the direction the caller wants:
    ///
    /// - **Safe**: `guard isMountPoint(x) else { throw }` — `.undetermined` refuses.
    /// - **Safe**: anywhere a wrong answer costs a wrong *number* rather than a wrong action —
    ///   `DiskUsage`, `TreeVerifier`, the display flags.
    /// - **Not safe**: `guard !isMountPoint(x) else { throw }` — `.undetermined` proceeds. Every
    ///   such site now calls `mountAnswer` and handles the third case;
    ///   `MountAnswerTests.testNoGuardNegatesTheBoolConvenience` fails if a new one appears.
    public static func isMountPoint(_ path: String) -> Bool { mountAnswer(path) == .isMountPoint }

    /// The volume UUID of the filesystem **containing** `path` — nil when the attribute cannot be
    /// read at all (path missing, unreadable, `ELOOP`, I/O error) or the filesystem reports none.
    /// Not APFS-specific: `ATTR_VOL_UUID` is answered by HFS+ too. Only the callers are APFS-bound.
    ///
    /// Note what this is not: `ATTR_VOL_*` answers about the volume, so an ordinary directory
    /// returns the UUID of the filesystem it lives on rather than nil. Asking this alone cannot
    /// distinguish "this *is* the volume" from "this is *on* the volume" — pair it with
    /// `isMountPoint` when identity of a mount point is what you mean. Pinned by
    /// `MountStatusTests.testAnOrdinaryDirectoryReportsItsContainingVolumeNotNil`, because the two
    /// functions read as interchangeable and are not.
    ///
    /// Deliberately a `getattrlist` syscall rather than `diskutil`: `VolumeDiscovery` shells out to
    /// build its inventory, which is fine once per scan but far too heavy — and far too slow — to
    /// re-check inside a transaction. The point of this primitive is to be cheap enough that
    /// "is the volume I verified a moment ago still the volume under my feet?" can be asked
    /// immediately before a write, closing the window between the check and the use.
    public static func volumeUUID(at path: String) -> String? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        // Layout: u_int32 length, then uuid_t (16 bytes).
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw in getattrlist(path, &attrList, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) }
        // Validate the length prefix rather than relying on the buffer having been zero-initialised:
        // a filesystem that does not support the attribute returns a short record, and without this
        // check the all-zero fallback below is what silently saves us. `isMountPoint` above makes the
        // same check explicitly (`>= 8`); this record is u_int32 length + uuid_t = 20.
        let returned = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard rc == 0, returned >= 20 else { return nil }
        let b = Array(buffer[4..<20])
        // An all-zero UUID means the filesystem reported none; treat that as absent rather than as
        // a volume whose identity happens to be zeros.
        guard b.contains(where: { $0 != 0 }) else { return nil }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    public struct FilesystemInfo: Sendable, Equatable {
        public let mountPoint: String
        public let device: String  // f_mntfromname
        public let typeName: String  // f_fstypename
        public let flags: UInt32
        public var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
        public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
        public var ignoresOwnership: Bool { flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }
    }

    /// The filesystem that serves `path` (walks up to the mount point).
    public static func filesystem(containing path: String) -> FilesystemInfo? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let mnt = withUnsafePointer(to: &s.f_mntonname) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &s.f_mntfromname) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let type = withUnsafePointer(to: &s.f_fstypename) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return FilesystemInfo(mountPoint: mnt, device: from, typeName: type, flags: s.f_flags)
    }

    /// Free and total bytes on the filesystem serving `path`.
    public static func space(at path: String) -> (free: UInt64, total: UInt64)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let bsize = UInt64(s.f_bsize)
        return (free: UInt64(s.f_bavail) * bsize, total: UInt64(s.f_blocks) * bsize)
    }
}
