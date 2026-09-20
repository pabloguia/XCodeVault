import XCTest

@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperProtocol

/// The client half of the XPC boundary (issue #30).
///
/// **What these can and cannot prove.** They exercise every decision the client makes *before* a
/// message is exchanged: whether it will connect at all, what requirement it demands, and in what
/// order it configures the connection. They cannot prove the daemon accepts it, because
/// `SMAppService` will not register an unsigned daemon — that is M5 and
/// `COMPATIBILITY_MATRIX.md` records it as pending rather than as working.
final class HelperClientTests: XCTestCase {

    /// Records the order of the two calls that matter, because the ordering *is* the safety
    /// property: a requirement set after `resume()` leaves a window in which the connection is live
    /// and unvalidated.
    private final class RecordingConnection: NSXPCConnection, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        // Records the *value*, not just that the call happened. The first version appended a bare
        // "requirement" and a reviewer showed that `connect()` could call `peerRequirement()` for
        // its throwing side effect and then hand `setCodeSigningRequirement` an empty string — the
        // single property this file exists to hold — while all seven tests passed.
        override func setCodeSigningRequirement(_ requirement: String) {
            lock.lock()
            events.append("requirement:\(requirement)")
            lock.unlock()
        }
        override func resume() {
            lock.lock()
            events.append("resume")
            lock.unlock()
        }
    }

    private func client(team: String, recorder: RecordingConnection) -> HelperClient {
        HelperClient(team: team, makeConnection: { _ in recorder })
    }

    private let goodTeam = "ABCDE12345"

    // MARK: - The refusal, which is the shipped behaviour today

    func testTheShippedClientRefusesToConnectBecauseItHasNoRealTeamID() {
        // The public initialiser, exactly as the app or CLI would build it. Until
        // `scripts/bundle-app.sh --sign` substitutes a real team, this is the placeholder and the
        // client must refuse rather than open an unvalidated connection.
        XCTAssertThrowsError(try HelperClient().peerRequirement()) { e in
            XCTAssertEqual(e as? HelperClient.Failure, .unusableTeamID(HelperClient.teamID))
        }
    }

    func testRefusalNeverReachesTheConnection() throws {
        let recorder = RecordingConnection()
        XCTAssertThrowsError(try client(team: HelperIdentity.teamIDPlaceholder, recorder: recorder).connect())
        // Not merely "it threw": nothing was configured and nothing was resumed. A refusal that
        // still resumed the connection would be the bug this guards, wearing an error message.
        XCTAssertEqual(recorder.events, [], "a refused connection must not be touched at all")
    }

    func testAMalformedTeamIDIsRefusedTheSameWayAsThePlaceholder() {
        // `isUsableTeamID` is about shape, not about equality with the placeholder — the distinction
        // a reviewer had to force once already, when a check asked whether a string contained
        // "TEAMID" and this build system ships "TEAMID_PLACEHOLDER".
        for bad in ["", "SHORT", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE-1234"] {
            XCTAssertThrowsError(try HelperClient(team: bad, makeConnection: { _ in NSXPCConnection() }).peerRequirement(), bad)
        }
    }

    // MARK: - The requirement itself

    func testTheRequirementIsTheOneTheProtocolDefinesAndItParses() throws {
        let requirement = try HelperClient(team: goodTeam, makeConnection: { _ in NSXPCConnection() }).peerRequirement()
        XCTAssertEqual(requirement, HelperIdentity.helperRequirement(teamID: goodTeam))

        // Parsed here too, independently of the client having parsed it. `setCodeSigningRequirement`
        // raises an Objective-C exception on a malformed string, which Swift cannot catch — the
        // process would die. This asserts the string the client would hand it is well-formed.
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &parsed), errSecSuccess)
        XCTAssertNotNil(parsed)
    }

    func testTheRequirementPinsTheDaemonIdentityAndNotTheClientIdentity() throws {
        let requirement = try HelperClient(team: goodTeam, makeConnection: { _ in NSXPCConnection() }).peerRequirement()
        XCTAssertTrue(requirement.contains("identifier \"\(HelperIdentity.bundleIdentifier)\""))
        // The client's own identifiers belong in the requirement the *daemon* enforces. Finding one
        // here would mean the two requirements had been transposed, which no test asserted before.
        XCTAssertFalse(requirement.contains("com.xcodevault.app"))
        XCTAssertFalse(requirement.contains("com.xcodevault.xcodevaultctl"))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains(goodTeam))
    }

    // MARK: - Ordering

    func testTheRequirementIsSetBeforeTheConnectionIsResumed() throws {
        let recorder = RecordingConnection()
        _ = try client(team: goodTeam, recorder: recorder).connect()
        XCTAssertEqual(
            recorder.events, ["requirement:\(HelperIdentity.helperRequirement(teamID: goodTeam))", "resume"],
            "the requirement must be the protocol's, and must be set before resume() — afterwards leaves the connection "
                + "live and unvalidated, and a different string leaves it validated against the wrong peer")
    }

    // MARK: - The build-time marker

    /// The placeholder `scripts/bundle-app.sh` substitutes must exist, exactly once, in the spelling
    /// the script's `sed` expects — and the script must assert its own substitution landed.
    ///
    /// Source-scanning for the reason `MigrationEngineSeamDisciplineTests` is: nothing else notices
    /// a rename on either side. A `sed` that matches nothing leaves the placeholder in place, the
    /// client then refuses every connection, and the release is silently inert — fail-closed, but
    /// fail-closed in a shipped artefact is still a broken release.
    func testTheTeamIDMarkerMatchesWhatTheBundleScriptSubstitutes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let client = try String(contentsOf: root.appendingPathComponent("Sources/XCodeVaultHelperClient/HelperClient.swift"), encoding: .utf8)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/bundle-app.sh"), encoding: .utf8)

        let marker = "let teamID = \"\(HelperIdentity.teamIDPlaceholder)\""
        let occurrences = client.components(separatedBy: marker).count - 1
        XCTAssertEqual(occurrences, 1, "the marker must appear exactly once; a second would make the script's sed ambiguous")

        XCTAssertTrue(
            script.contains("Sources/XCodeVaultHelperClient/HelperClient.swift"),
            "bundle-app.sh does not substitute the client's team ID, so a signed build would ship a client that refuses every connection")
        XCTAssertTrue(
            script.contains("CLIENT_SRC"),
            "bundle-app.sh names no client source variable; the substitution and its assertion are what this depends on")

        // `.privileged` is what sends this to the *root* LaunchDaemon in the global bootstrap
        // namespace. Without it the connection resolves in the per-user namespace, where any local
        // user can register a LaunchAgent under the same name. The requirement still limits that
        // impostor to a copy of our own signed daemon run unprivileged — so this is reply-spoofing,
        // not root escalation — but nothing else in the tree held it.
        XCTAssertTrue(
            client.contains("options: .privileged"),
            "the connection must be .privileged, or it resolves in the per-user bootstrap namespace")
    }

    // MARK: - The paths the quality gate found untested (issue #34)
    //
    // SonarQube reported 25 of this file's 54 new lines uncovered, which put `new_coverage` at 60.9%
    // against a threshold of 80 and turned the gate red. That is the gate doing its job: the client
    // added for issue #30 shipped with its error messages, its production connection factory and its
    // launchd status accessor never once executed. These cover them.

    func testEveryFailureExplainsItselfAndTheTeamIDOneDoesNotQuoteTheValue() {
        // Not "the description is non-empty". The `unusableTeamID` case has a deliberate property —
        // it must NOT print the value — and the comment in the source says why: naming it invites
        // "just compare against the placeholder", which is the bug that once produced a detector
        // unable to detect its own placeholder. An assertion that only checked for non-emptiness
        // would pass on the version that leaks it.
        let secret = "ZZZZ999999"
        let unusable = HelperClient.Failure.unusableTeamID(secret).description
        XCTAssertFalse(unusable.contains(secret), "the refusal must not print the team ID it rejected")
        XCTAssertTrue(unusable.contains(HelperIdentity.machServiceName), "it must name what it refused to talk to")
        XCTAssertTrue(unusable.contains("bundle-app.sh"), "it must say how to get a build that works")

        // The other two exist to carry a value to the reader, so here the value MUST appear.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
        XCTAssertTrue(HelperClient.Failure.requirementDoesNotParse(requirement).description.contains(requirement))
        XCTAssertTrue(HelperClient.Failure.notRegistered("notFound").description.contains("notFound"))
    }

    func testThePublicInitialiserProducesAFreshConnectionPerCall() {
        // Executes the production factory in `init()`, which every other test in this file replaces
        // with a double — so it had never run. Creating an `NSXPCConnection` performs no IPC; a
        // connection is inert until `resume()`, which this deliberately never calls.
        //
        // **What this does not prove, and who does hold it.** It does not show that `.privileged` was
        // passed — the property that makes the connection reach a root LaunchDaemon rather than a
        // per-user agent of the same name. The option is genuinely unreadable: a reviewer confirmed
        // `value(forKey: "options")` raises `NSUnknownKeyException`, `responds(to:)` is false for
        // every spelling of it, and `class_copyIvarList(NSXPCConnection.self)` has no options ivar.
        //
        // What holds it is `testTheTeamIDMarkerMatchesWhatTheBundleScriptSubstitutes` below, which
        // source-scans for `options: .privileged`. An earlier version of this comment credited
        // `scripts/helper-invariants.sh`, which does NOT check it — that script holds a different
        // property, that no file under `Sources/` outside `HelperClient.swift` constructs such a
        // connection at all. Someone deleting the source-scan on the strength of the wrong
        // attribution would have believed the property still held.
        //
        // **Residual hazard.** This test is safe only while `makeConnection` stays a pure
        // constructor. If configuration or `resume()` is ever moved into the factory, this quietly
        // becomes a test that opens a live, unvalidated privileged connection — and nothing would
        // catch it, because `helper-invariants.sh` does not read `Tests/`.
        let client = HelperClient()
        let first = client.makeConnection(HelperIdentity.machServiceName)
        let second = client.makeConnection(HelperIdentity.machServiceName)
        defer {
            first.invalidate()
            second.invalidate()
        }
        // A factory, not a captured singleton: `connect()` hands the caller a connection it owns, and
        // a shared one would let an invalidation in one place kill an unrelated caller's.
        XCTAssertFalse(first === second, "each call must yield its own connection")
        // `serviceName` IS readable back on a never-resumed connection, unlike `options` — so the
        // factory's argument is checkable, and this catches one that ignored it or hardcoded a
        // per-user agent name.
        XCTAssertEqual(first.serviceName, HelperIdentity.machServiceName)
    }

    func testServiceStatusReportsTheHelperIsNotInstalledRatherThanFailing() {
        // Measured, not assumed. This asserted `.notRegistered` on the strength of the source
        // comment saying so, and the run answered `.notFound` (rawValue 3) — the plist is not
        // discoverable from a test bundle at all, so launchd is never even asked. The source comment
        // was corrected along with this test.
        //
        // The assertion is the pair rather than either one, because which of the two comes back
        // depends on where the caller is running from — an installed .app carries the plist and would
        // answer `.notRegistered`, a `swift test` bundle does not and answers `.notFound`. Both mean
        // "not installed", which is the property this accessor exists to report.
        //
        // It is not a shrug at whatever arrives: `.enabled` and `.requiresApproval` both fail it, and
        // either would be worth investigating, since nothing in this repository can produce a signed
        // daemon for `SMAppService` to register.
        //
        // It is emphatically NOT a check that the helper is unreachable. This accessor reports a
        // plist's registration state relative to `Bundle.main`; a helper installed by any other route
        // — legacy SMJobBless, a pkg dropping into /Library/LaunchDaemons — is fully reachable while
        // this still answers `.notFound`. Reading a pass here as "no helper is listening" would be
        // exactly the confusion the source comment on `serviceStatus()` warns against.
        let status = HelperClient().serviceStatus()
        XCTAssertTrue(
            status == .notFound || status == .notRegistered,
            "expected a not-installed status, got \(status)")
    }

}
