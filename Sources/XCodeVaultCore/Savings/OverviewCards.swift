/// The Overview's three cards (spec 2026-10-03 §6.2): Temporary (delete), Temporary (park), Permanent (run externally),
/// each read from `SavingsSummary` and never re-derived by the view. Decided here so a test says which field feeds which
/// card.
public struct OverviewCards: Sendable, Equatable {
    /// How a card states its amount: nothing found, "up to", or "at least" when something counted could not be read.
    public enum Amount: Sendable, Equatable {
        case none
        case upTo(UInt64)
        case atLeast(UInt64)

        /// A headline: never `none` — "up to", or "at least" on a lower bound.
        static func headline(_ bytes: UInt64, lowerBound: Bool) -> Amount { lowerBound ? .atLeast(bytes) : .upTo(bytes) }
    }

    /// How much of a card rests on verified options (rule 10).
    public enum Verified: Sendable, Equatable {
        /// Every byte: no share to show.
        case all
        /// This many bytes are verified; the rest is experimental.
        case share(UInt64)
        /// The card has no bytes: nothing to qualify.
        case none
    }

    public struct Card: Sendable, Equatable {
        public let bucket: SavingsBucket
        /// `false` for the two temporary cards (delete, park), `true` for run externally.
        public let isPermanent: Bool
        /// The bucket's `optionBytes`: the bytes for which it is *an* option. Not additive across cards.
        public let bytes: UInt64
        /// The bucket's `verifiedOptionBytes`, the part that does not rest on an experimental option (rule 10).
        public let verifiedBytes: UInt64
        /// The delete card only: `SavingsSummary.deleteLosesUserDataBytes`, the part that deletes apps' data and does not
        /// come back (simulator devices). Nil on the other cards, and when it is zero.
        public let losesUserDataBytes: UInt64?
        /// `none` when the card has no bytes and nothing was unreadable; "at least" on a lower bound, even at zero.
        public let amount: Amount
        public let verified: Verified
    }

    /// The card order on the Overview.
    public static let buckets: [SavingsBucket] = [.deleteAndRegenerate, .parkExternally, .runFromExternal]

    public let cards: [Card]
    /// `SavingsSummary.reclaimableBytes`: the union of the three, each byte once — the alternatives note's total.
    public let reclaimableBytes: UInt64
    public let verifiedReclaimableBytes: UInt64
    /// Every amount is "at least" rather than "up to": something counted could not be fully read.
    public let isLowerBound: Bool
    /// The alternatives note's total, as a headline.
    public let total: Amount

    public static func make(savings s: SavingsSummary) -> OverviewCards {
        let cards = buckets.map { bucket in
            let totals = s[bucket]
            let lossy = bucket == .deleteAndRegenerate && s.deleteLosesUserDataBytes > 0 ? s.deleteLosesUserDataBytes : nil
            let bytes = totals.optionBytes, verifiedBytes = totals.verifiedOptionBytes
            let amount: Amount = bytes == 0 && !s.isLowerBound ? .none : .headline(bytes, lowerBound: s.isLowerBound)
            let verified: Verified = bytes == 0 ? .none : verifiedBytes >= bytes ? .all : .share(verifiedBytes)
            return Card(
                bucket: bucket, isPermanent: bucket == .runFromExternal, bytes: bytes, verifiedBytes: verifiedBytes, losesUserDataBytes: lossy,
                amount: amount, verified: verified)
        }
        return OverviewCards(
            cards: cards, reclaimableBytes: s.reclaimableBytes, verifiedReclaimableBytes: s.verifiedReclaimableBytes, isLowerBound: s.isLowerBound,
            total: .headline(s.reclaimableBytes, lowerBound: s.isLowerBound))
    }
}
