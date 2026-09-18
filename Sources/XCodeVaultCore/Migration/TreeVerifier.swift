import CryptoKit
import Foundation

/// Compares two directory trees far beyond file counts (MIGRATION_ENGINE.md §Verification):
/// relative topology, entry types, sizes, permissions, symlink targets, extended attributes,
/// and — when `deep` — SHA-256 of every regular file. Never follows symlinks; never crosses
/// mount points.
public struct TreeVerifier: Sendable {
    public struct Mismatch: Sendable, Codable, Equatable, CustomStringConvertible {
        public var relativePath: String
        public var reason: String
        public var description: String { "\(relativePath): \(reason)" }
    }
    public struct Report: Sendable, Codable, Equatable {
        public var sourceFiles: UInt64
        public var destinationFiles: UInt64
        public var sourceBytes: UInt64
        public var destinationBytes: UInt64
        public var hashedFiles: UInt64
        public var mismatches: [Mismatch]
        public var truncated: Bool  // more mismatches than recorded
        public var isIdentical: Bool { mismatches.isEmpty && !truncated }
    }

    public var deep: Bool
    public var maxMismatches: Int
    /// Compare uid/gid (only meaningful when both filesystems honour ownership).
    public var compareOwnership: Bool
    /// xattrs that the system rewrites per copy and that carry no user data: Spotlight's last-used
    /// date, TCC's per-app access list, the provenance tag. FinderInfo is compared by value;
    /// `com.apple.quarantine` by presence only — `ditto` rewrites its value (agent name/timestamp)
    /// on every copy (re-review probe, 2026-09-06), and what matters is that the flag survives.
    public var ignoredXattrs: Set<String> = ["com.apple.lastuseddate#PS", "com.apple.macl", "com.apple.provenance"]
    public static let presenceOnlyXattrs: Set<String> = ["com.apple.quarantine"]
    /// BSD flags the system toggles on its own (Spotlight tracking, dataless/restricted markers).
    static let ignoredFlags: UInt32 = UInt32(SF_ARCHIVED) | UInt32(UF_TRACKED) | UInt32(SF_RESTRICTED) | UInt32(SF_DATALESS)

    public init(deep: Bool, maxMismatches: Int = 200, compareOwnership: Bool = true) {
        self.deep = deep; self.maxMismatches = maxMismatches; self.compareOwnership = compareOwnership
    }

    struct Entry: Equatable {
        var type: mode_t; var size: UInt64; var mode: mode_t; var linkTarget: String?; var xattrs: [String: Data]; var isDir: Bool
        var uid: uid_t; var gid: gid_t; var flags: UInt32; var acl: String?
    }

    /// The result of walking one side of the comparison. `unreadable` is not a detail: an entry
    /// that could not be read is the one case where "the two sides agree" and "I could not look"
    /// are indistinguishable, and this type exists so that they are not.
    struct Inventory {
        var entries: [String: Entry]
        var unreadable: [String]
    }

    static func inventory(_ root: String, ignoredXattrs: Set<String>) -> Inventory? {
        var out: [String: Entry] = [:]
        var unreadable: [String] = []
        let cPath = strdup(root); defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        let rootLen = root.count
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            let path = String(cString: ent.pointee.fts_path)
            if info == FTS_D, ent.pointee.fts_level > 0, MountStatus.isMountPoint(path) { fts_set(fts, ent, FTS_SKIP); continue }
            // FTS_DNR (directory unreadable), FTS_NS (stat failed) and FTS_ERR used to fall through
            // the guard below and disappear — the directory *and* everything beneath it. When the
            // same subtree was unreadable on both sides, the two inventories agreed and `verify`
            // reported identical. A permission change between COPY and the re-verification that
            // precedes deleting the source is the realistic route, and the consequence is deleting
            // an original whose contents were never compared. "Neither side could be read" must
            // never be reachable from "identical".
            if info == FTS_DNR || info == FTS_NS || info == FTS_ERR {
                if ent.pointee.fts_level > 0, path.count > rootLen + 1 {
                    unreadable.append(String(path.dropFirst(rootLen + 1)))
                } else {
                    unreadable.append(".")
                }
                continue
            }
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT, ent.pointee.fts_level > 0 else { continue }
            guard let sp = ent.pointee.fts_statp else { continue }
            let rel = String(path.dropFirst(rootLen + 1))
            let st = sp.pointee
            let type = st.st_mode & S_IFMT
            let link = type == S_IFLNK ? (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) : nil
            out[rel] = Entry(
                type: type, size: type == S_IFREG ? UInt64(st.st_size) : 0, mode: st.st_mode & 0o7777, linkTarget: link,
                xattrs: xattrs(of: path, ignoring: ignoredXattrs), isDir: type == S_IFDIR,
                uid: st.st_uid, gid: st.st_gid, flags: st.st_flags & ~ignoredFlags, acl: aclText(of: path))
        }
        return Inventory(entries: out, unreadable: unreadable)
    }

    static func xattrs(of path: String, ignoring: Set<String>) -> [String: Data] {
        let len = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [:] }
        var buf = [CChar](repeating: 0, count: len)
        let got = listxattr(path, &buf, len, XATTR_NOFOLLOW)
        guard got > 0 else { return [:] }
        var out: [String: Data] = [:]
        for name in buf[0..<got].split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) where !ignoring.contains(name) {
            let vlen = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard vlen >= 0 else { continue }
            if presenceOnlyXattrs.contains(name) { out[name] = Data(); continue }
            var v = [UInt8](repeating: 0, count: vlen)
            let r = getxattr(path, name, &v, vlen, 0, XATTR_NOFOLLOW)
            out[name] = r >= 0 ? Data(v[0..<r]) : Data()
        }
        return out
    }

    static func aclText(of path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    public static func sha256(ofFile path: String) throws -> String {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func verify(source: String, destination: String) -> Report {
        guard let src = TreeVerifier.inventory(source, ignoredXattrs: ignoredXattrs) else {
            return Report(
                sourceFiles: 0, destinationFiles: 0, sourceBytes: 0, destinationBytes: 0, hashedFiles: 0,
                mismatches: [Mismatch(relativePath: ".", reason: "cannot read source")], truncated: false)
        }
        guard let dst = TreeVerifier.inventory(destination, ignoredXattrs: ignoredXattrs) else {
            return Report(
                sourceFiles: 0, destinationFiles: 0, sourceBytes: 0, destinationBytes: 0, hashedFiles: 0,
                mismatches: [Mismatch(relativePath: ".", reason: "cannot read destination")], truncated: false)
        }
        var mm: [Mismatch] = []
        var truncated = false
        func add(_ m: Mismatch) { if mm.count < maxMismatches { mm.append(m) } else { truncated = true } }
        // Before any comparison: anything neither side could read is a mismatch, not a match.
        for rel in src.unreadable.sorted() { add(Mismatch(relativePath: rel, reason: "unreadable in source")) }
        for rel in dst.unreadable.sorted() { add(Mismatch(relativePath: rel, reason: "unreadable in destination")) }
        var sroot = stat(), droot = stat()
        if lstat(source, &sroot) == 0, lstat(destination, &droot) == 0, (sroot.st_mode & 0o7777) != (droot.st_mode & 0o7777) {
            add(Mismatch(relativePath: ".", reason: String(format: "root mode %o vs %o", sroot.st_mode & 0o7777, droot.st_mode & 0o7777)))
        }
        var hashed: UInt64 = 0
        for (rel, s) in src.entries.sorted(by: { $0.key < $1.key }) {
            guard let d = dst.entries[rel] else { add(Mismatch(relativePath: rel, reason: "missing in destination")); continue }
            if s.type != d.type { add(Mismatch(relativePath: rel, reason: "type differs")); continue }
            if s.size != d.size { add(Mismatch(relativePath: rel, reason: "size \(s.size) vs \(d.size)")); continue }
            if s.mode != d.mode { add(Mismatch(relativePath: rel, reason: String(format: "mode %o vs %o", s.mode, d.mode))) }
            if s.linkTarget != d.linkTarget { add(Mismatch(relativePath: rel, reason: "symlink target differs")) }
            if s.xattrs != d.xattrs {
                add(
                    Mismatch(
                        relativePath: rel, reason: "xattrs differ (\(Set(s.xattrs.keys).symmetricDifference(d.xattrs.keys).sorted().joined(separator: ",")))"))
            }
            if compareOwnership && (s.uid != d.uid || s.gid != d.gid) {
                add(Mismatch(relativePath: rel, reason: "ownership \(s.uid):\(s.gid) vs \(d.uid):\(d.gid)"))
            }
            if s.flags != d.flags { add(Mismatch(relativePath: rel, reason: String(format: "flags %x vs %x", s.flags, d.flags))) }
            if s.acl != d.acl { add(Mismatch(relativePath: rel, reason: "ACL differs")) }
            if deep && s.type == S_IFREG {
                hashed += 1
                let a = try? TreeVerifier.sha256(ofFile: source + "/" + rel), b = try? TreeVerifier.sha256(ofFile: destination + "/" + rel)
                if a == nil || a != b { add(Mismatch(relativePath: rel, reason: "content hash differs")) }
            }
        }
        for rel in dst.entries.keys where src.entries[rel] == nil { add(Mismatch(relativePath: rel, reason: "extra in destination")) }
        let sf = src.entries.values.filter { !$0.isDir }.count, df = dst.entries.values.filter { !$0.isDir }.count
        return Report(
            sourceFiles: UInt64(sf), destinationFiles: UInt64(df),
            sourceBytes: src.entries.values.reduce(0) { $0 + $1.size }, destinationBytes: dst.entries.values.reduce(0) { $0 + $1.size },
            hashedFiles: hashed, mismatches: mm, truncated: truncated)
    }
}
