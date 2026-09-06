import Foundation
import XCodeVaultHelperProtocol

// XCodeVault privileged helper — a root LaunchDaemon registered with SMAppService.daemon.
// Every verb is a fixed operation on a fixed resource. There is no Process/shell anywhere in this
// target on purpose: .claude/hooks/helper-guard.sh blocks it, and the security review checks it.

final class HelperService: NSObject, XCodeVaultHelperXPC {
    func version(reply: @escaping (String) -> Void) { reply(HelperIdentity.version) }

    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping (HelperResult) -> Void) {
        guard let t = HelperCleanupTarget(rawValue: target) else { reply(HelperResult(ok: false, message: "unknown target")); return }
        let dir = t.path
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { reply(HelperResult(ok: true, message: "nothing to do", bytesFreed: 0)); return }
        guard !Self.isMountPoint(dir) else { reply(HelperResult(ok: false, message: "target is a mount point")); return }
        var freed: UInt64 = 0
        var failures = 0
        // Remove children, never the directory itself (CoreSimulator recreates the caches in place).
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for n in names {
                let p = dir + "/" + n
                var cst = stat(); guard lstat(p, &cst) == 0 else { continue }
                if (cst.st_mode & S_IFMT) == S_IFLNK { failures += 1; continue }   // never follow/delete through symlinks
                freed += Self.allocatedBytes(p)
                do { try FileManager.default.removeItem(atPath: p) } catch { failures += 1 }
            }
        }
        reply(HelperResult(ok: failures == 0, message: failures == 0 ? "cleaned \(dir)" : "\(failures) item(s) could not be removed", bytesFreed: freed))
    }

    func removeStrandedRuntimeDownload(fileName: String, reply: @escaping (HelperResult) -> Void) {
        // Single component, .dmg, no traversal.
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.hasPrefix("."), fileName.lowercased().hasSuffix(".dmg") else {
            reply(HelperResult(ok: false, message: "invalid file name")); return
        }
        for inbox in HelperInboxDirectory.allCases {
            let p = inbox.rawValue + "/" + fileName
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { reply(HelperResult(ok: false, message: "not a regular file")); return }
            let bytes = UInt64(st.st_blocks) * 512
            do { try FileManager.default.removeItem(atPath: p); reply(HelperResult(ok: true, message: "removed \(p)", bytesFreed: bytes)) }
            catch { reply(HelperResult(ok: false, message: "\(error)")) }
            return
        }
        reply(HelperResult(ok: false, message: "no such stranded download"))
    }

    func createVaultDirectory(volumeUUID: String, ownerUID: UInt32, ownerGID: UInt32, reply: @escaping (HelperResult) -> Void) {
        guard UUID(uuidString: volumeUUID) != nil else { reply(HelperResult(ok: false, message: "invalid UUID")); return }
        guard ownerUID >= 500 else { reply(HelperResult(ok: false, message: "owner must be a regular user")); return }
        // Resolve the UUID to a mount point ourselves: enumerate mounted filesystems and match the
        // volume UUID via getattrlist(ATTR_VOL_UUID) — no client-supplied path, no diskutil parsing.
        guard let mp = Self.mountPoint(forVolumeUUID: volumeUUID) else { reply(HelperResult(ok: false, message: "volume not mounted")); return }
        guard mp.hasPrefix("/Volumes/") else { reply(HelperResult(ok: false, message: "only volumes under /Volumes are eligible")); return }
        let dir = mp + "/XcodeVault"
        var st = stat()
        if lstat(dir, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { reply(HelperResult(ok: false, message: "XcodeVault exists and is not a directory")); return }
        } else if mkdir(dir, 0o755) != 0 {
            reply(HelperResult(ok: false, message: "mkdir failed: \(String(cString: strerror(errno)))")); return
        }
        guard lchown(dir, ownerUID, ownerGID) == 0 else { reply(HelperResult(ok: false, message: "chown failed: \(String(cString: strerror(errno)))")); return }
        reply(HelperResult(ok: true, message: dir))
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
        let n = getmntinfo(&mounts, MNT_NOWAIT)
        guard n > 0, let mounts else { return nil }
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
            let volUUID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            if volUUID.uuidString.caseInsensitiveCompare(uuid) == .orderedSame { return mp }
        }
        return nil
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Code-signing requirement is enforced by the kernel/XPC layer for this connection — set
        // BEFORE resume(), never validated by PID (SECURITY_MODEL.md).
        do { try connection.setCodeSigningRequirement(requirement) } catch { return false }
        connection.exportedInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

// The requirement is baked in at bundle time (scripts/bundle-app.sh replaces TEAMID). A helper
// built without a real team ID refuses every connection rather than accepting any client.
let teamID = "TEAMID_PLACEHOLDER"
guard teamID != "TEAMID_PLACEHOLDER" else {
    FileHandle.standardError.write(Data("xcodevault-helper: not bundled with a signing team id; refusing to serve\n".utf8))
    exit(78)
}
let delegate = ListenerDelegate(requirement: HelperIdentity.clientRequirement(teamID: teamID))
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
