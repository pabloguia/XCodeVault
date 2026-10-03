import Foundation

/// One bucket's bytes, three ways (spec 2026-10-03 §3.3).
public struct SavingsBucketTotals: Sendable, Codable, Equatable {
    /// Bytes for which this bucket is *an* option. Not additive across buckets: DerivedData is in two.
    public var optionBytes: UInt64 = 0
    /// Bytes counted once, under the category's most durable option. Additive across buckets.
    public var primaryBytes: UInt64 = 0
    /// The part of `optionBytes` whose category is not experimental (rule 10).
    public var verifiedOptionBytes: UInt64 = 0
    public init() {}
}

/// What the user can reclaim from the boot volume, temporarily and permanently. Every headline is an
/// "up to": the options are alternatives for the same bytes, and the unions count each byte once.
public struct SavingsSummary: Sendable, Codable, Equatable {
    public var runFromExternal = SavingsBucketTotals()
    public var parkExternally = SavingsBucketTotals()
    public var deleteAndRegenerate = SavingsBucketTotals()
    /// Its `verifiedOptionBytes` equals its `optionBytes`; there is nothing to verify about keeping data.
    public var keepLocal = SavingsBucketTotals()
    /// Bytes that can be freed for a while: deleted (grows back) or parked (until brought back). A union.
    public var temporaryBytes: UInt64 = 0
    public var verifiedTemporaryBytes: UInt64 = 0
    /// Bytes with any saving option at all — temporary or permanent. A union.
    public var reclaimableBytes: UInt64 = 0
    public var verifiedReclaimableBytes: UInt64 = 0
    /// Bytes with a permanent option that applies to data already on disk. A union.
    public var permanentBytes: UInt64 = 0
    public var verifiedPermanentBytes: UInt64 = 0
    /// Some counted item could not be fully read: every number above is "at least". Boot-volume items only,
    /// unlike `ScanSummary.lowerBound`, because only those are savings.
    public var isLowerBound = false

    public init() {}

    public subscript(bucket: SavingsBucket) -> SavingsBucketTotals {
        switch bucket {
        case .runFromExternal: runFromExternal
        case .parkExternally: parkExternally
        case .deleteAndRegenerate: deleteAndRegenerate
        case .keepLocal: keepLocal
        }
    }

    fileprivate mutating func add(_ bytes: UInt64, to bucket: SavingsBucket, primary: Bool, verified: Bool) {
        func bump(_ t: inout SavingsBucketTotals) {
            t.optionBytes += bytes
            if primary { t.primaryBytes += bytes }
            if verified { t.verifiedOptionBytes += bytes }
        }
        switch bucket {
        case .runFromExternal: bump(&runFromExternal)
        case .parkExternally: bump(&parkExternally)
        case .deleteAndRegenerate: bump(&deleteAndRegenerate)
        case .keepLocal: bump(&keepLocal)
        }
    }
}

public enum SavingsCalculator {
    /// The items a saving is counted from, with their category: existing, not a symlink, on the boot volume, of a
    /// known category that is not a breakdown. Shared with `SavingsPlanner`, so a plan row can never count a
    /// byte the summary does not.
    static func countedItems(_ items: [StorageItem], category: (String) -> StorageCategory?) -> [(item: StorageItem, category: StorageCategory)] {
        items.compactMap { item in
            guard item.exists, !item.isSymlink, item.onBootVolume, let c = category(item.categoryID), c.isBreakdownOf == nil else { return nil }
            return (item, c)
        }
    }

    /// Counts the same items `Scanner.summarize` counts for the boot-volume total — existing, not a symlink,
    /// not a breakdown — restricted to the boot volume, because only bytes there are a saving. An item whose
    /// category is unknown is skipped rather than guessed into `.keepLocal`.
    public static func summarize(items: [StorageItem], category: (String) -> StorageCategory?) -> SavingsSummary {
        var s = SavingsSummary()
        for (item, c) in countedItems(items, category: category) {
            let bytes = item.allocatedBytes
            if item.usage?.isLowerBound == true { s.isLowerBound = true }
            let options = c.savingsOptionDetails.filter(\.appliesToExistingData)
            for option in options {
                s.add(bytes, to: option.bucket, primary: option.bucket == c.primaryBucket, verified: !option.isExperimental)
            }
            func union(_ buckets: Set<SavingsBucket>, _ total: inout UInt64, _ verified: inout UInt64) {
                let matching = options.filter { buckets.contains($0.bucket) }
                guard !matching.isEmpty else { return }
                total += bytes
                if matching.contains(where: { !$0.isExperimental }) { verified += bytes }
            }
            union([.deleteAndRegenerate, .parkExternally], &s.temporaryBytes, &s.verifiedTemporaryBytes)
            union([.runFromExternal], &s.permanentBytes, &s.verifiedPermanentBytes)
            union([.runFromExternal, .parkExternally, .deleteAndRegenerate], &s.reclaimableBytes, &s.verifiedReclaimableBytes)
        }
        return s
    }
}
