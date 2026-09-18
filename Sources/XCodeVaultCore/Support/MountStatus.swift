import Foundation

/// Mount-state primitives. Apple DTS recommends `getattrlist` + `ATTR_DIR_MOUNTSTATUS` as
/// the cheap, race-free "is something mounted here?" check (research F5), preferred over
/// Disk Arbitration for synchronous decisions.
public enum MountStatus {
    /// True if `path` is a directory that is currently a mount point (i.e. a filesystem is
    /// mounted on it). False for ordinary directories and for non-directories.
    public static func isMountPoint(_ path: String) -> Bool {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        // Buffer: u_int32 length + u_int32 mount status
        var buffer = [UInt32](repeating: 0, count: 2)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &attrList, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard rc == 0, buffer[0] >= 8 else { return false }
        return (buffer[1] & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0
    }

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
