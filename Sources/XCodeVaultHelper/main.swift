import Foundation
import XCodeVaultHelperProtocol

// XCodeVault privileged helper — a root LaunchDaemon registered with SMAppService.daemon.
// Every verb is a fixed operation on a fixed resource. There is no Process/shell anywhere in this
// target on purpose: .claude/hooks/helper-guard.sh blocks it, and the security review checks it.

/// All privileged work runs on one serial queue: connections never race each other, and the
/// per-connection caller identity (uid/gid from the audit token) is captured at accept time.
let privilegedWork = DispatchQueue(label: "com.xcodevault.helper.work")

final class HelperService: NSObject, XCodeVaultHelperXPC {
    let callerUID: uid_t
    let callerGID: gid_t
    init(callerUID: uid_t, callerGID: gid_t) { self.callerUID = callerUID; self.callerGID = callerGID }

    func version(reply: @escaping (String) -> Void) { reply(HelperIdentity.version) }

    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doRemoveRegenerableSystemDirectoryContents(target: target)) }
    }
    func removeStrandedRuntimeDownload(fileName: String, reply: @escaping (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doRemoveStrandedRuntimeDownload(fileName: fileName)) }
    }
    func createVaultDirectory(volumeUUID: String, reply: @escaping (HelperResult) -> Void) {
        privilegedWork.async { reply(self.doCreateVaultDirectory(volumeUUID: volumeUUID)) }
    }

    private func doRemoveRegenerableSystemDirectoryContents(target: String) -> HelperResult {
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
                do { try FileManager.default.removeItem(atPath: p) } catch { failures += 1 }
            }
        }
        return HelperResult(ok: failures == 0, message: failures == 0 ? "cleaned \(dir)" : "\(failures) item(s) could not be removed", bytesFreed: freed)
    }

    private func doRemoveStrandedRuntimeDownload(fileName: String) -> HelperResult {
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
            guard unlink(p) == 0 else { return HelperResult(ok: false, message: "unlink failed: \(String(cString: strerror(errno)))") }
            return HelperResult(ok: true, message: "removed \(p)", bytesFreed: bytes)
        }
        return HelperResult(ok: false, message: "no such stranded download")
    }

    private func doCreateVaultDirectory(volumeUUID: String) -> HelperResult {
        guard UUID(uuidString: volumeUUID) != nil else { return HelperResult(ok: false, message: "invalid UUID") }
        guard callerUID >= 500, callerGID >= 20 else { return HelperResult(ok: false, message: "caller must be a regular user") }
        // Resolve the UUID to a mount point ourselves (getattrlist ATTR_VOL_UUID over getmntinfo_r_np):
        // no client-supplied path, no diskutil parsing, no shared static buffer.
        guard let mp = Self.mountPoint(forVolumeUUID: volumeUUID) else { return HelperResult(ok: false, message: "volume not mounted") }
        guard mp.hasPrefix("/Volumes/"), mp.split(separator: "/").count == 2, Self.isMountPoint(mp) else {
            return HelperResult(ok: false, message: "only top-level volumes under /Volumes are eligible")
        }
        let dir = mp + "/XcodeVault"
        // O_NOFOLLOW|O_DIRECTORY open of a freshly created (or existing, non-symlink) directory, then
        // fchown on the descriptor: no path-based TOCTOU between check and chown.
        var st = stat()
        if lstat(dir, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "XcodeVault exists and is not a directory") }
        } else if mkdir(dir, 0o755) != 0 {
            return HelperResult(ok: false, message: "mkdir failed: \(String(cString: strerror(errno)))")
        }
        let fd = open(dir, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { return HelperResult(ok: false, message: "open failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFDIR else { return HelperResult(ok: false, message: "not a directory") }
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

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Code-signing requirement is enforced by the kernel/XPC layer for this connection — set
        // BEFORE resume(), never validated by PID (SECURITY_MODEL.md).
        do { try connection.setCodeSigningRequirement(requirement) } catch { return false }
        // Caller identity comes from the connection's audit credentials, never from request payloads.
        let uid = connection.effectiveUserIdentifier, gid = connection.effectiveGroupIdentifier
        connection.exportedInterface = NSXPCInterface(with: XCodeVaultHelperXPC.self)
        connection.exportedObject = HelperService(callerUID: uid, callerGID: gid)
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
