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
    public var keepLocal = SavingsBucketTotals()
    /// Bytes that can be freed for a while: deleted (grows back) or parked (until brought back). A union.
    public var temporaryBytes: UInt64 = 0
    public var verifiedTemporaryBytes: UInt64 = 0
    /// Bytes with any saving option at all — temporary or permanent. A union.
    public var reclaimableBytes: UInt64 = 0
    public var verifiedReclaimableBytes: UInt64 = 0
    /// Some counted item could not be fully read: every number above is "at least".
    public var isLowerBound = false

    public init() {}

    public var permanentBytes: UInt64 { runFromExternal.optionBytes }
    public var verifiedPermanentBytes: UInt64 { runFromExternal.verifiedOptionBytes }

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
    /// Counts the same items `Scanner.summarize` counts for the boot-volume total — existing, not a symlink,
    /// not a breakdown — restricted to the boot volume, because only bytes there are a saving. An item whose
    /// category is unknown is skipped rather than guessed into `.keepLocal`.
    public static func summarize(items: [StorageItem], category: (String) -> StorageCategory?) -> SavingsSummary {
        var s = SavingsSummary()
        for item in items where item.exists && !item.isSymlink && item.onBootVolume {
            guard let c = category(item.categoryID), c.isBreakdownOf == nil else { continue }
            let bytes = item.allocatedBytes
            let verified = !c.isExperimental
            if item.usage?.isLowerBound == true { s.isLowerBound = true }
            let options = c.savingsOptions
            for bucket in options { s.add(bytes, to: bucket, primary: bucket == c.primaryBucket, verified: verified) }
            if options.contains(where: \.isSaving) {
                s.reclaimableBytes += bytes
                if verified { s.verifiedReclaimableBytes += bytes }
            }
            if options.contains(.deleteAndRegenerate) || options.contains(.parkExternally) {
                s.temporaryBytes += bytes
                if verified { s.verifiedTemporaryBytes += bytes }
            }
        }
        return s
    }
}
