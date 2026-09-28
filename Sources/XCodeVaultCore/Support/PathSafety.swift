import Foundation

/// Canonical-path containment checks. String prefix tests are not enough: `..`, interior
/// symlinks and trailing slashes all escape them (migration-safety review, 2026-09-06).
public enum PathSafety {
    public struct Violation: DescribedError, Sendable {
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
        let resolvedTarget =
            realpath(lexical, nil).map { p -> String in
                defer { free(p) }; return String(cString: p)
            }
            ?? URL(fileURLWithPath: lexical).standardized.path
        let resolvedCandidate =
            realpath(candidate, nil).map { p -> String in
                defer { free(p) }; return String(cString: p)
            }
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

    /// `canonicalize` for a directory about to be created together with any folders missing on the way to it, which
    /// `canonicalize` refuses: `realpath(3)` fails with `ENOENT` when any folder in the path is missing, the last
    /// included (migration-safety review of deliverable 4, F9; measured again 2026-09-28).
    ///
    /// The deepest parent that exists is resolved through `realpath`, and the folders below it, which do not exist,
    /// are appended as written; `..` and `.` are refused as in `canonicalize`, so what is appended means what it says.
    /// Existence is `lstat`, so a symlink on the way counts as existing whatever it points at, and is resolved: one
    /// pointing out of the root fails the comparison, and a dangling one fails `realpath` and refuses. Any `lstat`
    /// answer but "no such file" refuses too: a folder that cannot be looked up (`EACCES`), or a path under a file
    /// (`ENOTDIR`), is not known to be missing. With every parent present this is `canonicalize` exactly.
    ///
    /// Internal, and a new function rather than a change to `canonicalize`, so no other caller's answer changes.
    static func canonicalizeAllowingMissingParents(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw Violation("\(path): not an absolute path") }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.contains("..") && !comps.contains(".") else { throw Violation("\(path): relative components are not allowed") }
        guard let last = comps.last else { return "/" }
        var existing = Array(comps.dropLast())
        var missing: [String] = []
        while !existing.isEmpty {
            let p = "/" + existing.joined(separator: "/")
            var st = stat()
            if lstat(p, &st) == 0 { break }
            let code = errno
            guard code == ENOENT else { throw Violation("\(p): \(String(cString: strerror(code)))") }
            missing.insert(existing.removeLast(), at: 0)
        }
        let parent = "/" + existing.joined(separator: "/")
        guard let real = realpath(parent, nil) else { throw Violation("\(parent): \(String(cString: strerror(errno)))") }
        defer { free(real) }
        let base = String(cString: real)
        let tail = (missing + [last]).joined(separator: "/")
        return base == "/" ? "/" + tail : base + "/" + tail
    }

    /// `isContained` for a directory about to be created with its missing parents. Throws when where it would be
    /// created cannot be told, which is a different answer from "outside".
    ///
    /// It does not check that `root` exists: a missing root contains its would-be children here, where `isContained`
    /// says no (migration-safety review of F9). The caller asserts that the root is there — `VaultRegistry.register`
    /// asserts the mount before and after this check, and before it writes to the volume.
    static func isContainedAllowingMissingParents(_ path: String, in root: String) throws -> Bool {
        let p = try canonicalizeAllowingMissingParents(path)
        let r = try canonicalize(root)
        return p == r || p.hasPrefix(r + "/")
    }

    // `requireContained(_:in:home:what:)` lived here until 2026-09-15 and is deliberately gone.
    // Every caller passed a category's `pathTemplates`, which for a per-device category names the
    // enclosing CoreSimulator device set rather than the category — so the check accepted the whole
    // set, every device, and every app container inside them. `StorageCategory.containsPath` is now
    // the one definition of "is this path this category", and leaving a broader helper here invited
    // the next caller to reach for it again. Use `isContained` for plain "is A under B" questions,
    // which is all it ever claimed to answer.
}
