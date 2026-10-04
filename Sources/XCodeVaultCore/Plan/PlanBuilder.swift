import Foundation

// R7-C: the guided Plan — the best path for this Mac as ordered steps. The user (2026-10-04): "um passo-a-passo para a
// melhor solução: preparar o drive -> criar volume específico -> movimentar o que for possível (com uma previsão de
// espaço a ser recuperado, e deixando claro o que vai ser uma cópia temporária e o que vai rodar no device)."
//
// The plan is DERIVED, NEVER STORED (ADR-0013): `PlanBuilder.plan` is a pure function of what the app already read — the
// scan, the drives as assessed, the vault registry's checks, Xcode's locations, the journal's History rows and the
// doctor's findings — so it cannot drift from the Mac it describes, and it updates when any of those does (a drive
// plugged in, an operation finished). Nothing here runs anything: every step's action names an EXISTING sheet or screen,
// and each keeps its own review and confirmation. Nothing is chained (ADR-0012, rule 6).

/// What a plan step or item's button opens. The app maps each case to an existing opener (`AppModel.performPlanAction`);
/// this enum is the whole of what the Plan can reach.
public enum PlanAction: Sendable, Equatable {
    /// The Drives screen: connect, choose or read why a drive cannot be used.
    case showDrives
    /// The preparation sheet for `option` on the disk `diskID` (R6), with its own review and typed-name confirmation.
    case prepareDrive(diskID: String, option: PreparationOption)
    /// **Use This Drive** for the volume `volumeUUID` on `diskID` (R6): its own review; registers and makes the folders.
    case useDrive(diskID: String, volumeUUID: String)
    /// **Run…** for the plan row of `categoryID` in `bucket` (R3/R6/R7-A): the Run sheet, the vault's standard folder
    /// pre-filled, its own review and confirmation.
    case run(categoryID: String, bucket: SavingsBucket)
    /// A Save Space view, where the item is acted on with that view's own confirmation (Delete's exact-count dialog).
    case showBucket(SavingsBucket)
    /// The Health screen.
    case showHealth
}

/// Why a step cannot be done yet.
public enum PlanBlock: Sendable, Equatable {
    /// No external drive is connected and no vault is registered.
    case noExternalDrive
    /// Drives are connected but none can hold a vault (`DriveVerdict.cannotBeUsed` for every one).
    case noUsableDrive
    /// A vault is registered but not connected: its name.
    case vaultOffline(String)
    /// The drive has no recommended fix — what it offers erases data, or is the ownership setting the app does not run —
    /// so the choice is the user's, in Drives. The Plan never proposes an erase by itself.
    case chooseInDrives
    /// A step above has to be done first.
    case needsEarlierStep
}

/// What happens to an item, in the user's terms (the four kinds of R7-C).
public enum PlanOutcome: String, Sendable, CaseIterable, Codable {
    /// New data is written to the vault (DerivedData, new Archives): it runs from the drive.
    case runsFromDrive
    /// Existing data is copied to the vault, verified, and the original removed in the two-step remove (Archives).
    case movedToDrive
    /// Leaves this Mac and comes back when needed (a parked simulator runtime).
    case leavesAndComesBack
    /// Deleted here and recreated on demand (caches and other regenerable data). Never Archives (rule 5).
    case deletedRecreated
}

/// One thing the move step can do.
public struct PlanItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var outcome: PlanOutcome
    public var categoryID: String
    /// The catalog's English name, or the journal's summary for a runtime already parked: records, never translated.
    public var name: String
    /// What it frees on this Mac: the item's internal bytes, counted once (`SavingsCalculator`). 0 for new data only.
    public var bytes: UInt64
    /// What is already off this Mac because of it: bytes found on the vault, or a parked runtime's recorded size.
    public var doneBytes: UInt64
    public var isDone: Bool
    public var isExperimental: Bool
    /// The caveats that must stay visible on the item, as stable ids: `derivedDataTests` (unit tests fail to load from an
    /// external physical drive on macOS 26 — never hidden).
    public var warnings: [String]
    /// Nil when it is done or nothing opens for it.
    public var action: PlanAction?
}

public struct PlanStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case chooseDrive, prepareDrive, registerVault, moveItems, checkHealth
    }

    public enum State: Sendable, Equatable {
        case done
        case next
        case blocked(PlanBlock)
        case notNeeded
    }

    public var kind: Kind
    public var state: State
    /// The drive or vault the step is about, as the user knows it (a volume name); nil when there is none.
    public var subject: String?
    /// The space the step adds to what is freed; nil when it frees nothing by itself.
    public var bytes: UInt64?
    public var isExperimental: Bool
    public var action: PlanAction?
    /// The move step's items; empty for the others.
    public var items: [PlanItem]
    /// The preparation the step proposes (prepare step only).
    public var option: PreparationOption?
    /// Health: the findings that are warnings or worse.
    public var findingCount: Int

    public var id: String { kind.rawValue }
}

/// The header: up to how much can be freed, how much is done, and by outcome. Each item counted once.
public struct PlanSummary: Sendable, Equatable {
    public var upTo: UInt64
    public var done: UInt64
    public var byOutcome: [PlanOutcome: UInt64]
}

public struct Plan: Sendable, Equatable {
    public var steps: [PlanStep]
    public var summary: PlanSummary
    /// The vault the moves go to (its UUID), when there is a usable one: the Run sheets open on its standard folders.
    public var vaultUUID: String?

    /// The step whose button is the screen's one primary action: the first that is `next`.
    public var primaryStepKind: PlanStep.Kind? { steps.first { $0.state == .next }?.kind }

    public func step(_ kind: PlanStep.Kind) -> PlanStep? { steps.first { $0.kind == kind } }
}

public enum PlanBuilder {
    /// The plan for this Mac now. Pure: the same inputs give the same plan.
    public static func plan(
        report: ScanReport, drives: [DriveAssessment], vaults: [VaultVolumeCheck], locations: XcodeLocations?, history: [JournalTimeline.Row],
        findings: [Finding]
    ) -> Plan {
        let usable = vaults.filter { $0.isUsable && $0.currentMountPoint != nil }
        // A good vault: usable, and not on a volume whose case-sensitivity or ignored ownership the drive's own fix is for
        // (PABLO's case: the plan's path goes through the recommended new volume first).
        let good = usable.first { v in !isFixable(v, drives) }
        let chosen = chosenDrive(good: good, drives: drives)
        let candidate = chosen.flatMap(registrationCandidate)

        // 1. Choose a drive.
        var choose = step(.chooseDrive)
        if let good {
            choose.state = .done
            choose.subject = good.volume.volumeName
        } else if let chosen {
            choose.state = .done
            choose.subject = chosen.displayName
        } else {
            choose.action = .showDrives
            if let offline = vaults.first(where: { !$0.isUsable }) {
                choose.state = .blocked(.vaultOffline(offline.volume.volumeName))
            } else {
                choose.state = .blocked(drives.isEmpty ? .noExternalDrive : .noUsableDrive)
            }
        }

        // 2. Prepare it: only when the chosen drive needs it, with its recommended option.
        var prepare = step(.prepareDrive)
        prepare.subject = chosen?.displayName
        if good != nil || candidate != nil {
            // A good vault, or a volume on the chosen drive that can be registered as it is: nothing to prepare (or it was).
            prepare.state = good == nil && chosen?.recommendedOption != nil ? .done : .notNeeded
        } else if let chosen {
            // Only the recommended option, which erases nothing (`DriveAssessment.isRecommended`): never an erase.
            if let option = chosen.recommendedOption {
                prepare.state = .next
                prepare.option = option
                prepare.isExperimental = true
                prepare.action = .prepareDrive(diskID: chosen.disk.id, option: option)
            } else {
                prepare.state = .blocked(.chooseInDrives)
                prepare.action = .showDrives
            }
        } else {
            prepare.state = .blocked(.needsEarlierStep)
        }

        // 3. Register it as a vault (Use This Drive, which also makes the standard folders).
        var register = step(.registerVault)
        if let good {
            register.state = .done
            register.subject = good.volume.volumeName
        } else if let chosen, let candidate, let uuid = candidate.volumeUUID {
            register.state = .next
            register.subject = candidate.volumeName
            register.action = .useDrive(diskID: chosen.disk.id, volumeUUID: uuid)
        } else {
            register.state = .blocked(.needsEarlierStep)
        }

        // 4. Move what can move.
        let items = moveItems(report: report, vault: good, locations: locations, history: history)
        var move = step(.moveItems)
        move.items = items.map { item in
            var i = item
            // Without a vault nothing can go to it yet; deleting needs none.
            if good == nil && i.outcome != .deletedRecreated { i.action = nil }
            return i
        }
        move.isExperimental = items.contains { $0.isExperimental && !$0.isDone }
        let open = items.filter { !$0.isDone }
        move.bytes = open.reduce(0) { $0 + $1.bytes }
        if good == nil {
            move.state = .blocked(.needsEarlierStep)
        } else {
            move.state = open.contains { $0.action != nil } ? .next : .done
        }

        // 5. Check health: done when the last read found nothing that is a warning or worse.
        var health = step(.checkHealth)
        health.findingCount = findings.filter { $0.severity >= .warning }.count
        health.state = health.findingCount == 0 ? .done : .next
        health.action = .showHealth

        let summary = PlanSummary(
            upTo: open.reduce(0) { $0 + $1.bytes }, done: items.filter(\.isDone).reduce(0) { $0 + $1.doneBytes },
            byOutcome: Dictionary(grouping: open, by: \.outcome).mapValues { $0.reduce(0) { $0 + $1.bytes } })
        return Plan(steps: [choose, prepare, register, move, health], summary: summary, vaultUUID: good?.volume.volumeUUID)
    }

    private static func step(_ kind: PlanStep.Kind) -> PlanStep {
        PlanStep(kind: kind, state: .notNeeded, subject: nil, bytes: nil, isExperimental: false, action: nil, items: [], option: nil, findingCount: 0)
    }

    // MARK: - The drive

    /// A usable vault whose drive recommends a fix for its own volume — case-sensitive, or ownership ignored.
    static func isFixable(_ vault: VaultVolumeCheck, _ drives: [DriveAssessment]) -> Bool {
        guard let drive = drives.first(where: { $0.vault?.volume.volumeUUID == vault.volume.volumeUUID }) else { return false }
        guard let volume = drive.volumes.first(where: { $0.volumeUUID?.uppercased() == vault.volume.volumeUUID.uppercased() }) else { return false }
        return drive.recommendedOption != nil && !isGoodVolume(volume)
    }

    /// The drive the path goes through: the good vault's; else a drive holding a vault that needs its fix (PABLO);
    /// else one that can be used; else one that needs preparation. `drives` is already ranked (`DriveEvaluation`).
    static func chosenDrive(good: VaultVolumeCheck?, drives: [DriveAssessment]) -> DriveAssessment? {
        if let good { return drives.first { $0.vault?.volume.volumeUUID == good.volume.volumeUUID } }
        return drives.first { $0.verdict == .ready } ?? drives.first { $0.verdict == .canBeUsed } ?? drives.first { $0.verdict == .needsPreparation }
    }

    /// A volume on the chosen drive that can be registered as a good vault as it is: mounted, suitable, not registered,
    /// case-insensitive with ownership on. After the recommended new volume is added, this is that volume.
    static func registrationCandidate(_ drive: DriveAssessment) -> Volume? {
        let registered = drive.vault.map { Set([$0.volume.volumeUUID.uppercased()]) } ?? []
        return drive.volumes.filter { v in
            guard let uuid = v.volumeUUID?.uppercased(), !registered.contains(uuid), v.mountPoint != nil else { return false }
            return isGoodVolume(v) && drive.qualifications[v.deviceNode]?.verdict != .unsuitable
        }.max { $0.freeBytes < $1.freeBytes }
    }

    static func isGoodVolume(_ v: Volume) -> Bool {
        v.isAPFS && !v.filesystemPersonality.lowercased().contains("case-sensitive") && v.ownersEnabled
    }

    // MARK: - The items

    /// The move step's items, from the scan's items counted once by their primary bucket — the rule the Overview, the
    /// planner and the Storage chart share — plus Xcode's location for new Archives and the runtimes the journal says
    /// were parked. Keep-local items are not in the plan; Archives are never deleted (rule 5).
    static func moveItems(report: ScanReport, vault: VaultVolumeCheck?, locations: XcodeLocations?, history: [JournalTimeline.Row]) -> [PlanItem] {
        let vaultMount = vault?.currentMountPoint
        var internalBytes: [String: UInt64] = [:]
        var vaultBytes: [String: UInt64] = [:]
        var bucketOf: [String: SavingsBucket] = [:]
        for item in report.items {
            let category = report.category(for: item)
            guard let bucket = SavingsCalculator.countedOnceBucket(item, category: category), bucket != .keepLocal else { continue }
            if bucket == .deleteAndRegenerate && item.categoryID == "archives" { continue }
            bucketOf[item.categoryID] = bucket
            if SavingsCalculator.isInternalSaving(item) {
                internalBytes[item.categoryID, default: 0] = add(internalBytes[item.categoryID, default: 0], item.allocatedBytes)
            } else if let mp = vaultMount, item.volumeMountPoint == mp {
                vaultBytes[item.categoryID, default: 0] = add(vaultBytes[item.categoryID, default: 0], item.allocatedBytes)
            }
        }
        var items: [PlanItem] = []
        let order: [SavingsBucket] = [.runFromExternal, .parkExternally, .deleteAndRegenerate]
        let ids = bucketOf.keys.sorted { a, b in
            let (ba, bb) = (order.firstIndex(of: bucketOf[a]!) ?? 9, order.firstIndex(of: bucketOf[b]!) ?? 9)
            if ba != bb { return ba < bb }
            let (sa, sb) = (internalBytes[a] ?? 0, internalBytes[b] ?? 0)
            return sa != sb ? sa > sb : a < b
        }
        for id in ids {
            guard let bucket = bucketOf[id], let category = StorageCatalog.category(id) else { continue }
            let bytes = internalBytes[id] ?? 0
            let onVault = vaultBytes[id] ?? 0
            let option = category.savingsOptionDetails.first { $0.bucket == bucket }
            var item = PlanItem(
                id: bucket.rawValue + ":" + id, outcome: outcome(categoryID: id, bucket: bucket), categoryID: id, name: category.name, bytes: bytes,
                doneBytes: onVault, isDone: false, isExperimental: option?.isExperimental ?? false, warnings: [], action: nil)
            switch item.outcome {
            case .runsFromDrive:
                // DerivedData: done once Xcode builds on the vault. Its tests caveat stays visible, done or not.
                item.isDone = isOnVault(locations?.derivedData, vaultMount)
                if id == "derivedData" { item.warnings = ["derivedDataTests"] }
            case .movedToDrive, .leavesAndComesBack:
                item.isDone = bytes == 0 && onVault > 0
            case .deletedRecreated:
                item.isDone = false
            }
            if bytes == 0 && !item.isDone { continue }
            item.action = item.isDone ? nil : action(categoryID: id, bucket: bucket)
            items.append(item)
        }
        // New Archives: Xcode's Archives location, new data only (0 bytes now). Done when it is on the vault.
        if SavingsPlanner.command(categoryID: "archives", bucket: .runFromExternal) != nil {
            let done = isOnVault(locations?.archives, vaultMount)
            let option = StorageCatalog.category("archives")?.savingsOptionDetails.first { $0.bucket == .runFromExternal }
            items.insert(
                PlanItem(
                    id: "runFromExternal:archives", outcome: .runsFromDrive, categoryID: "archives",
                    name: StorageCatalog.category("archives")?.name ?? "Archives",
                    bytes: 0, doneBytes: 0, isDone: done, isExperimental: option?.isExperimental ?? false, warnings: [],
                    action: done ? nil : .run(categoryID: "archives", bucket: .runFromExternal)),
                at: items.firstIndex { $0.outcome != .runsFromDrive } ?? items.endIndex)
        }
        // Runtimes the journal records as parked (offloaded, completed): done, with their recorded size.
        for row in history where row.kind == .runtimeOffload && row.outcome == .completed {
            items.append(
                PlanItem(
                    id: "parked:" + row.id, outcome: .leavesAndComesBack, categoryID: "simulatorRuntimeAssets", name: row.summary, bytes: 0,
                    doneBytes: row.bytes ?? 0, isDone: true, isExperimental: true, warnings: [], action: nil))
        }
        return items
    }

    /// The outcome of an item counted in `bucket`: the four kinds the user asked to tell apart.
    public static func outcome(categoryID: String, bucket: SavingsBucket) -> PlanOutcome {
        switch bucket {
        case .runFromExternal: .runsFromDrive
        case .parkExternally: categoryID == "archives" ? .movedToDrive : .leavesAndComesBack
        case .deleteAndRegenerate, .keepLocal: .deletedRecreated
        }
    }

    /// What an item's button opens: the Run sheet where the app runs that row (`SavingsPlanner.command` has one and it is
    /// a kind the Run sheet handles); the bucket's view otherwise — Delete keeps its own exact-count confirmation.
    public static func action(categoryID: String, bucket: SavingsBucket) -> PlanAction {
        switch (bucket, categoryID) {
        case (.runFromExternal, "derivedData"), (.runFromExternal, "archives"), (.runFromExternal, "runtimeLibrary"), (.parkExternally, "archives"),
            (.parkExternally, "simulatorRuntimeAssets"):
            .run(categoryID: categoryID, bucket: bucket)
        default:
            .showBucket(bucket)
        }
    }

    static func isOnVault(_ path: String?, _ mountPoint: String?) -> Bool {
        guard let path, let mountPoint else { return false }
        return path == mountPoint || path.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/")
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (v, o) = a.addingReportingOverflow(b)
        return o ? .max : v
    }
}
