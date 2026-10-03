/// The Overview's three cards (spec 2026-10-03 §6.2): Temporary (delete), Temporary (park), Permanent (run externally),
/// each read from `SavingsSummary` and never re-derived by the view. Decided here so a test says which field feeds which
/// card.
public struct OverviewCards: Sendable, Equatable {
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
    }

    /// The card order on the Overview.
    public static let buckets: [SavingsBucket] = [.deleteAndRegenerate, .parkExternally, .runFromExternal]

    public let cards: [Card]
    /// `SavingsSummary.reclaimableBytes`: the union of the three, each byte once — the alternatives note's total.
    public let reclaimableBytes: UInt64
    public let verifiedReclaimableBytes: UInt64
    /// Every amount is "at least" rather than "up to": something counted could not be fully read.
    public let isLowerBound: Bool

    public static func make(savings s: SavingsSummary) -> OverviewCards {
        let cards = buckets.map { bucket in
            let totals = s[bucket]
            let lossy = bucket == .deleteAndRegenerate && s.deleteLosesUserDataBytes > 0 ? s.deleteLosesUserDataBytes : nil
            return Card(
                bucket: bucket, isPermanent: bucket == .runFromExternal, bytes: totals.optionBytes, verifiedBytes: totals.verifiedOptionBytes,
                losesUserDataBytes: lossy)
        }
        return OverviewCards(
            cards: cards, reclaimableBytes: s.reclaimableBytes, verifiedReclaimableBytes: s.verifiedReclaimableBytes, isLowerBound: s.isLowerBound)
    }
}
