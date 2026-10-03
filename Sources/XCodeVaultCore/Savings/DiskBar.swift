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
        let buckets = DiskBar.bucketOrder.map { Segment(kind: .bucket($0), bytes: savings[$0].primaryBytes) }
        let accounted = buckets.reduce(host.dataVolumeFreeBytes) { sum, s in
            let (value, overflow) = sum.addingReportingOverflow(s.bytes)
            return overflow ? .max : value
        }
        let total = host.dataVolumeTotalBytes
        let other = Segment(kind: .otherData, bytes: total > accounted ? total - accounted : 0)
        segments = ([other] + buckets + [Segment(kind: .free, bytes: host.dataVolumeFreeBytes)]).filter { $0.bytes > 0 }
        isClamped = accounted > total
    }

    public static func segments(host: HostEnvironment, savings: SavingsSummary) -> [Segment] {
        DiskBar(host: host, savings: savings).segments
    }
}
