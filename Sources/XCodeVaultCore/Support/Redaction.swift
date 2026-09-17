import Foundation

/// Removes machine-identifying strings from text that is about to be published.
///
/// `report` exists to be pasted into a public issue, so this is the Swift counterpart of
/// `xcv_redact` in `scripts/experiments/common.sh`. The two are deliberately kept in step: they are
/// the project's only redactors, they publish into the same places, and every defect found in one
/// has also been present in the other. The three the shell version had to learn under test, all of
/// which were present here too until 2026-09-17:
///
///   - **The home directory is a path prefix, not a word.** Unanchored, `/Users/dev` rewrites
///     `/Users/devops` into `~ops` — corrupting rather than protecting.
///   - **The account name needs a word boundary.** Unanchored, an account called `dev` turns
///     `devicectl` into `<user>icectl`, in text headed for a bug report.
///   - **The boot volume's name is an ordinary path component.** On a machine whose boot volume is
///     called `MacOS`, every app bundle contains `Contents/MacOS/`. Its name is therefore redacted
///     only in its `/Volumes/` form and never as a bare word; redacting a name is not worth
///     destroying the paths that are often the finding.
///
/// What deliberately survives: CoreSimulator's runtime and device identifiers, Apple's APFS
/// partition-type GUID, and OS/Xcode build numbers. None of them identifies a person, and several
/// findings are unreadable without them.
public struct Redaction: Sendable {
    private let rules: [(pattern: NSRegularExpression, template: String)]

    /// - Parameters:
    ///   - home: the invoking user's home directory.
    ///   - user: the invoking user's short name.
    ///   - volumes: every mounted volume, so labels and UUIDs can be redacted by value.
    public init(home: String, user: String, volumes: [Volume]) {
        var built: [(NSRegularExpression, String)] = []
        func add(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            built.append((re, template))
        }

        // Volume UUIDs first: a UUID is never an ordinary word, and it is the identifier the docs
        // tell you to use in place of a name, so it must not depend on any label rule matching.
        for v in volumes {
            if let uuid = v.volumeUUID, !uuid.isEmpty { add(Self.quote(uuid), "<vault-uuid>") }
        }
        // Then the home, anchored: a trailing word character means this is a longer path that only
        // starts the same way, and must be left alone.
        if !home.isEmpty { add(Self.quote(home) + "(?![A-Za-z0-9_])", "~") }
        // Then the account name, word-bounded. `root` is a subject in this project's output, not an
        // identity to hide, and substituting it corrupts every mention of root-owned anything.
        if !user.isEmpty, user != "root" { add(Self.bounded(user), "<user>") }

        for v in volumes where !v.volumeName.isEmpty {
            let marker = v.isBootVolume ? "<bootvolume>" : "<vault>"
            add("/Volumes/" + Self.quote(v.volumeName), "/Volumes/" + marker)
            if v.isBootVolume {
                // The boot volume's name is redacted as a *name* but never as a path component, and
                // `(?<!/)` is what tells those apart: `Contents/MacOS/…` is preceded by a slash and
                // survives, while the `volumeName` field, or prose calling it "the MacOS volume",
                // does not. Without the lookbehind this rule rewrites every application bundle path
                // in the report; without the rule at all, a boot volume named after its owner is
                // published verbatim.
                add("(?<!/)" + Self.bounded(v.volumeName), marker)
            } else {
                add(Self.bounded(v.volumeName), marker)
            }
        }
        rules = built
    }

    public func callAsFunction(_ s: String) -> String { redact(s) }

    public func redact(_ s: String) -> String {
        rules.reduce(s) { acc, rule in
            rule.pattern.stringByReplacingMatches(
                in: acc, range: NSRange(acc.startIndex..., in: acc), withTemplate: rule.template)
        }
    }

    /// A literal, safe to embed in a pattern.
    private static func quote(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    /// A literal with word boundaries, but **only where a boundary can fire**. `\b` sits between a
    /// word and a non-word character, so a label like `Backup.` has no boundary after its dot and
    /// `\bBackup\.\b` matches nothing at all — the silent-no-op failure the shell version shipped.
    /// Where the edge is not a word character the literal's own punctuation delimits it, and the
    /// rule over-redacts rather than leaking.
    private static func bounded(_ s: String) -> String {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let lead = s.unicodeScalars.first.map { word.contains($0) } ?? false ? "\\b" : ""
        let trail = s.unicodeScalars.last.map { word.contains($0) } ?? false ? "\\b" : ""
        return lead + quote(s) + trail
    }
}
