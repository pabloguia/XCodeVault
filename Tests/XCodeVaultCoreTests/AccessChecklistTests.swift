import XCTest

@testable import XCodeVaultCore

final class AccessChecklistTests: XCTestCase {
    private func row(_ id: String, _ bytes: UInt64, bucket: SavingsBucket = .deleteAndRegenerate, notes: [String] = []) -> SavingsPlanRow {
        SavingsPlanRow(
            categoryID: id, categoryName: id, bytes: bytes,
            option: SavingsOption(bucket: bucket, isExperimental: false, appliesToExistingData: true, losesUserData: false),
            command: "xcodevaultctl clean --category \(id)", itemCount: 1, actsImmediately: false, noteIDs: notes)
    }

    private var plan: [SavingsPlanRow] {
        [
            row("dyldCacheA", 3000, notes: ["rootOnly"]), row("dyldCacheB", 500, notes: ["rootOnly"]), row("derivedData", 9000),
            // Not a delete row: never counted towards the helper, whatever its notes say.
            row("strayPark", 7, bucket: .parkExternally, notes: ["rootOnly"]),
        ]
    }

    private func rows(
        _ fda: FullDiskAccessState, _ helper: HelperState, lowerBound: Bool = false, refusals: Int = 0, plan: [SavingsPlanRow]? = nil
    ) -> [AccessChecklist.Row] {
        var s = SavingsSummary()
        s.isLowerBound = lowerBound
        return AccessChecklist.rows(fullDiskAccess: fda, helper: helper, savings: s, plan: plan ?? self.plan, privacyRefusalCount: refusals)
    }

    func testOneRowPerNeedInFixedOrder() {
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                XCTAssertEqual(rows(fda, helper).map(\.need), [.fullDiskAccess, .privilegedHelper], "\(fda) \(helper)")
            }
        }
    }

    func testFullDiskAccessGranted() {
        let r = rows(.granted, .enabled, lowerBound: true, refusals: 3)[0]
        XCTAssertEqual(r.state, .granted)
        XCTAssertEqual(r.whyKey, "app.access.fda.why.granted")
        XCTAssertNil(r.actionKey)
        XCTAssertNil(r.action)
        XCTAssertNil(r.blocksBytes)
        XCTAssertNil(r.blocksFolders)
    }

    func testFullDiskAccessMissingCountsTheFoldersItCannotRead() {
        let r = rows(.notGranted, .enabled, lowerBound: true, refusals: 3)[0]
        XCTAssertEqual(r.state, .missing)
        XCTAssertEqual(r.whyKey, "app.access.fda.why.unreadableFolders")
        XCTAssertEqual(r.blocksFolders, 3)
        XCTAssertNil(r.blocksBytes, "unread bytes are unmeasurable")
        XCTAssertEqual(r.actionKey, "app.access.fda.action.openSettings")
        XCTAssertEqual(r.action, .openFullDiskAccessSettings)
    }

    func testFullDiskAccessMissingWithALowerBoundButNoRefusalCount() {
        let r = rows(.notGranted, .enabled, lowerBound: true)[0]
        XCTAssertEqual(r.whyKey, "app.access.fda.why.unreadable")
        XCTAssertNil(r.blocksFolders)
        XCTAssertEqual(r.action, .openFullDiskAccessSettings)
    }

    func testFullDiskAccessMissingWithNothingUnread() {
        let r = rows(.notGranted, .enabled)[0]
        XCTAssertEqual(r.whyKey, "app.access.fda.why.protected")
        XCTAssertNil(r.blocksFolders)
        XCTAssertEqual(r.actionKey, "app.access.fda.action.openSettings")
    }

    func testFullDiskAccessUnknownNeverPromptsForSettings() {
        // ADR-0007: "could not tell" is not "missing"; the row offers a re-check, not the Settings pane.
        let r = rows(.unknown, .enabled, lowerBound: true, refusals: 2)[0]
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.whyKey, "app.access.fda.why.unknown")
        XCTAssertEqual(r.actionKey, "app.access.fda.action.recheck")
        XCTAssertEqual(r.action, .recheckFullDiskAccess)
        XCTAssertNil(r.blocksFolders)
    }

    func testHelperEnabled() {
        let r = rows(.granted, .enabled)[1]
        XCTAssertEqual(r.state, .granted)
        XCTAssertEqual(r.whyKey, "app.access.helper.why.enabled")
        XCTAssertNil(r.actionKey)
        XCTAssertNil(r.action)
        XCTAssertNil(r.blocksBytes)
    }

    func testHelperNotInstalledNamesTheRootOnlyBytes() {
        let r = rows(.granted, .notInstalled)[1]
        XCTAssertEqual(r.state, .missing)
        XCTAssertEqual(r.whyKey, "app.access.helper.why.rootOnlyBytes")
        XCTAssertEqual(r.blocksBytes, 3500)
        XCTAssertEqual(r.actionKey, "app.access.helper.action.install")
        XCTAssertEqual(r.action, .installHelper)
    }

    func testHelperAwaitingApproval() {
        let r = rows(.granted, .awaitingApproval)[1]
        XCTAssertEqual(r.state, .awaitingApproval)
        XCTAssertEqual(r.whyKey, "app.access.helper.why.rootOnlyBytes")
        XCTAssertEqual(r.blocksBytes, 3500)
        XCTAssertEqual(r.actionKey, "app.access.helper.action.approve")
        XCTAssertEqual(r.action, .installHelper)
    }

    func testHelperUnavailableInThisBuildSaysWhatToDoInstead() {
        let r = rows(.granted, .unavailableInThisBuild)[1]
        XCTAssertEqual(r.state, .unavailableInThisBuild)
        XCTAssertEqual(r.whyKey, "app.access.helper.why.rootOnlyBytes")
        XCTAssertEqual(r.blocksBytes, 3500)
        // §6.3: never a bare "not available": the key is the CLI / signed-release guidance, and it is text, not a button.
        XCTAssertEqual(r.actionKey, "app.access.helper.action.signedReleaseOrCLI")
        XCTAssertEqual(r.action, .guidanceOnly)
    }

    func testHelperWithNoRootOnlyBytesUsesTheGeneralReason() {
        for helper: HelperState in [.notInstalled, .awaitingApproval, .unavailableInThisBuild] {
            let r = rows(.granted, helper, plan: [row("derivedData", 9000), row("dyldCacheA", 0, notes: ["rootOnly"])])[1]
            XCTAssertEqual(r.whyKey, "app.access.helper.why.rootActions", "\(helper)")
            XCTAssertNil(r.blocksBytes, "\(helper)")
        }
    }

    func testEveryKeyIsAnAccessKey() {
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for lowerBound in [false, true] {
                    for r in rows(fda, helper, lowerBound: lowerBound, refusals: lowerBound ? 1 : 0) {
                        XCTAssertTrue(r.whyKey.hasPrefix("app.access."))
                        XCTAssertTrue(r.actionKey?.hasPrefix("app.access.") ?? true)
                        XCTAssertTrue(AccessChecklist.allKeys.contains(r.whyKey), r.whyKey)
                        if let a = r.actionKey { XCTAssertTrue(AccessChecklist.allKeys.contains(a), a) }
                        XCTAssertEqual(r.actionKey == nil, r.action == nil)
                    }
                }
            }
        }
    }

    func testDefaultsToNoRefusals() {
        let r = AccessChecklist.rows(fullDiskAccess: .notGranted, helper: .enabled, savings: SavingsSummary(), plan: [])
        XCTAssertEqual(r[0].whyKey, "app.access.fda.why.protected")
    }

    // MARK: - The Overview's one banner (S4 Task 3)

    private func banner(
        _ fda: FullDiskAccessState, _ helper: HelperState, lowerBound: Bool = false, refusals: Int = 0, plan: [SavingsPlanRow]? = nil
    ) -> AccessChecklist.Row? {
        var s = SavingsSummary()
        s.isLowerBound = lowerBound
        return AccessChecklist.banner(fullDiskAccess: fda, helper: helper, savings: s, plan: plan ?? self.plan, privacyRefusalCount: refusals)
    }

    func testNoBannerWhenNothingIsHeldBack() {
        XCTAssertNil(banner(.granted, .enabled))
        // Missing, but nothing measured is held back by it: no banner, the Access view still lists the row.
        XCTAssertNil(banner(.notGranted, .notInstalled, plan: [row("derivedData", 9000)]))
        XCTAssertNil(banner(.unknown, .unavailableInThisBuild, plan: []))
    }

    func testFullDiskAccessBlocksWhenFoldersWereRefusedOrSizesAreALowerBound() {
        XCTAssertEqual(banner(.notGranted, .enabled, refusals: 2)?.need, .fullDiskAccess)
        XCTAssertEqual(banner(.notGranted, .enabled, lowerBound: true)?.need, .fullDiskAccess)
        XCTAssertEqual(banner(.unknown, .enabled, refusals: 2)?.action, .recheckFullDiskAccess, "unknown re-checks, never sends to Settings")
        XCTAssertNil(banner(.granted, .enabled, lowerBound: true, refusals: 2), "granted is never a banner")
    }

    func testTheHelperBlocksOnlyWithRootOnlyBytes() {
        for state in [HelperState.notInstalled, .awaitingApproval, .unavailableInThisBuild] {
            let b = banner(.granted, state)
            XCTAssertEqual(b?.need, .privilegedHelper, "\(state)")
            XCTAssertEqual(b?.blocksBytes, 3500, "\(state)")
        }
        XCTAssertNil(banner(.granted, .enabled))
    }

    func testAtMostOneBannerAndFullDiskAccessComesFirst() {
        XCTAssertEqual(banner(.notGranted, .notInstalled, refusals: 1)?.need, .fullDiskAccess)
    }
}
