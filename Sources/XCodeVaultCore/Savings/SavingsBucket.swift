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

extension StorageCategory {
    /// Categories whose park command exists although their strategy is `.appleManaged`: a runtime is
    /// offloaded through the Runtime Library (`runtime offload`). Named rather than inferred, because
    /// nothing in `allowedStrategies` says so; `SavingsOptionsTests` pins that every id here exists.
    static let parkCommandCategoryIDs: Set<String> = ["simulatorRuntimeAssets"]

    /// Derived from the strategies the catalog already records, never stored: a second field could
    /// disagree with `allowedStrategies`, and the disagreement would be a promise the product does not
    /// keep. Most durable first; `[.keepLocal]` when the category offers nothing.
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

    /// Where the dashboard counts this category's bytes: its most durable option.
    public var primaryBucket: SavingsBucket { savingsOptions[0] }
}
