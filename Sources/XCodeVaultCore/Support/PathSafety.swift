import Foundation

/// Canonical-path containment checks. String prefix tests are not enough: `..`, interior
/// symlinks and trailing slashes all escape them (migration-safety review, 2026-09-06).
public enum PathSafety {
    public struct Violation: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// Canonical form of `path`: the parent directory resolved through `realpath(3)` (every
    /// interior symlink resolved) plus the unresolved last component, so a path that *is* a
    /// symlink is still identified as that symlink rather than its target.
    public static func canonicalize(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw Violation("\(path): not an absolute path") }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.contains("..") && !comps.contains(".") else { throw Violation("\(path): relative components are not allowed") }
        guard let last = comps.last else { return "/" }
        let parent = "/" + comps.dropLast().joined(separator: "/")
        guard let real = realpath(parent, nil) else { throw Violation("\(parent): \(String(cString: strerror(errno)))") }
        defer { free(real) }
        let p = String(cString: real)
        return p == "/" ? "/" + last : p + "/" + last
    }

    /// True if `path` (canonicalized) equals `root` (canonicalized) or lies inside it.
    public static func isContained(_ path: String, in root: String) -> Bool {
        guard let p = try? canonicalize(path), let r = try? canonicalize(root) else { return false }
        return p == r || p.hasPrefix(r + "/")
    }

    /// Throws unless `path` is inside one of `roots` (after tilde expansion + canonicalization).
    public static func requireContained(_ path: String, in roots: [String], home: String, what: String) throws {
        let expanded = roots.map { $0.expandingTilde(home: home) }
        guard expanded.contains(where: { isContained(path, in: $0) }) else {
            throw Violation("\(path) is not inside an approved \(what) path (\(expanded.joined(separator: ", ")))")
        }
    }
}
