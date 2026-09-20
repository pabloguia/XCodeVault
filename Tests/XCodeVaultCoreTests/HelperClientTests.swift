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
}
