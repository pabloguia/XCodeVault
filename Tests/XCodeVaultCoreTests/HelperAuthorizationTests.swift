import XCTest

@testable import XCodeVaultHelperCore

/// The authorization gate on the root daemon's three state-changing verbs.
///
/// These exist because the first version of `isAdministrator` shipped with a defect that no test
/// could reach: it lived in an executable target. The defect was a retry loop that could never run,
/// and its effect was to deny every administrator with more than 64 group memberships. That is the
/// whole argument for `XCodeVaultHelperCore` being a library.
final class HelperAuthorizationTests: XCTestCase {
    private let adminGID: Int32 = 80

    private func decide(
        uid: uid_t, name: String = "someone", primaryGID: Int32 = 20, memberships: [Int32]? = [20],
        admin: Int32? = 80
    ) -> Bool {
        HelperService.isAdministrator(
            uid: uid,
            passwd: { _ in (name: name, gid: primaryGID) },
            adminGroup: { admin },
            groups: { _, _ in memberships })
    }

    func testAnAdminByGroupMembershipIsAllowed() {
        XCTAssertTrue(decide(uid: 501, memberships: [20, 12, 80, 701]))
    }

    func testAnAdminByPrimaryGroupIsAllowed() {
        XCTAssertTrue(decide(uid: 501, primaryGID: adminGID, memberships: []))
    }

    func testAnOrdinaryUserIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: [20, 12, 701]))
    }

    /// The whole point of the gate: a signed client satisfying the code-signing requirement is not
    /// an authorization, and a service account driving it must not reach a verb that deletes as root.
    func testAServiceAccountIsRefused() {
        XCTAssertFalse(decide(uid: 200, primaryGID: 200, memberships: [200]))
    }

    func testRootIsAllowedWithoutConsultingTheDirectory() {
        // Fails the lookups deliberately: root must not depend on them.
        XCTAssertTrue(
            HelperService.isAdministrator(uid: 0, passwd: { _ in nil }, adminGroup: { nil }, groups: { _, _ in nil }))
    }

    // MARK: fails closed

    func testAnUnresolvableAccountIsRefused() {
        XCTAssertFalse(
            HelperService.isAdministrator(uid: 501, passwd: { _ in nil }, adminGroup: { self.adminGID }, groups: { _, _ in [80] }))
    }

    func testAnUnresolvableAdminGroupIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: [80], admin: nil))
    }

    /// "I could not read the group list" must not be reachable from "allowed". This is the path the
    /// real `groupList` takes when it gives up, and it is the one a directory outage produces.
    func testAnUnreadableGroupListIsRefused() {
        XCTAssertFalse(decide(uid: 501, memberships: nil))
    }

    // MARK: the real lookups, against this machine

    /// `getgrouplist` on Darwin sets `*ngroups` to the *truncated* count on overflow, not the needed
    /// size — the opposite of the contract the first implementation assumed. This pins the observable
    /// consequence: the real lookup returns the account's full membership rather than giving up.
    func testTheRealGroupListReturnsTheFullMembership() throws {
        let uid = getuid()
        let pw = try XCTUnwrap(HelperService.passwdLookup(uid))
        let groups = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid), "could not read this account's groups")
        XCTAssertFalse(groups.isEmpty)
        // `id -G` is the same question asked of the system.
        let expected = Set(Self.idG())
        XCTAssertFalse(expected.isEmpty, "could not read `id -G`")
        XCTAssertTrue(expected.isSubset(of: Set(groups)), "groupList returned fewer groups than `id -G`: \(groups) vs \(expected)")
    }

    /// And the decision itself, end to end on this machine, checked against `id -Gn`.
    func testTheRealDecisionAgreesWithTheSystem() throws {
        let uid = getuid()
        guard let admin = HelperService.adminGroupID() else { throw XCTSkip("no admin group on this machine") }
        let inAdmin = Set(Self.idG()).contains(admin)
        XCTAssertEqual(HelperService.isAdministrator(uid: uid), inAdmin)
    }

    /// The growth path, driven on a machine that has far fewer than 64 groups — which is every
    /// machine, and every CI runner. Without this seam the retry is never executed, and "a retry
    /// that can never run" is precisely the defect this function was rewritten to fix. A test that
    /// only ever exercises the first iteration would not have caught it either.
    func testTheGroupListRetryActuallyRuns() throws {
        let uid = getuid()
        let pw = try XCTUnwrap(HelperService.passwdLookup(uid))
        let full = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid))
        XCTAssertGreaterThan(full.count, 1, "this account has too few groups for the test to mean anything")
        // seedCapacity 1 guarantees at least one overflow-and-grow cycle.
        let viaRetry = try XCTUnwrap(HelperService.groupList(pw.name, pw.gid, seedCapacity: 1), "the retry gave up")
        XCTAssertEqual(viaRetry, full)
    }

    private static func idG() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        p.arguments = ["-G"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
}
