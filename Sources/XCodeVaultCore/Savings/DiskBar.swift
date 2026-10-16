/// The Overview's horizontal bar of the internal disk (spec 2026-10-03 §6.2): other data, the developer data split by
/// primary bucket, then free space. Decided here so the view only draws it.
///
/// Developer data is `SavingsBucketTotals.primaryBytes`, the one additive measure: `optionBytes` counts DerivedData in
/// two buckets and would overfill the bar.
public struct DiskBar: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        /// Everything on the volume that is neither counted developer data nor free.
        case otherData
        case bucket(SavingsBucket)
        case free
    }

    public struct Segment: Sendable, Equatable {
        public let kind: Kind
        public let bytes: UInt64
    }

    /// The bucket order on the bar: most durable saving first, keeping last (the order of `SavingsBucket`).
    public static let bucketOrder: [SavingsBucket] = [.runFromExternal, .parkExternally, .deleteAndRegenerate, .keepLocal]

    /// Non-empty segments in order: other data, the buckets in `bucketOrder`, free.
    public let segments: [Segment]
    /// Free space plus developer data exceeded the volume's size, so other data was clamped to 0 and the segments do not
    /// sum to `dataVolumeTotalBytes` (a measurement taken at different moments, or a volume that could not be measured).
    public let isClamped: Bool

    public init(host: HostEnvironment, savings: SavingsSummary) {
        self.init(
            totalBytes: host.dataVolumeTotalBytes, freeBytes: host.dataVolumeFreeBytes,
            bucketBytes: Dictionary(uniqueKeysWithValues: DiskBar.bucketOrder.map { ($0, savings[$0].primaryBytes) }))
    }

    /// Any volume's bar (R2: the Drives screen draws one per drive): `totalBytes` split into other data, `bucketBytes` in
    /// `bucketOrder`, and `freeBytes`.
    public init(totalBytes total: UInt64, freeBytes: UInt64, bucketBytes: [SavingsBucket: UInt64]) {
        let buckets = DiskBar.bucketOrder.map { Segment(kind: .bucket($0), bytes: bucketBytes[$0] ?? 0) }
        let accounted = buckets.reduce(freeBytes) { sum, s in
            let (value, overflow) = sum.addingReportingOverflow(s.bytes)
            return overflow ? .max : value
        }
        let other = Segment(kind: .otherData, bytes: total > accounted ? total - accounted : 0)
        segments = ([other] + buckets + [Segment(kind: .free, bytes: freeBytes)]).filter { $0.bytes > 0 }
        isClamped = accounted > total
    }

    /// The legend's order: the buckets as the Overview's cards list them (delete, park, run externally), then keeping,
    /// other data and free — so a legend item sits in the same order as the card with its title. The bar keeps
    /// `bucketOrder`.
    public static let legendOrder: [Kind] = OverviewCards.buckets.map { .bucket($0) } + [.bucket(.keepLocal), .otherData, .free]

    /// The non-empty segments in `legendOrder`.
    public var legend: [Segment] {
        DiskBar.legendOrder.compactMap { kind in segments.first { $0.kind == kind } }
    }

    public static func segments(host: HostEnvironment, savings: SavingsSummary) -> [Segment] {
        DiskBar(host: host, savings: savings).segments
    }
}
