import XCTest
// Plain import, not `@testable`: every symbol here is `public`, and importing it as the
// outside world does keeps the test honest about what surface it exercises.
import XCodeVaultHelperProtocol

/// The two code-signing requirements, and the property that matters most about them: they must not
/// drift apart.
///
/// Issue #30 — nothing in the tree opens an XPC connection, so the daemon's own requirement has
/// never been exercised against a real peer and the client-side one has no caller at all. What
/// *can* be pinned without a signed build is the shape of both strings, and specifically that
/// weakening one of them shows up as a failing test rather than as a plausible-looking constant.
///
/// This is the half of #30 that does not need signing. The connection itself stays M4.
final class HelperIdentityRequirementTests: XCTestCase {

    private let team = "ABCDE12345"

    /// The daemon validates clients; the client validates the daemon. Before #30 only the first
    /// existed, and a client resuming a connection without the second is talking to whoever holds
    /// that name in the global bootstrap namespace.
    func testEachSideNamesTheOtherAndNotItself() {
        let forClients = HelperIdentity.clientRequirement(teamID: team)
        let forHelper = HelperIdentity.helperRequirement(teamID: team)

        XCTAssertTrue(forClients.contains("com.xcodevault.app"), forClients)
        XCTAssertTrue(forClients.contains("com.xcodevault.xcodevaultctl"), forClients)
        XCTAssertFalse(
            forClients.contains(HelperIdentity.bundleIdentifier),
            "the daemon must not accept a connection from something claiming to be the daemon: \(forClients)")

        XCTAssertTrue(forHelper.contains(HelperIdentity.bundleIdentifier), forHelper)
        XCTAssertFalse(
            forHelper.contains("com.xcodevault.app") || forHelper.contains("com.xcodevault.xcodevaultctl"),
            "a client must accept only the daemon, not another client: \(forHelper)")
    }

    /// The load-bearing clauses, asserted individually rather than by comparing whole strings.
    ///
    /// A whole-string comparison would fail on any edit and so would be rewritten by whoever made
    /// the edit — including the edit that drops a clause. Each of these is a separate reason an
    /// impostor is rejected, and each has to be able to fail on its own.
    func testBothRequirementsCarryEveryClauseThatDoesWork() {
        for (name, requirement) in [
            ("client-side", HelperIdentity.clientRequirement(teamID: team)),
            ("helper-side", HelperIdentity.helperRequirement(teamID: team)),
        ] {
            XCTAssertTrue(requirement.hasPrefix("anchor apple generic"), "\(name): must chain to Apple's root — \(requirement)")
            XCTAssertTrue(
                requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6]"),
                "\(name): must require the Developer ID intermediate marker — \(requirement)")
            XCTAssertTrue(
                requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]"),
                "\(name): must require the Developer ID application leaf marker — \(requirement)")
            XCTAssertTrue(
                requirement.contains("certificate leaf[subject.OU] = \"\(team)\""),
                "\(name): must pin OUR team — `anchor apple generic` alone accepts any Developer ID binary from anyone — \(requirement)")
            XCTAssertTrue(requirement.contains("identifier"), "\(name): must pin an identifier — \(requirement)")
        }
    }

    /// **A requirement is weakened by `or`, not by deletion**, and `and` binds tighter than `or`.
    ///
    /// Three versions of this assertion have been defeated, each by a narrower reading of "an `or`":
    /// `contains(" or ")` missed a newline and a tab, and splitting on whitespace missed `"TEAM"or`
    /// and `)or(` — the grammar terminates a string literal at its closing quote, so `or` needs no
    /// whitespace before it at all. Both of those parse, and both reduce the requirement to "any
    /// Apple-anchored binary from any team".
    ///
    /// So this checks a **lexical** boundary — and it is deliberately named for what it can see.
    /// `withoutIdentifiers` returns a *prefix*, so an `or` **appended after** the identifier clause
    /// is truncated away before the regex runs, and that is the canonical weakening: `and` binds
    /// tighter than `or`, so `(… and identifier "X") or (anchor apple generic)` accepts any
    /// Developer ID binary from any team. This test does not catch it; an earlier name claimed it
    /// did. The exact pin below is what holds that case. Two further spellings — an `or` written
    /// `\u{6F}r`, and one assembled from split string literals — are caught by this test too, since
    /// both produce a literal `or` in the composed string; what cannot see them is the rule in
    /// `scripts/helper-invariants.sh`, which reads source text rather than the runtime value.
    func testNeitherRequirementCarriesADisjunctionAmongTheAnchorClauses() {
        for (name, requirement) in [
            ("client-side", HelperIdentity.clientRequirement(teamID: team)),
            ("helper-side", HelperIdentity.helperRequirement(teamID: team)),
        ] {
            XCTAssertNil(
                Self.withoutIdentifiers(requirement).range(of: "(?<![A-Za-z0-9_])or(?![A-Za-z0-9_])", options: .regularExpression),
                "\(name): an `or` among the anchor/OID/team clauses makes them all optional — \(requirement)")
        }
    }

    /// The exact strings, pinned.
    ///
    /// Every other assertion here is structural, and a reviewer got past the structural ones three
    /// times running. A security constant is one of the few things worth a golden comparison: an
    /// edit that changes what the daemon accepts should fail loudly and be updated deliberately,
    /// which is the whole point — the danger is the edit nobody had to think about.
    ///
    /// The clause-level assertions above are kept because this one cannot say *which* property was
    /// lost when it fails.
    func testBothRequirementsAreExactlyWhatIsExpected() {
        let common =
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        XCTAssertEqual(
            HelperIdentity.helperRequirement(teamID: team),
            common + " and identifier \"\(HelperIdentity.bundleIdentifier)\"")
        XCTAssertEqual(
            HelperIdentity.clientRequirement(teamID: team),
            common + " and (identifier \"com.xcodevault.app\" or identifier \"com.xcodevault.xcodevaultctl\")")
    }

    /// Everything up to the identifier clause. The client string's identifiers are parenthesised and
    /// the helper's is not, hence two separators.
    static func withoutIdentifiers(_ s: String) -> String {
        guard let cut = s.range(of: " and identifier ") ?? s.range(of: " and (identifier ") else { return s }
        return String(s[s.startIndex..<cut.lowerBound])
    }

    /// They differ in exactly one place. If a future edit weakens the anchor or drops a marker OID
    /// on one side only, this fails — which is the point: the dangerous version of that edit is the
    /// one that looks like a reasonable constant in isolation.
    func testTheTwoRequirementsDifferOnlyInTheIdentifierClause() {
        XCTAssertEqual(
            Self.withoutIdentifiers(HelperIdentity.clientRequirement(teamID: team)),
            Self.withoutIdentifiers(HelperIdentity.helperRequirement(teamID: team)),
            "everything before the identifier clause is the same security argument and must stay identical")
    }

    /// The team is substituted, not hardcoded, and a different team produces a different string.
    /// A requirement that ignored its argument would pin somebody else's team forever.
    func testTheTeamIsActuallySubstituted() {
        XCTAssertNotEqual(
            HelperIdentity.clientRequirement(teamID: "AAAAAAAAAA"), HelperIdentity.clientRequirement(teamID: "BBBBBBBBBB"))
        XCTAssertNotEqual(
            HelperIdentity.helperRequirement(teamID: "AAAAAAAAAA"), HelperIdentity.helperRequirement(teamID: "BBBBBBBBBB"))
    }

    /// The condition, not the string — see `isUsableTeamID`. The first version of this asked whether
    /// a requirement contained `"TEAMID"`, and this build ships `TEAMID_PLACEHOLDER`, so it answered
    /// "fine" for the only unsubstituted state it can produce. It passed because it synthesised a
    /// team `bundle-app.sh` would reject.
    func testAnUnusableTeamIsDetectable() {
        XCTAssertFalse(HelperIdentity.isUsableTeamID(HelperIdentity.teamIDPlaceholder), "the placeholder itself")
        XCTAssertFalse(HelperIdentity.isUsableTeamID(""), "a sed that matched nothing")
        XCTAssertFalse(HelperIdentity.isUsableTeamID("SHORT"), "too short")
        XCTAssertFalse(HelperIdentity.isUsableTeamID("abcde12345"), "lowercase is not an Apple team ID")
        XCTAssertFalse(HelperIdentity.isUsableTeamID("ABCDE 2345"), "nor is anything with a space")
        XCTAssertFalse(HelperIdentity.isUsableTeamID("ABCDE12345X"), "too long")
        XCTAssertTrue(HelperIdentity.isUsableTeamID(team))
        XCTAssertTrue(HelperIdentity.isUsableTeamID("1234567890"), "all digits is a valid shape")
    }

    /// The placeholder literal appears in four places that must agree, and three of them are outside
    /// Swift's reach: the daemon's source, the `sed` in the bundler, and the invariants script. This
    /// reads them and fails when they drift — which is how the B1 defect would have been caught by
    /// something other than a reviewer.
    func testEveryPlaceThatKnowsThePlaceholderAgreesOnIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["Sources/XCodeVaultHelper/main.swift", "scripts/bundle-app.sh", "scripts/helper-invariants.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertTrue(
                text.contains(HelperIdentity.teamIDPlaceholder),
                "\(relative) does not mention \(HelperIdentity.teamIDPlaceholder); the substitution chain is broken")
            // The bundler matches the whole assignment, so the daemon's spelling has to be exact:
            // `let teamID="TEAMID_PLACEHOLDER"` keeps the token and breaks the `sed`. That fails
            // closed at build time, but failing here says why.
            if relative.hasSuffix("main.swift") {
                XCTAssertTrue(
                    text.contains("let teamID = \"\(HelperIdentity.teamIDPlaceholder)\""),
                    "the daemon's assignment must be spelled exactly as bundle-app.sh's sed expects it")
            }
        }
    }

    /// The coupling `helperRequirement`'s doc says nothing else holds — so hold it.
    ///
    /// The daemon is a bare Mach-O with no `Info.plist`, so `codesign` would default its identifier
    /// to the binary's basename. `bundle-app.sh` passes `--identifier` explicitly; drop that flag and
    /// the requirement pinning `bundleIdentifier` rejects the real daemon. The comment saying so was
    /// written in the same pass as the machinery that can check it, which a reviewer noticed.
    func testTheBundlerSignsTheDaemonWithTheIdentifierTheRequirementPins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/bundle-app.sh"), encoding: .utf8)
        // Line-scoped, not a whole-file `contains`. The realistic mistake is not the flag vanishing
        // — it is the daemon's and the CLI's identifiers being swapped between two adjacent
        // `codesign` lines, which a file-wide substring test cannot see. A mention in a comment
        // would satisfy that test too.
        let signsTheDaemon = script.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("#") && l.contains("codesign") && l.contains("--identifier \(HelperIdentity.bundleIdentifier)")
                && l.contains("xcodevault-helper")
        }
        XCTAssertTrue(
            signsTheDaemon,
            "bundle-app.sh must sign the daemon binary as \(HelperIdentity.bundleIdentifier), or helperRequirement rejects it")
    }

    /// Both strings must parse as real code-signing requirements, not merely look like them.
    ///
    /// This is the one check that would catch a typo inside the OID brackets — every assertion above
    /// is a substring test, and a substring test cannot tell a valid requirement from a malformed
    /// one that happens to contain the right words.
    func testBothRequirementsParseAsCodeSigningRequirements() {
        for (name, requirement) in [
            ("client-side", HelperIdentity.clientRequirement(teamID: team)),
            ("helper-side", HelperIdentity.helperRequirement(teamID: team)),
        ] {
            var parsed: SecRequirement?
            let status = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
            XCTAssertEqual(status, errSecSuccess, "\(name) does not parse (OSStatus \(status)): \(requirement)")
            XCTAssertNotNil(parsed, name)
        }
    }
}
