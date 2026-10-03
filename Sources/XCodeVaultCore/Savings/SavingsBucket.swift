import Foundation

/// What the user can do with a category's bytes, in their terms (spec 2026-10-03 §3.1). Declared in
/// durability order: the first case a category supports is where the dashboard counts its bytes.
public enum SavingsBucket: String, Sendable, Codable, CaseIterable {
    /// Lives on an external drive from now on; stops growing on this Mac. The only permanent saving.
    case runFromExternal
    /// Copied to a vault and removed here; brought back by copying, without downloading.
    case parkExternally
    /// Deleted; Xcode rebuilds it or Apple downloads it again on demand. Grows back as you work.
    case deleteAndRegenerate
    /// Nothing XCodeVault can reclaim safely.
    case keepLocal

    public var isPermanent: Bool { self == .runFromExternal }
    public var isSaving: Bool { self != .keepLocal }
}

/// One thing the user can do with a category's bytes, with the facts a rendering needs (spec §3.4).
public struct SavingsOption: Sendable, Codable, Equatable {
    public let bucket: SavingsBucket
    /// Not verified for this option: the category's evidence is not `.verified`, or the option goes through a
    /// command the CLI labels experimental (`runtime offload`). Rule 10, decided per option.
    public let isExperimental: Bool
    /// False when the option only changes where *new* data goes (Archives' `locations set-archives`): listed,
    /// never counted as a saving of the bytes on disk now.
    public let appliesToExistingData: Bool
    /// Deleting loses data the user made and nothing recreates it by itself (simulator devices and their apps).
    public let losesUserData: Bool
}

extension StorageCategory {
    /// Categories whose park command exists although their strategy is `.appleManaged`: a runtime is
    /// offloaded through the Runtime Library (`runtime offload`). Named rather than inferred, because
    /// nothing in `allowedStrategies` says so; `SavingsOptionsTests` pins that every id here exists.
    static let parkCommandCategoryIDs: Set<String> = ["simulatorRuntimeAssets"]

    /// Derived from the strategies the catalog already records, never stored: a second field could
    /// disagree with `allowedStrategies`, and the disagreement would be a promise the product does not
    /// keep. Most durable first; the first option that applies to existing data is `primaryBucket`.
    /// `[.keepLocal]` when the category offers nothing.
    public var savingsOptions: [SavingsBucket] {
        let strategies = Set(allowedStrategies)
        var options: [SavingsBucket] = []
        // `.symlinkRelocation` and `.canonicalMount` are deliberately absent (rule 7, ADR-0004).
        if !strategies.isDisjoint(with: [.nativeConfiguration, .userDirectoryRelocation, .downloadRepository]) {
            options.append(.runFromExternal)
        }
        if strategies.contains(.coldStorage) || Self.parkCommandCategoryIDs.contains(id) {
            options.append(.parkExternally)
        }
        // Rule 5: whatever the strategies say, non-regenerable data is never offered for deletion.
        if (strategies.contains(.safeCleanup) || cleanupCommand != nil) && regenerability != .nonRegenerable {
            options.append(.deleteAndRegenerate)
        }
        return options.isEmpty ? [.keepLocal] : options
    }

    /// Run-from-external options that only redirect new data. Named, like `parkCommandCategoryIDs`.
    static let newDataOnlyRunFromExternalIDs: Set<String> = ["archives"]

    public var savingsOptionDetails: [SavingsOption] {
        savingsOptions.map { bucket in
            SavingsOption(
                bucket: bucket,
                isExperimental: bucket != .keepLocal
                    && (evidenceStatus != .verified || (bucket == .parkExternally && Self.parkCommandCategoryIDs.contains(id))),
                appliesToExistingData: !(bucket == .runFromExternal && Self.newDataOnlyRunFromExternalIDs.contains(id)),
                losesUserData: bucket == .deleteAndRegenerate && regenerability == .userRecreatable)
        }
    }

    /// Where the dashboard counts this category's bytes: the most durable option that applies to existing data.
    public var primaryBucket: SavingsBucket {
        savingsOptionDetails.first(where: \.appliesToExistingData)?.bucket ?? .keepLocal
    }
}
