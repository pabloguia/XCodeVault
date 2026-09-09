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

    /// True if the symlink at `link` redirects into `candidate`, or `candidate` into it.
    ///
    /// Written once here because three copies of "read a link, resolve it, compare" had accumulated
    /// in `Doctor`, each missing a different shape. All of these are the fail-open direction — the
    /// caller concludes "nothing points here" and offers to delete something still in use:
    ///
    /// - **Relative destinations.** `destinationOfSymbolicLink` returns the raw string, so
    ///   `../../ext/x` never string-matches an absolute candidate. Resolved against the link's own
    ///   directory.
    /// - **Chained symlinks.** A link to a link to the candidate matches nothing at one hop.
    ///   `realpath(3)` follows the whole chain.
    /// - **Doubled slashes and `.` components.** `URL.standardized` does not collapse the empty
    ///   component in `/a//b`; `realpath` does.
    /// - **Containment in *both* directions.** A redirect at `~/Library/Developer` pointing at the
    ///   volume root contains the candidate rather than being contained by it — the mac-ssd-rescue
    ///   layout, and the one most likely to matter.
    ///
    /// Comparison is case-insensitive **on purpose**, even though `realpath` does not case-normalise
    /// on macOS and the user's volume may be case-sensitive (where `Foo` and `foo` really are
    /// different). It over-matches, and over-matching is the safe direction here: a false positive
    /// only withholds a deletion suggestion, while a false negative offers to delete a live target.
    public static func symlinkRedirectsBetween(_ link: String, _ candidate: String) -> Bool {
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return false }
        let base = (link as NSString).deletingLastPathComponent
        let lexical = raw.hasPrefix("/") ? raw : base + "/" + raw
        // `realpath` needs the path to exist; a dangling target still deserves a lexical comparison,
        // so fall back rather than reporting "not targeted" for a link into a directory we are about
        // to be asked about.
        let resolvedTarget = realpath(lexical, nil).map { p -> String in defer { free(p) }; return String(cString: p) }
            ?? URL(fileURLWithPath: lexical).standardized.path
        let resolvedCandidate = realpath(candidate, nil).map { p -> String in defer { free(p) }; return String(cString: p) }
            ?? URL(fileURLWithPath: candidate).standardized.path
        let a = resolvedTarget, b = resolvedCandidate
        return a.caseInsensitiveCompare(b) == .orderedSame
            || a.lowercased().hasPrefix(b.lowercased() + "/")
            || b.lowercased().hasPrefix(a.lowercased() + "/")
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
