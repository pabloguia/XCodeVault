import XCTest

@testable import XCodeVaultCore

/// Which `SavingsSummary` field feeds which Overview card (S4 Task 3). Every field gets a distinct value, so a card
/// reading the wrong one fails.
final class OverviewCardsTests: XCTestCase {
    private var savings: SavingsSummary {
        var s = SavingsSummary()
        s.deleteAndRegenerate.optionBytes = 101
        s.deleteAndRegenerate.verifiedOptionBytes = 102
        s.deleteAndRegenerate.primaryBytes = 103
        s.parkExternally.optionBytes = 201
        s.parkExternally.verifiedOptionBytes = 202
        s.parkExternally.primaryBytes = 203
        s.runFromExternal.optionBytes = 301
        s.runFromExternal.verifiedOptionBytes = 302
        s.runFromExternal.primaryBytes = 303
        s.keepLocal.optionBytes = 401
        s.temporaryBytes = 501
        s.verifiedTemporaryBytes = 502
        s.permanentBytes = 601
        s.verifiedPermanentBytes = 602
        s.reclaimableBytes = 701
        s.verifiedReclaimableBytes = 702
        s.deleteLosesUserDataBytes = 801
        return s
    }

    func testThreeCardsInOrderTwoTemporaryOnePermanent() {
        let cards = OverviewCards.make(savings: savings).cards
        XCTAssertEqual(cards.map(\.bucket), [.deleteAndRegenerate, .parkExternally, .runFromExternal])
        XCTAssertEqual(cards.map(\.isPermanent), [false, false, true])
        XCTAssertEqual(OverviewCards.buckets, cards.map(\.bucket))
    }

    func testEachCardReadsItsBucketsOptionAndVerifiedBytes() {
        let cards = OverviewCards.make(savings: savings).cards
        XCTAssertEqual(cards.map(\.bytes), [101, 201, 301], "optionBytes, never primaryBytes or a union")
        XCTAssertEqual(cards.map(\.verifiedBytes), [102, 202, 302])
    }

    func testOnlyTheDeleteCardSaysWhatDoesNotComeBack() {
        let cards = OverviewCards.make(savings: savings).cards
        XCTAssertEqual(cards.map(\.losesUserDataBytes), [801, nil, nil])
        var none = savings
        none.deleteLosesUserDataBytes = 0
        XCTAssertNil(OverviewCards.make(savings: none).cards[0].losesUserDataBytes, "no line when nothing is lost")
    }

    func testTheAlternativesNoteTotalIsTheUnion() {
        let overview = OverviewCards.make(savings: savings)
        XCTAssertEqual(overview.reclaimableBytes, 701)
        XCTAssertEqual(overview.verifiedReclaimableBytes, 702)
        XCTAssertFalse(overview.isLowerBound)
    }

    func testALowerBoundCarriesThrough() {
        var s = savings
        s.isLowerBound = true
        XCTAssertTrue(OverviewCards.make(savings: s).isLowerBound)
    }

    func testAnEmptySummaryGivesThreeZeroCards() {
        let overview = OverviewCards.make(savings: SavingsSummary())
        XCTAssertEqual(overview.cards.count, 3)
        XCTAssertEqual(overview.cards.map(\.bytes), [0, 0, 0])
        XCTAssertEqual(overview.reclaimableBytes, 0)
    }

    // MARK: - What each card says (review I1): decided here, not in the view

    private func card(bytes: UInt64, verified: UInt64, lowerBound: Bool = false) -> OverviewCards.Card {
        var s = SavingsSummary()
        s.parkExternally.optionBytes = bytes
        s.parkExternally.verifiedOptionBytes = verified
        s.isLowerBound = lowerBound
        return OverviewCards.make(savings: s).cards[1]
    }

    func testAZeroCardSaysNothingFound() {
        let c = card(bytes: 0, verified: 0)
        XCTAssertEqual(c.amount, .none)
        XCTAssertEqual(c.verified, .none)
    }

    func testALowerBoundSaysAtLeastEvenAtZero() {
        XCTAssertEqual(card(bytes: 0, verified: 0, lowerBound: true).amount, .atLeast(0))
        XCTAssertEqual(card(bytes: 0, verified: 0, lowerBound: true).verified, .none)
        XCTAssertEqual(card(bytes: 500, verified: 200, lowerBound: true).amount, .atLeast(500))
        XCTAssertEqual(card(bytes: 500, verified: 200).amount, .upTo(500))
    }

    func testAFullyVerifiedCardDropsTheShare() {
        XCTAssertEqual(card(bytes: 500, verified: 500).verified, .all)
    }

    func testAPartlyVerifiedCardShowsItsShare() {
        XCTAssertEqual(card(bytes: 500, verified: 200).verified, .share(200))
        XCTAssertEqual(card(bytes: 500, verified: 0).verified, .share(0))
    }

    func testTheTotalIsAHeadlineNeverNothing() {
        XCTAssertEqual(OverviewCards.make(savings: SavingsSummary()).total, .upTo(0))
        XCTAssertEqual(OverviewCards.make(savings: savings).total, .upTo(701))
        var s = savings
        s.isLowerBound = true
        XCTAssertEqual(OverviewCards.make(savings: s).total, .atLeast(701))
    }
}
