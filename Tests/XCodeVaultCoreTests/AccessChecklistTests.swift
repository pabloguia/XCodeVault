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
        for state in [HelperState.notInstalled, .awaitingApproval] {
            let b = banner(.granted, state)
            XCTAssertEqual(b?.need, .privilegedHelper, "\(state)")
            XCTAssertEqual(b?.blocksBytes, 3500, "\(state)")
        }
        XCTAssertNil(banner(.granted, .enabled))
    }

    /// Final review M6: a build that can never reach the helper does not nag from the Overview, but the blocker is not
    /// hidden — the Access row and the Delete view's row still carry it, with its bytes and what to do instead.
    func testABuildWithoutTheHelperKeepsItsRowOffTheOverviewOnly() {
        XCTAssertNil(banner(.granted, .unavailableInThisBuild))
        XCTAssertEqual(banner(.notGranted, .unavailableInThisBuild, refusals: 1)?.need, .fullDiskAccess, "Full Disk Access still banners")
        let access = rows(.granted, .unavailableInThisBuild)[1]
        XCTAssertEqual(access.blocksBytes, 3500)
        XCTAssertEqual(access.actionKey, AccessChecklist.Key.helperActionSignedReleaseOrCLI)
        XCTAssertEqual(AccessChecklist.deleteRow(helper: .unavailableInThisBuild, list: deleteList(rootBytes: [3000, 500]))?.blocksBytes, 3500)
    }

    func testAtMostOneBannerAndFullDiskAccessComesFirst() {
        XCTAssertEqual(banner(.notGranted, .notInstalled, refusals: 1)?.need, .fullDiskAccess)
    }

    /// The Overview shows the first blocking row only: with both needs holding something back, the helper's row is not it.
    func testTheBannerIsOnlyTheFirstBlockingRow() {
        let all = rows(.notGranted, .notInstalled, refusals: 1)
        let b = banner(.notGranted, .notInstalled, refusals: 1)
        XCTAssertEqual(b, all[0])
        XCTAssertNotNil(all[1].blocksBytes, "the helper holds bytes back too")
        XCTAssertEqual(banner(.granted, .notInstalled, refusals: 1), all[1], "with Full Disk Access granted, the helper's turn")
    }

    // MARK: - Titles and status words (S4 Task 5)

    func testEveryRowHasItsTitleAndAStatusWordPerState() {
        var statuses: [AccessChecklist.Need: Set<String>] = [:]
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for r in rows(fda, helper) {
                    XCTAssertTrue(AccessChecklist.allKeys.contains(r.titleKey), r.titleKey)
                    XCTAssertTrue(AccessChecklist.allKeys.contains(r.statusKey), r.statusKey)
                    statuses[r.need, default: []].insert(r.statusKey)
                }
            }
        }
        XCTAssertEqual(rows(.granted, .enabled).map(\.titleKey), ["perm.fda.title", "perm.helper.title"])
        // One word per state the need can be in: FDA granted / missing / unknown; the helper's four.
        XCTAssertEqual(statuses[.fullDiskAccess]?.count, FullDiskAccessState.allCases.count)
        XCTAssertEqual(statuses[.privilegedHelper]?.count, HelperState.allCases.count)
        XCTAssertEqual(rows(.granted, .unavailableInThisBuild)[1].statusKey, "app.access.status.helper.unavailable")
        XCTAssertEqual(rows(.unknown, .enabled)[0].statusKey, "app.access.status.fda.unknown")
    }

    // MARK: - The Delete view's contextual row (S4 Task 5)

    private func deleteList(rootBytes: [UInt64]) -> DeleteList {
        func action(_ path: String, _ bytes: UInt64, root: Bool) -> CleanAction {
            CleanAction(
                categoryID: root ? "coreSimulatorSystemCaches" : "derivedData", categoryName: "c", path: path, bytes: bytes, isExperimental: true,
                risk: .low, requiresRoot: root, notes: [])
        }
        var groups = [DeleteList.Group(categoryID: "derivedData", categoryName: "DerivedData", actions: [action("/d", 9000, root: false)], undo: .regenerable)]
        if !rootBytes.isEmpty {
            let actions = rootBytes.enumerated().map { action("/r\($0.offset)", $0.element, root: true) }
            groups.append(DeleteList.Group(categoryID: "coreSimulatorSystemCaches", categoryName: "dyld", actions: actions, undo: .regenerable))
        }
        return DeleteList(groups: groups, otherTools: [])
    }

    func testDeleteShowsTheHelperRowWhenARootRowIsListedAndTheHelperIsNotEnabled() {
        let list = deleteList(rootBytes: [3000, 500])
        for state in [HelperState.notInstalled, .awaitingApproval, .unavailableInThisBuild] {
            let r = AccessChecklist.deleteRow(helper: state, list: list)
            XCTAssertEqual(r?.need, .privilegedHelper, "\(state)")
            XCTAssertEqual(r?.blocksBytes, 3500, "the listed root rows' bytes: \(state)")
            XCTAssertEqual(r?.whyKey, AccessChecklist.Key.helperWhyRootOnlyBytes)
            // The same row the checklist has for that state, but for its bytes.
            XCTAssertEqual(r?.action, rows(.granted, state)[1].action, "\(state)")
            XCTAssertEqual(r?.actionKey, rows(.granted, state)[1].actionKey, "\(state)")
        }
        XCTAssertEqual(AccessChecklist.deleteRow(helper: .unavailableInThisBuild, list: list)?.action, .guidanceOnly)
    }

    func testDeleteHidesTheHelperRowWhenEnabledOrWhenNothingNeedsRoot() {
        XCTAssertNil(AccessChecklist.deleteRow(helper: .enabled, list: deleteList(rootBytes: [3000])))
        for state in HelperState.allCases {
            XCTAssertNil(AccessChecklist.deleteRow(helper: state, list: deleteList(rootBytes: [])), "\(state)")
        }
        // A root row of zero bytes still needs the helper; the sentence is then the general one.
        XCTAssertEqual(AccessChecklist.deleteRow(helper: .notInstalled, list: deleteList(rootBytes: [0]))?.whyKey, AccessChecklist.Key.helperWhyRootActions)
    }

    /// Final review M1: with a Delete list, the Access row and the banner take their root-only bytes from it, so every
    /// screen says the same number even where the plan's `rootOnly` rows count something else.
    func testTheDeleteListIsTheOneSourceOfRootOnlyBytes() {
        let list = deleteList(rootBytes: [1200])
        var s = SavingsSummary()
        s.isLowerBound = false
        for state in [HelperState.notInstalled, .awaitingApproval, .unavailableInThisBuild] {
            let access = AccessChecklist.rows(fullDiskAccess: .granted, helper: state, savings: s, plan: plan, deleteList: list)[1]
            XCTAssertEqual(access.blocksBytes, 1200, "not the plan's 3500: \(state)")
            XCTAssertEqual(access.blocksBytes, AccessChecklist.deleteRow(helper: state, list: list)?.blocksBytes, "\(state)")
        }
        XCTAssertEqual(AccessChecklist.banner(fullDiskAccess: .granted, helper: .notInstalled, savings: s, plan: plan, deleteList: list)?.blocksBytes, 1200)
        XCTAssertEqual(AccessChecklist.rootOnlyBytes(plan: plan, list: nil), 3500, "no list: the plan's rootOnly delete rows")
        XCTAssertEqual(AccessChecklist.rootOnlyBytes(plan: plan, list: deleteList(rootBytes: [])), 0)
    }
}
