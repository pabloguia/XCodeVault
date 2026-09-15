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

    /// True when `path` **is** this category, or lies inside it.
    ///
    /// For an ordinary category that is containment in `pathTemplates`, which is what containment
    /// has always meant here. For a per-device category it is not, and the difference is the point
    /// of this function: `pathTemplates` names the enclosing *device set*, and the set is the
    /// enclosure rather than the storage. The category is `<deviceSet>/<one device>/<subpath>`, so
    /// a prefix test against the set accepts the set itself, every device root, and every byte of
    /// every device — including the app containers, which are neither regenerable nor ours.
    ///
    /// The test is structural on purpose: it asks whether the path has the shape
    /// `<set>/<single component>/<subpath>…` once canonicalized, rather than enumerating the
    /// devices present on disk. A predicate that read the filesystem would answer differently
    /// depending on which devices existed at that instant, and callers use this to decide whether
    /// to act on a path — an answer that must not change because a device appeared between the
    /// check and the act.
    public func containsPath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard let p = try? PathSafety.canonicalize(path) else { return false }
        guard !perDeviceSubpaths.isEmpty else {
            return pathTemplates.contains { PathSafety.isContained(p, in: $0.expandingTilde(home: home)) }
        }
        // ONE decision, deliberately. An earlier version also guarded `below.count >= 2` to reject
        // a bare device root, and mutation testing showed why that was a liability rather than
        // belt-and-braces: the subpath match below already rejects it, so mutating either guard
        // changed nothing and both read as load-bearing while neither was individually pinned.
        // The rule is stated once — "the components under the device must begin with a subpath" —
        // and everything else follows from it.
        for template in pathTemplates {
            guard let root = try? PathSafety.canonicalize(template.expandingTilde(home: home)) else { continue }
            // Not `isContained`: this is the arithmetic's precondition, not the answer. `p == root`
            // yields no components below and is rejected by the subpath match either way, so this
            // guard is UNPINNED — no test distinguishes it, and swapping it for `isContained` is an
            // equivalent mutant. It stays because `dropFirst` on a path that is not under `root`
            // would slice a string that means nothing.
            guard p.hasPrefix(root + "/") else { continue }
            let below = String(p.dropFirst(root.count + 1))
                .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // below[0] must be a device, and "a device" is `SimulatorNaming.isDeviceUDID` — the
            // same rule the scanner enumerates by, called rather than restated. Without it any
            // directory a user left in the device set (`Backup 2026-09-01`) satisfied containment
            // for a per-device category and reached a deletion path; the scanner had always been
            // stricter, and the two disagreeing was the bug.
            guard let device = below.first, SimulatorNaming.isDeviceUDID(device) else { continue }
            // The category begins one level in, so a path that stops at the device — or at the
            // set — has nothing left to match a subpath against.
            let insideDevice = Array(below.dropFirst())
            for sub in perDeviceSubpaths {
                let subComponents = sub.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                // Two halves, and they are NOT alike — an earlier version of this comment claimed
                // both were equivalent mutants and was wrong about one of them.
                //  - `insideDevice.count >= subComponents.count` IS equivalent: `prefix(n)` past the
                //    end returns the whole array, which then compares unequal anyway. Removing it
                //    fails no test, and that is the right answer rather than a gap to plug.
                //  - `!subComponents.isEmpty` is LOAD-BEARING. With no components,
                //    `Array(insideDevice.prefix(0)) == []` is true and the predicate would accept
                //    every path in the device set, app containers included. Pinned by a test that
                //    builds such a category directly, because `CatalogRules.validate` is not a
                //    startup invariant — it only runs in the `compatibility` subcommand.
                guard !subComponents.isEmpty, insideDevice.count >= subComponents.count else { continue }
                if Array(insideDevice.prefix(subComponents.count)) == subComponents { return true }
            }
        }
        return false
    }

    /// What `containsPath` expected, for the message a refusal prints. A guard that only says "no"
    /// sends the user to read our source to find out what shape it wanted.
    public var containmentShapeHint: String {
        guard !perDeviceSubpaths.isEmpty else {
            return pathTemplates.isEmpty ? "" : " Expected a path under \(pathTemplates.joined(separator: " or "))."
        }
        let set = pathTemplates.first ?? "<device set>"
        // Each alternative is rendered whole. Joining the subpaths alone produced
        // "…/<UDID>/data/var/db/diagnostics or data/var/db/uuidtext", where the second reads as a
        // separate root rather than another subpath of the same device.
        let subs = perDeviceSubpaths.map { "\(set)/<device UDID>/\($0)" }.joined(separator: " or ")
        return " This category lives inside every simulator device, not at one path: expected \(subs)."
    }

    /// The single path a command may default to when the user gives none, or nil when the category
    /// has no single location. Per-device categories have none — they live inside every device —
    /// and defaulting them to `pathTemplates.first` names the device set, which is the one place
    /// they are certainly not. Callers must ask for an explicit path rather than invent one.
    public func singleStandardPath(home: String = NSHomeDirectory()) -> String? {
        guard perDeviceSubpaths.isEmpty, let first = pathTemplates.first else { return nil }
        return first.expandingTilde(home: home)
    }
}
