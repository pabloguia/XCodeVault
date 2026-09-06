import Foundation

/// On-disk usage of a directory tree, computed like `du -x`: allocated blocks (not logical
/// size), physical traversal (symlinks not followed), and **never crossing a mount point**.
/// The last property is essential here: `/Library/Developer/CoreSimulator/Volumes/*` are
/// mounted runtime images, and counting them would attribute gigabytes of read-only sealed
/// images to the parent directory (research F1).
///
/// Mount boundaries are detected with `getattrlist(ATTR_DIR_MOUNTSTATUS)` per directory, not
/// by comparing `st_dev`: on macOS volume groups `stat` reports the same device number for
/// `/System/Volumes` and `/System/Volumes/Data`, so `du -x` (and a naive fts walk) descend
/// into the entire data volume. Observed on macOS 26.6.2 / Intel while writing the tests.
public struct DiskUsage: Sendable, Equatable, Codable {
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var fileCount: UInt64
    public var directoryCount: UInt64
    public var symlinkCount: UInt64
    /// Mount points encountered directly under the tree that were NOT descended into.
    public var skippedMountPoints: [String]
    /// Paths that could not be read (permission denied etc.). Non-empty means the total is a lower bound.
    public var unreadable: [String]

    public static let zero = DiskUsage(
        allocatedBytes: 0, logicalBytes: 0, fileCount: 0, directoryCount: 0, symlinkCount: 0, skippedMountPoints: [], unreadable: [])

    public var isLowerBound: Bool { !unreadable.isEmpty }

    /// Measures `path`. Returns nil if the path does not exist.
    public static func measure(_ path: String) -> DiskUsage? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var usage = DiskUsage.zero
        if (st.st_mode & S_IFMT) != S_IFDIR {
            usage.allocatedBytes = UInt64(st.st_blocks) * 512
            usage.logicalBytes = UInt64(st.st_size)
            if (st.st_mode & S_IFMT) == S_IFLNK { usage.symlinkCount = 1 } else { usage.fileCount = 1 }
            return usage
        }
        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            usage.unreadable.append(path)
            return usage
        }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            let entPath = String(cString: ent.pointee.fts_path)
            switch info {
            case FTS_D:
                // A nested mount point is recorded and pruned, never descended into.
                if ent.pointee.fts_level > 0 && MountStatus.isMountPoint(entPath) {
                    usage.skippedMountPoints.append(entPath)
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                usage.directoryCount += 1
                if let sp = ent.pointee.fts_statp { usage.allocatedBytes += UInt64(sp.pointee.st_blocks) * 512 }
            case FTS_DP:
                continue
            case FTS_F, FTS_DEFAULT:
                if let sp = ent.pointee.fts_statp {
                    usage.allocatedBytes += UInt64(sp.pointee.st_blocks) * 512
                    usage.logicalBytes += UInt64(sp.pointee.st_size)
                }
                usage.fileCount += 1
            case FTS_SL, FTS_SLNONE:
                if let sp = ent.pointee.fts_statp { usage.allocatedBytes += UInt64(sp.pointee.st_blocks) * 512 }
                usage.symlinkCount += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.unreadable.append(entPath)
            default:
                continue
            }
        }
        return usage
    }
}
