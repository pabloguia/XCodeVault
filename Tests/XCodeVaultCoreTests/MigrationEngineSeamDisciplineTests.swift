import XCTest

@testable import XCodeVaultCore

/// Two properties of `MigrationEngine`'s declaration that the compiler will not hold for us.
///
/// **Why a source-scanning test rather than a normal one.** Issue #27 converted one seam to `let`
/// and #31 converted the remaining seven, and nothing anywhere would notice them going back.
///
/// **What keeps the hooks off the public API: `internal`.** An early version of this file claimed
/// it was their *absence of a default* — that giving them one would make the two initialisers
/// ambiguous and reopen the public path. A reviewer disproved it: `= nil` draws no diagnostic, and
/// a cross-module caller still fails with `extra argument 'afterCopy' in call`. The defaults do a
/// smaller job — they tell the two in-module initialisers apart, so a call naming neither hook
/// lands on the public one by shape rather than by an overload-ranking rule. Both are asserted
/// below, for their real reasons.
///
/// **This file has been vacuous three times, for three different reasons**, each found by a
/// reviewer rather than by it failing: it read `MigrationError`'s initialiser instead of this one;
/// its parameter splitter counted `->`'s `>` as a bracket and found no parameters at all; and it
/// scanned only the struct body, missing extension initialisers, label/name splits, and braces
/// written in prose. Every assertion below therefore carries a positive control, because a check
/// that cannot tell "clean" from "I did not run" is not a check.
///
/// **What it still does not catch.** Every claim here was measured — build, `swift format lint
/// --strict`, then the tests — because the previous version of this paragraph asserted five things
/// and a reviewer found four of them false, in the one place whose whole job was to be honest
/// about limits.
///
/// - `@MainActor public var journal2: Int = 0` inside the struct: **builds, lints clean, passes.**
///   The property regex is anchored at the start of a trimmed line, so any attribute before the
///   access modifier hides the declaration. An earlier version named this exact spelling as the one
///   case a `Sendable` struct *cannot* have; it compiles here under `.swiftLanguageMode(.v6)`.
/// - A line break after `var` (`public var` ⏎ `journal2: Int = 0`) escapes the same regex, but
///   `swift format lint --strict` flags it (`[RemoveLine]`), so `scripts/preflight.sh` covers it.
///   A break after `public` whose continuation keeps the same indent is caught by *both*; indent
///   that continuation further and it escapes both, which a sixth reviewer measured.
/// - **Any public member other than an initialiser that constructs through the internal one.**
///   `public static func withHooks(…) -> MigrationEngine` and a non-mutating `withAfterCopy(_:)`
///   both build, lint clean, and pass all four tests below, handing a caller outside this module
///   both fault-injection hooks with every property still `let` — the capability the fourth test
///   denies, reached by a more idiomatic route than `mutating` + `self =`. Enumerating shapes does
///   not terminate (`callAsFunction`, a public subscript, a factory returning a `KeyPath`…), so it
///   is not patched here. **`scripts/public-surface.sh` closes it** (issue #32): it asks the
///   compiler through `swift symbolgraph-extract` and asserts that no public member of
///   `MigrationEngine` takes a fault-injection hook and no public property is settable. Both
///   `withHooks` and `withAfterCopy` die there, as does `@MainActor public var` — which neither
///   this file nor the first version of that gate could see, both for the same reason: a pattern
///   anchored at the start of a declaration does not survive an attribute being put in front of it.
///
///   What that gate does *not* cover, and this file does: in-module settability. A seam reachable
///   only inside `XCodeVaultCore` never appears in the public surface, and in-module reassignment
///   is what #27 and #31 were about.
///
/// Closed since, rather than listed: tabs between `init` and its parameter list (`"\t"`/`"\r"` are
/// now skipped); an unterminated literal blinding the whole-file scan (`engineChars()` fails on a
/// non-empty frame stack at EOF); and `public mutating func` (its own test below).
///
/// `blanked(_:)` still handles no multiline (`"""`) or raw (`#"`) literal, and `MigrationEngine`
/// has neither today. If one appears, the EOF control fires rather than the scan going quiet.
///
/// Nothing here pins `VaultVerifier`'s or `CleanExecutor`'s seams, which remain `public var` — see
/// the pointer in `MigrationEngine.swift`.
///
/// The idiom is the one `DoctorFamilyCompositionTests` already uses in this suite: read the source
/// and assert a shape. It is blunt, and it is the only thing that can fail here.
final class MigrationEngineSeamDisciplineTests: XCTestCase {

    private func engineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/XCodeVaultCore/Migration/MigrationEngine.swift"), encoding: .utf8)
    }

    /// The file with comment bodies and string contents blanked out, character-for-character, so
    /// every offset still points at the same place in the original.
    ///
    /// Brace counting without this reads braces in prose. `MigrationEngine` carries brace-bearing
    /// comments (`MigrationEngine.swift:103`, `:134`) and brace-bearing interpolations (`:863`),
    /// balanced today only by luck; a reviewer showed that one unbalanced `}` in a sentence
    /// truncates the body, everything after it silently stops being scanned, and a re-added
    /// `public var` goes unseen. Interpolations are treated as the code they are — `\("...")`
    /// nests a string inside a string, and a naive scan desynchronises there.
    private func blanked(_ source: String) -> (chars: [Character], openFrames: Int) {
        enum Frame { case string, interpolation(depth: Int) }
        let c = Array(source)
        var out: [Character] = []
        var stack: [Frame] = []
        var block = 0
        var i = 0

        func put(_ ch: Character, blank: Bool) { out.append(blank && ch != "\n" ? " " : ch) }
        func inString() -> Bool { if case .string = stack.last { return true }; return false }

        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil

            if block > 0 {  // Swift block comments nest.
                if ch == "/" && next == "*" { block += 1; put(" ", blank: false); put(" ", blank: false); i += 2; continue }
                if ch == "*" && next == "/" { block -= 1; put(" ", blank: false); put(" ", blank: false); i += 2; continue }
                put(ch, blank: true); i += 1; continue
            }
            if inString() {
                if ch == "\\" && next == "(" {
                    stack.append(.interpolation(depth: 1))
                    put(" ", blank: false); put("(", blank: false)  // keep the paren balanced for readers
                    i += 2; continue
                }
                if ch == "\\" { put(ch, blank: true); if next != nil { put(c[i + 1], blank: true); i += 1 }; i += 1; continue }
                if ch == "\"" { stack.removeLast(); put(" ", blank: false); i += 1; continue }
                put(ch, blank: true); i += 1; continue
            }
            // Code, including inside an interpolation.
            if ch == "/" && next == "/" { while i < c.count && c[i] != "\n" { put(c[i], blank: true); i += 1 }; continue }
            if ch == "/" && next == "*" { block = 1; put(" ", blank: false); put(" ", blank: false); i += 2; continue }
            if ch == "\"" { stack.append(.string); put(" ", blank: false); i += 1; continue }
            if case .interpolation(let d) = stack.last {
                if ch == "(" { stack[stack.count - 1] = .interpolation(depth: d + 1) }
                if ch == ")" {
                    if d == 1 { stack.removeLast(); put(")", blank: false); i += 1; continue }
                    stack[stack.count - 1] = .interpolation(depth: d - 1)
                }
            }
            put(ch, blank: false); i += 1
        }
        return (out, stack.count + (block > 0 ? 1 : 0))
    }

    private func engineChars() throws -> (raw: [Character], scan: [Character]) {
        let s = try engineSource()
        let (scan, openFrames) = blanked(s)
        // The sibling of the column-0 control below, and the one that covers the rest of the file.
        // `engineBodyPair()` stops at the struct's closing brace, but the initialiser scan runs to
        // EOF — so a literal the lexer cannot close (a `"""` body with an odd number of quotes,
        // placed *after* the struct) blinded that scan from there on while every body-scoped
        // control stayed green. A reviewer hid a public hook initialiser exactly there.
        XCTAssertEqual(
            openFrames, 0,
            "the blanking scanner reached end-of-file inside a string or comment, so an unknown part of "
                + "MigrationEngine.swift was never scanned. Nothing this file asserts is trustworthy until that is fixed "
                + "— most likely a multiline (\"\"\") or raw (#\") literal, which blanked(_:) does not handle.")
        return (Array(s), scan)
    }

    private func find(_ needle: String, in hay: [Character], from: Int) -> Int? {
        let n = Array(needle)
        guard n.count <= hay.count else { return nil }
        var i = max(0, from)
        while i + n.count <= hay.count {
            if Array(hay[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }

    /// `MigrationEngine`'s own body, delimited by counting braces over the blanked text.
    ///
    /// Earlier versions of this had two blind spots a reviewer demonstrated: it scanned only as far
    /// as the first `public init(`, and that search covered the whole file so it matched
    /// `MigrationError`'s — leaving both hook assertions inspecting the signature `_ d: String`.
    private func engineBodyPair() throws -> (raw: String, code: String) {
        let (raw, scan) = try engineChars()
        guard let decl = find("public struct MigrationEngine: Sendable {", in: scan, from: 0) else {
            XCTFail("could not find MigrationEngine; this test is reading the wrong shape")
            return ("", "")
        }
        let open = decl + Array("public struct MigrationEngine: Sendable {").count - 1
        var depth = 0
        var i = open
        while i < scan.count {
            if scan[i] == "{" { depth += 1 }
            if scan[i] == "}" {
                depth -= 1
                if depth == 0 {
                    // Control against silent truncation: the struct's closing brace is the only one
                    // in its span at column 0. Stopping at an indented `}` means the count went
                    // wrong somewhere above and everything after that point went unscanned.
                    XCTAssertTrue(
                        i == 0 || scan[i - 1] == "\n",
                        "MigrationEngine's body ended at an indented `}`, so brace counting desynchronised and the rest of "
                            + "the struct was never scanned. Every assertion built on this body is worthless until it is fixed.")
                    return (String(raw[(open + 1)..<i]), String(scan[(open + 1)..<i]))
                }
            }
            i += 1
        }
        XCTFail("MigrationEngine's braces do not balance; this test is reading the wrong shape")
        return ("", "")
    }

    private func engineBody() throws -> String { try engineBodyPair().raw }

    /// The same span with comments and string contents blanked. Declaration checks run against
    /// this: `body.contains("let afterCopy")` was satisfiable by a *comment* mentioning it, which
    /// made that positive control the weakest of the three.
    private func engineBodyCode() throws -> String { try engineBodyPair().code }

    /// Split a parameter list on the commas separating parameters, ignoring commas nested in a
    /// parameter's own type — `(A, B) -> Void` is one parameter, not two.
    private func parameters(of list: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        let chars = Array(list)
        for (i, c) in chars.enumerated() {
            if c == "(" || c == "[" || c == "<" { depth += 1 }
            // `->` is not a closing bracket. Counting its `>` drove depth negative, which is why an
            // earlier version found zero parameters in `(@Sendable (T) throws -> Void)?` and reported
            // zero initialisers taking either hook — vacuous again, one layer down.
            if c == ">" && i > 0 && chars[i - 1] == "-" { current.append(c); continue }
            if c == ")" || c == "]" || c == ">" { depth -= 1 }
            if c == "," && depth == 0 {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return out.filter { !$0.isEmpty }
    }

    /// A parameter's **external label** — the name a caller writes. `afterCopy: T` and
    /// `afterCopy hook: T` are both called as `afterCopy:`, and matching on the prefix `"afterCopy:"`
    /// sees only the first. A reviewer reopened the public hook with the second spelling.
    private func firstLabel(of parameter: String) -> String {
        String(parameter.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// The nearest enclosing `extension`/`struct` declaration before `offset`, and whether it is
    /// `public`.
    ///
    /// `public extension MigrationEngine { init(afterCopy:) }` makes that initialiser public while
    /// its own line says nothing about access. Reading only the initialiser's line reported it
    /// `internal` — and the assertion that misread it is precisely the one that names access level.
    private func enclosingIsPublicExtension(before offset: Int, in scan: [Character]) -> Bool {
        var best = -1
        var isPublicExtension = false
        for needle in ["extension MigrationEngine", "struct MigrationEngine"] {
            var from = 0
            while let at = find(needle, in: scan, from: from), at < offset {
                var lineStart = at
                while lineStart > 0 && scan[lineStart - 1] != "\n" { lineStart -= 1 }
                if at > best {
                    best = at
                    isPublicExtension = needle.hasPrefix("extension") && String(scan[lineStart..<at]).contains("public")
                }
                from = at + 1
            }
        }
        return isPublicExtension
    }

    /// Every initialiser declared **anywhere in the file**, as (isPublic, its parameters).
    ///
    /// Whole-file, not struct-body: `extension MigrationEngine { public init(afterCopy:) { ... } }`
    /// is legal Swift, publicly reopens the hook, and was invisible to a body-scoped scan — the
    /// third way a reviewer defeated this file. `MigrationEngine.swift` already has an extension.
    ///
    /// `init` is matched as a **token**, then generics and whitespace are skipped before the
    /// parameter list is required. Searching for the literal `"init("` was the fourth way through:
    /// `public init<T>(afterCopy:)` declares a public initialiser taking both hooks, was invisible
    /// here, and `swift-format lint --strict` does not flag it either. An initialiser this scan
    /// cannot see is indistinguishable from one that does not exist — which is why the count
    /// assertion below cannot cover for it.
    private func allInitialisers() throws -> [(isPublic: Bool, parameters: [String])] {
        let (raw, scan) = try engineChars()
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var result: [(Bool, [String])] = []
        var search = 0
        while let kw = find("init", in: scan, from: search) {
            search = kw + 4
            if kw > 0 && (scan[kw - 1] == "." || isWord(scan[kw - 1])) { continue }  // `.init`, `reinit`
            if kw + 4 < scan.count && isWord(scan[kw + 4]) { continue }  // `initialise`

            var j = kw + 4
            loop: while j < scan.count {
                switch scan[j] {
                case " ", "\t", "\r", "\n", "?", "!":  // whitespace, and failable initialisers
                    j += 1
                case "<":  // a generic parameter list
                    var d = 0
                    while j < scan.count {
                        if scan[j] == "<" { d += 1 }
                        if scan[j] == ">" {
                            d -= 1
                            if d == 0 {
                                j += 1
                                break
                            }
                        }
                        j += 1
                    }
                default:
                    break loop
                }
            }
            guard j < scan.count, scan[j] == "(" else { continue }

            var lineStart = kw
            while lineStart > 0 && scan[lineStart - 1] != "\n" { lineStart -= 1 }
            let isPublic = String(scan[lineStart..<kw]).contains("public") || enclosingIsPublicExtension(before: kw, in: scan)

            var depth = 0
            var i = j
            var end = i
            while i < scan.count {
                if scan[i] == "(" { depth += 1 }
                if scan[i] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = i
                        break
                    }
                }
                i += 1
            }
            // The blanked span, not the raw one. `j` and `end` are computed on `scan`, and slicing
            // `raw` here put comments back in front of a bracket counter: one unbalanced `(` inside
            // a `//` comment in a parameter list — `// TODO(pirado: reorder` does it by accident —
            // pins depth above zero, so no comma is ever top-level, the whole list collapses into a
            // single pseudo-parameter, and every hook in that initialiser goes unseen.
            result.append((isPublic, parameters(of: String(scan[(j + 1)..<end]))))
            search = end
        }
        return result
    }

    /// No seam may go back to being settable after construction.
    ///
    /// `verifier` is the one worth naming. It is not, as an earlier version of this comment said,
    /// the switch that "disables verification wholesale" — the byte-and-metadata comparison runs
    /// through `verifierFor(_:)`, which builds a `TreeVerifier` and never consults this property.
    /// What `verifier` decides is `resolveUsable`: whether the named vault volume is mounted and
    /// usable at all, and which directory on it is the vault. A stub there points a migration at a
    /// path of the caller's choosing while reporting the vault healthy. That is a different lever
    /// from `volumeUUIDAt`'s single lying lookup, and neither contains the other.
    func testNoSeamOnTheEngineIsPubliclySettable() throws {
        let body = try engineBody()
        // Positive control: the body must contain the seams this is meant to be looking at.
        XCTAssertTrue(
            body.contains("public let verifier:") && body.contains("public let runner:"),
            "the scanned body does not contain the seams, so nothing below is checking anything")

        let offenders = body.split(separator: "\n")
            // Stored properties sit exactly one level in. Locals inside method bodies are deeper,
            // are not seams, and drowned an earlier version of this in false positives.
            .filter { $0.hasPrefix("    ") && !$0.hasPrefix("     ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^((public|internal|private|fileprivate)\s+)?(\w+\(set\)\s+)?var\s+\w+"#, options: .regularExpression) != nil }
        XCTAssertEqual(
            offenders, [],
            "every seam on MigrationEngine must be `let`, set through `init` (issues #27, #31). Settable again: \(offenders)")
    }

    /// The two fault-injection hooks must stay off every public initialiser, and carry no default.
    ///
    /// They execute caller-supplied code in the middle of a migration. Nothing in `Sources/` passes
    /// either one — they exist for tests — and `internal` is what keeps them reachable from here and
    /// nowhere else.
    func testTheFaultInjectionHooksCarryNoDefaultAndStayOffThePublicInitialiser() throws {
        let initialisers = try allInitialisers()
        XCTAssertGreaterThanOrEqual(initialisers.count, 2, "expected at least the public initialiser and the internal one")

        for hook in ["afterCopy", "afterRenameAside"] {
            let declaring = initialisers.filter { $0.parameters.contains { firstLabel(of: $0) == hook } }
            // Positive control. Without it the whole test passes by finding nothing, which is what
            // two earlier versions did — one reading the wrong initialiser, one parsing no
            // parameters at all. A rename, or a fourth way of hiding the parameter, lands here.
            XCTAssertEqual(
                declaring.count, 1,
                "expected exactly one initialiser in the file to declare \(hook); found \(declaring.count). Either it was "
                    + "renamed — in which case this test now checks nothing and must be updated — or a second initialiser, "
                    + "possibly in an extension, also takes it.")

            for (isPublic, parameters) in declaring {
                XCTAssertFalse(isPublic, "no public initialiser may take \(hook) — a fault-injection hook on the public API")
                let parameter = parameters.first { firstLabel(of: $0) == hook } ?? ""
                // No default, in any spelling. An earlier version looked for the literal `= nil` and
                // a reviewer walked past it with `= .none`.
                XCTAssertFalse(
                    parameter.contains("="),
                    "\(hook) has a default again: `\(parameter)`. That does not by itself reopen the public path — `internal` "
                        + "does that work — but it is what tells the two in-module initialisers apart, so defaulting it makes "
                        + "the overload chosen by argument count rather than by intent.")
            }
        }
    }

    /// No `public mutating func`, because one reopens every seam without a `var` anywhere.
    ///
    /// `let` properties cannot be assigned individually, so this looked unreachable and two earlier
    /// versions of the paragraph above said so — one calling it "a `public mutating func` assigning
    /// a seam" (impossible), a reviewer calling it "not achievable as written". Neither was
    /// measured. It is reachable by reassigning **`self`** through the internal initialiser:
    ///
    ///     public mutating func installHook(_ h: @escaping @Sendable (MigrationPlan) throws -> Void) {
    ///         self = MigrationEngine(runner: runner, ..., afterCopy: h, ...)
    ///     }
    ///
    /// Measured on this toolchain: it builds, `swift format lint --strict` reports nothing, all
    /// three tests above pass, and `xcodevaultctl` can then install a fault-injection hook. The
    /// struct has no such method today; adding one should be a deliberate act that edits this test.
    func testTheEngineHasNoPublicMutatingFunction() throws {
        let body = try engineBodyCode()
        XCTAssertTrue(body.contains("public let verifier:"), "the scanned body does not contain the seams; nothing here is checking anything")
        let offenders = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("public mutating func") }
        XCTAssertEqual(
            offenders, [],
            "a `public mutating func` can reassign `self` through the internal initialiser and hand a caller outside this "
                + "module both fault-injection hooks, with every property still `let`. Found: \(offenders)")
    }

    /// The hooks are internal, which is what `@testable` reaches. A `public` on either would put a
    /// named fault-injection point back on a type the CLI can construct.
    func testTheHooksAreNotPublic() throws {
        let body = try engineBodyCode()
        for hook in ["afterCopy", "afterRenameAside"] {
            XCTAssertFalse(body.contains("public let \(hook)"), "\(hook) must stay internal")
            XCTAssertTrue(body.contains("let \(hook)"), "\(hook) is not declared where this test expects it")
        }
    }
}
