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
    /// How many of `unreadable` were refused with `EPERM`, the errno macOS privacy protection (TCC) returns
    /// (H15) — as opposed to `EACCES`, which is ordinary permission bits. Other policy layers can return
    /// `EPERM` too (a `sandbox-exec` profile did, measured 2026-09-28), which is why the app stops asking
    /// once the grant is known to be present. The app asks for Full Disk Access only when a scan reports one
    /// of these (ADR-0007). It only counts; `unreadable` and `isLowerBound` are exactly what they were.
    public var privacyRefusalCount: Int = 0

    public static let zero = DiskUsage(
        allocatedBytes: 0, logicalBytes: 0, fileCount: 0, directoryCount: 0, symlinkCount: 0, skippedMountPoints: [], unreadable: [])

    public var isLowerBound: Bool { !unreadable.isEmpty }

    /// `EPERM`, and only it, is the privacy refusal. Separate so the rule is testable: no in-process unit
    /// test can make macOS refuse a read with `EPERM` on demand (a subprocess under a sandbox profile can).
    static func isPrivacyRefusal(_ code: Int32) -> Bool { code == EPERM }

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
            if DiskUsage.isPrivacyRefusal(errno) { usage.privacyRefusalCount += 1 }
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
                //
                // Three-valued as of issue #25, and the reason is not the descent. `FTS_XDEV`
                // already stops a real mount being walked into whatever this answers. What the
                // answer decides is whether the path gets *recorded* — and `CleanPlanner` skips a
                // whole item when `skippedMountPoints` is non-empty. With the `Bool` collapse an
                // unreadable nested mount was silently absent from that list, so the planner saw
                // a clean tree and offered to remove it; `FileManager.removeItem` would then take
                // the siblings and fail on the mount itself. Recording the unanswerable case is
                // what keeps the planner's premise true.
                if ent.pointee.fts_level > 0 {
                    switch MountStatus.mountAnswer(entPath) {
                    case .isMountPoint:
                        usage.skippedMountPoints.append(entPath)
                        fts_set(fts, ent, FTS_SKIP)
                        continue
                    case .undetermined:
                        usage.skippedMountPoints.append(entPath)
                        // Also a lower bound: the subtree is deliberately not walked, so these
                        // bytes are missing from the total and the report must say so.
                        usage.unreadable.append(entPath)
                        fts_set(fts, ent, FTS_SKIP)
                        continue
                    case .isNotMountPoint: break
                    }
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
                if DiskUsage.isPrivacyRefusal(ent.pointee.fts_errno) { usage.privacyRefusalCount += 1 }
                usage.unreadable.append(entPath)
            default:
                continue
            }
        }
        return usage
    }
}
