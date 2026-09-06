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

    public struct FilesystemInfo: Sendable, Equatable {
        public let mountPoint: String
        public let device: String       // f_mntfromname
        public let typeName: String     // f_fstypename
        public let flags: UInt32
        public var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
        public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
        public var ignoresOwnership: Bool { flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }
        public var isNoBrowse: Bool { flags & UInt32(MNT_DONTBROWSE) != 0 }
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
