import Foundation

/// Compile-time-ish safety invariants from NON_GOALS_AND_SAFETY.md and CLAUDE.md rule 7.
/// Every catalog and every plan is validated against these; a violation is a programming
/// error, not a user error.
public enum CatalogRules {
    /// Paths that must never be symlinked or redirected wholesale (FB12363725, H5).
    public static let neverSymlink: [String] = [
        "~/Library/Developer",
        "~/Library/Developer/CoreSimulator",
        "~/Library/Developer/DeveloperDiskImages",
        "/Library/Developer",
    ]
    /// Nothing under here is ever modified by us (only Apple's own tools may).
    public static let neverModifyPrefixes: [String] = ["/System"]

    public struct Violation: Error, CustomStringConvertible, Sendable {
        public let categoryID: String
        public let message: String
        public var description: String { "[\(categoryID)] \(message)" }
    }

    public static func validate(_ category: StorageCategory) -> [Violation] {
        var v: [Violation] = []
        for t in category.pathTemplates {
            if neverSymlink.contains(t) && category.allowedStrategies.contains(where: { $0 == .symlinkRelocation || $0 == .userDirectoryRelocation }) {
                v.append(Violation(categoryID: category.id, message: "\(t) may never be symlinked/relocated (CLAUDE.md rule 7)"))
            }
            if neverModifyPrefixes.contains(where: { t.hasPrefix($0) }) && category.allowedStrategies.contains(where: { $0 != .appleManaged && $0 != .neverMove }) {
                v.append(Violation(categoryID: category.id, message: "\(t) is under /System: only appleManaged/neverMove allowed (CLAUDE.md rule 2)"))
            }
        }
        if category.regenerability == .nonRegenerable && category.allowedStrategies.contains(.safeCleanup) {
            v.append(Violation(categoryID: category.id, message: "non-regenerable data cannot have safeCleanup (CLAUDE.md rule 5)"))
        }
        if category.evidence == nil && category.evidenceStatus == .verified {
            v.append(Violation(categoryID: category.id, message: "verified status without evidence pointer"))
        }
        if !category.allowedStrategies.contains(category.recommendedStrategy) {
            v.append(Violation(categoryID: category.id, message: "recommended strategy not in allowed strategies"))
        }
        return v
    }

    public static func validate(_ catalog: [StorageCategory]) -> [Violation] {
        var all = catalog.flatMap(validate)
        let ids = catalog.map(\.id)
        for dup in Set(ids.filter { id in ids.filter { $0 == id }.count > 1 }) {
            all.append(Violation(categoryID: dup, message: "duplicate category id"))
        }
        return all
    }
}
