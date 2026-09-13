import Foundation

/// How a storage category may be handled. Mirrors docs/product/STORAGE_CATALOG.md.
public enum Strategy: String, Sendable, Codable, CaseIterable {
    case nativeConfiguration  // Xcode's own Locations setting
    case safeCleanup  // regenerable; delete via official commands
    case coldStorage  // archive to external, off the live path
    case userDirectoryRelocation
    case symlinkRelocation  // per-category only; forbidden for some paths
    case canonicalMount  // experimental, gated on E1/E2/E4/E6
    case downloadRepository  // keep installers externally (Runtime Library)
    case restoreOnDemand
    case appleManaged  // info only
    case neverMove
}

/// Evidence status for a (category, strategy) pair. Anything below `.verified` renders as
/// experimental in CLI/GUI copy (NON_GOALS_AND_SAFETY.md "Definition of supported").
public enum EvidenceStatus: String, Sendable, Codable {
    case verified, probable, experimental, unverified, falsified
}

public enum Regenerability: String, Sendable, Codable {
    case regenerable  // rebuilt automatically by Xcode/tools
    case redownloadable  // Apple will download it again on demand
    case userRecreatable  // user can recreate with effort (e.g. simulator devices)
    case nonRegenerable  // Archives, custom data — never auto-delete
}

public enum RiskLevel: String, Sendable, Codable, Comparable {
    case none, low, medium, high, critical
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
    private var rank: Int {
        switch self {
        case .none: 0;
        case .low: 1;
        case .medium: 2;
        case .high: 3;
        case .critical: 4
        }
    }
}

public enum PrivilegeLevel: String, Sendable, Codable { case user, root }

/// The owning Apple subsystem, used for grouping and for choosing the right official command.
public enum Subsystem: String, Sendable, Codable {
    case xcodeIDE, coreSimulator, mobileAsset, coreDevice, swiftPM, toolchain, commandLineTools, xctest, playgrounds, previews, other
}

/// One catalog entry. Paths are templates (`~` allowed); instances are resolved at scan time.
public struct StorageCategory: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var subsystem: Subsystem
    public var pathTemplates: [String]
    public var description: String
    public var regenerability: Regenerability
    public var deletionRisk: RiskLevel
    public var relocationRisk: RiskLevel
    public var recommendedStrategy: Strategy
    public var allowedStrategies: [Strategy]
    public var privilege: PrivilegeLevel
    public var evidence: String?  // matrix entry, F#, H#, or Apple URL — nil ⇒ unverified
    public var evidenceStatus: EvidenceStatus
    public var minimumXcodeMajor: Int?
    public var notes: [String]
    /// Whether the directory content is (at least partly) mount grafts rather than storage.
    public var isMountGraft: Bool
    /// Official command that reclaims this category (when deletion must go through Apple's tool).
    public var cleanupCommand: String?
    /// Set when the category does not live at a fixed path but *inside every simulator device*, at
    /// `<device root>/<subpath>` (F22). `pathTemplates` then names the enclosing device set, which is
    /// what containment is checked against; the concrete instances are enumerated at scan time from
    /// the device roots actually on disk. A category with this set is reported per device, never as
    /// one aggregate path, because the devices are independently disposable.
    ///
    /// Plural for the same reason `pathTemplates` is: one concept can occupy more than one directory
    /// (the log store is `db/diagnostics` *and* `db/uuidtext`), and splitting it into two categories
    /// to fit a singular field would report one idea as two numbers.
    public var perDeviceSubpaths: [String]
    /// Set when this category's bytes are already counted inside another category's total — it is a
    /// *breakdown* of that category, not storage in addition to it. Summaries skip these items, so
    /// the machine-wide totals stay the sum of disjoint parts; the per-item lines still show them,
    /// which is the whole point of having them. Without this, adding a breakdown category silently
    /// inflates every headline number by the size of the slice, which is the same class of error as
    /// missing a directory entirely, only in the other direction.
    public var isBreakdownOf: String?
    /// What the user should do about a category the product reports but does not clean. Nil means
    /// "nothing we can stand behind yet" and `doctor` then offers no remediation at all, which is
    /// the honest rendering of not knowing — never a plausible-sounding command we have not run.
    public var remediationHint: String?

    public init(
        id: String, name: String, subsystem: Subsystem, pathTemplates: [String], description: String,
        regenerability: Regenerability, deletionRisk: RiskLevel, relocationRisk: RiskLevel,
        recommendedStrategy: Strategy, allowedStrategies: [Strategy], privilege: PrivilegeLevel = .user,
        evidence: String? = nil, evidenceStatus: EvidenceStatus = .unverified, minimumXcodeMajor: Int? = nil,
        notes: [String] = [], isMountGraft: Bool = false, cleanupCommand: String? = nil,
        perDeviceSubpaths: [String] = [], remediationHint: String? = nil, isBreakdownOf: String? = nil
    ) {
        self.id = id; self.name = name; self.subsystem = subsystem; self.pathTemplates = pathTemplates
        self.description = description; self.regenerability = regenerability; self.deletionRisk = deletionRisk
        self.relocationRisk = relocationRisk; self.recommendedStrategy = recommendedStrategy
        self.allowedStrategies = allowedStrategies; self.privilege = privilege; self.evidence = evidence
        self.evidenceStatus = evidence == nil ? .unverified : evidenceStatus
        self.minimumXcodeMajor = minimumXcodeMajor; self.notes = notes; self.isMountGraft = isMountGraft
        self.cleanupCommand = cleanupCommand; self.perDeviceSubpaths = perDeviceSubpaths
        self.remediationHint = remediationHint; self.isBreakdownOf = isBreakdownOf
    }

    /// Rule 10 of CLAUDE.md: not supported until verified. Everything else is labeled experimental.
    public var isExperimental: Bool { evidenceStatus != .verified && recommendedStrategy != .appleManaged && recommendedStrategy != .neverMove }
    public var isRelocatable: Bool {
        allowedStrategies.contains {
            [.nativeConfiguration, .userDirectoryRelocation, .symlinkRelocation, .canonicalMount, .coldStorage, .downloadRepository].contains($0)
        }
    }
    public var isCleanable: Bool { allowedStrategies.contains(.safeCleanup) || cleanupCommand != nil }
    public var mustStayLocal: Bool { recommendedStrategy == .neverMove || recommendedStrategy == .appleManaged }

    /// Human label of the honest outcome: relocatable / delete-only / neither (UX_AND_CLI.md).
    public var outcomeLabel: String {
        switch (isRelocatable, isCleanable) {
        case (true, _): return "relocatable"
        case (false, true): return cleanupCommand != nil ? "delete-only (official tool)" : "delete-only"
        case (false, false): return mustStayLocal ? "must stay local" : "informational"
        }
    }
}
