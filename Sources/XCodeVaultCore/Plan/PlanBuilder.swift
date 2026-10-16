import Foundation

// R7-C: the guided Plan — the best path for this Mac as ordered steps. The user (2026-10-04): "um passo-a-passo para a
// melhor solução: preparar o drive -> criar volume específico -> movimentar o que for possível (com uma previsão de
// espaço a ser recuperado, e deixando claro o que vai ser uma cópia temporária e o que vai rodar no device)."
//
// The plan is DERIVED, NEVER STORED (ADR-0013): `PlanBuilder.plan` is a pure function of what the app already read — the
// scan, the drives as assessed, the vault registry's checks, Xcode's locations, the runtimes the whole journal shows
// parked (`ParkedRuntimes`) and the doctor's findings — so it cannot drift from the Mac it describes, and it updates when
// any of those does (a drive plugged in, an operation finished). Nothing here runs anything: every step's action names an
// EXISTING sheet or screen, and each keeps its own review and confirmation. Nothing is chained (ADR-0012, rule 6).
//
// The R7-C fix round (safety review F1–F7, quality I1–I3): data the user made is never "recreated on demand" (F1); old
// DerivedData is its own item, deleted, not "run from the drive" (F2/I1); parked runtimes come from the whole journal
// (F3/I2); an unusable vault says why (F4).

/// What a plan step or item's button opens. The app maps each case to an existing opener (`AppModel.performPlanAction`);
/// this enum is the whole of what the Plan can reach.
public enum PlanAction: Sendable, Equatable {
    /// The Drives screen: connect, choose or read why a drive cannot be used.
    case showDrives
    /// The preparation sheet for `option` on the disk `diskID` (R6), with its own review and typed-name confirmation. The
    /// app opens it only for the drive's recommended option, and offers no erasing option in it (F5, F6).
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
    /// R7-D: shows a volume in Finder, where File ▸ Get Info has "Ignore ownership on this volume". Nothing runs.
    case showInFinder(path: String)
    /// R7-D: copies `sudo diskutil enableOwnership <mountPoint>` for Terminal. The app never asks for a password or runs it.
    case copyOwnershipCommand(mountPoint: String)
}

/// Why a step cannot be done yet.
public enum PlanBlock: Sendable, Equatable {
    /// No external drive is connected and no vault is registered.
    case noExternalDrive
    /// Drives are connected but none can hold a vault (`DriveVerdict.cannotBeUsed` for every one).
    case noUsableDrive
    /// A vault is registered but not connected: its name.
    case vaultOffline(String)
    /// The vault is not mounted and its mount point holds data on this Mac (`ambiguous`): shadow data, which rule 6 says
    /// must be reported. The vault's name and the size found there, when it could be read in full.
    case vaultShadowed(name: String, bytes: UInt64?)
    /// A different volume is mounted where the vault should be, or the vault's sentinel is gone (`foreign`,
    /// `sentinelMissing`): its name.
    case vaultReplaced(String)
    /// The drive has no recommended fix — what it offers erases data, or is the ownership setting the app does not run —
    /// so the choice is the user's, in Drives. The Plan never proposes an erase by itself.
    case chooseInDrives
    /// The suitable volume has to be added first (step 2).
    case addVolumeFirst
    /// Ownership has to be turned on for the volume first (step 2): its name.
    case ownershipFirst(String)
    /// A step above has to be done first.
    case needsEarlierStep
}

/// What a step adds to its explanation beyond its state.
/// What is wrong with a vault's volume, exactly (R7-D: no "case-sensitive or ignores ownership").
public enum VolumeIssue: Sendable, Equatable {
    case caseSensitive, ownershipOff, both

    static func of(_ v: Volume) -> VolumeIssue? {
        let cs = v.filesystemPersonality.lowercased().contains("case-sensitive")
        switch (cs, !v.ownersEnabled) {
        case (true, true): return .both
        case (true, false): return .caseSensitive
        case (false, true): return .ownershipOff
        case (false, false): return nil
        }
    }
}

public enum PlanNote: Sendable, Equatable {
    /// Step 1: the drive holds the vault, but the vault's volume is the wrong kind (`issue`). `ownershipVolume` names the
    /// volume on the same drive that only needs ownership turned on (R7-D); nil when step 2 adds a new volume.
    case vaultWrongKind(drive: String, issue: VolumeIssue, ownershipVolume: String?)
    /// Step 2: ownership is off on this volume, its only blocker: turn it on in Finder (R7-D). The volume's name.
    case turnOnOwnership(volume: String)
    /// Step 3: the new vault is a second one; the registered vault on `existing` stays registered and nothing on it moves.
    case secondVault(existing: String)
    /// Step 2: the drive has a suitable volume. Says what is there, not who made it.
    case suitableVolume(drive: String, volume: String)
    /// Step 1, done with a good vault, while ANOTHER registered vault has shadow data at its mount point (`ambiguous`):
    /// not blocking, but reported, pointing to Health (rule 6; safety re-review N3). The other vault's name and the size.
    case otherVaultShadowed(name: String, bytes: UInt64?)
}

/// What happens to an item, in the user's terms: what needs the drive connected, what leaves its only copy on the drive,
/// what is deleted and whether anything rebuilds it (I3).
public enum PlanOutcome: String, Sendable, CaseIterable, Codable {
    /// New data is written to the vault (new builds, new Archives): keep the drive connected while you work.
    case runsFromDrive
    /// Existing data is copied to the vault and verified; the original is removed only in the second step (Archives).
    case movedToDrive
    /// Parked on the drive (a simulator runtime): it comes back to this Mac only when you restore it, which needs the drive.
    case parkedOnDrive
    /// Deleted here and rebuilt on demand (caches, old DerivedData). Never Archives (rule 5).
    case deletedRebuilt
    /// Deleted, and nothing recreates it: what you made in it is lost (simulator devices, F1).
    case deletedLost
}

/// An item's name as the app words it: localized through keys, never the catalog's English name in another language.
public enum PlanItemName: Sendable, Equatable {
    /// New builds go to the drive (Xcode's DerivedData location).
    case newDerivedData
    /// The DerivedData already on this Mac.
    case oldDerivedData
    /// Archives made from now on (Xcode's Archives location).
    case newArchives
    /// The Archives already on this Mac.
    case existingArchives
    /// A catalog category, by id.
    case category(String)
    /// A runtime the journal shows parked: its name as recorded (a record, never translated).
    case parkedRuntime(String)
}

/// One thing the move step can do.
public struct PlanItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var outcome: PlanOutcome
    public var categoryID: String
    public var name: PlanItemName
    /// What it frees on this Mac: the item's internal bytes, counted once (`SavingsCalculator`). 0 for new data only.
    public var bytes: UInt64
    /// What is already off this Mac because of it: bytes found on the vault, or a parked runtime's recorded size.
    public var doneBytes: UInt64
    public var isDone: Bool
    public var isExperimental: Bool
    /// Deleting it loses data the user made (F1): never in the headline, always tagged.
    public var losesUserData: Bool
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
        /// Some of the step's items can be acted on now; the rest waits for the vault (the move step without a vault).
        case partly
        case blocked(PlanBlock)
        case notNeeded
    }

    public var kind: Kind
    public var state: State
    /// The drive or vault the step is about, as the user knows it (a volume name); nil when there is none.
    public var subject: String?
    public var note: PlanNote?
    /// The space the step adds to what is freed; nil when it frees nothing by itself.
    public var bytes: UInt64?
    public var isExperimental: Bool
    public var action: PlanAction?
    /// A second button beside `action` (R7-D: Copy Command next to Show in Finder); never prominent.
    public var secondaryAction: PlanAction? = nil
    /// The move step's items; empty for the others.
    public var items: [PlanItem]
    /// The preparation the step proposes (prepare step only).
    public var option: PreparationOption?
    /// Health: the findings that are warnings or worse.
    public var findingCount: Int

    public var id: String { kind.rawValue }
}

/// The header: up to how much can be freed, how much is done, and by outcome. Each item counted once. What deleting would
/// lose for good is never in `upTo` (F1): it is `lostIfDeleted`, its own line.
public struct PlanSummary: Sendable, Equatable {
    public var upTo: UInt64
    public var done: UInt64
    public var byOutcome: [PlanOutcome: UInt64]
    public var lostIfDeleted: UInt64

    public init(upTo: UInt64, done: UInt64, byOutcome: [PlanOutcome: UInt64], lostIfDeleted: UInt64 = 0) {
        self.upTo = upTo
        self.done = done
        self.byOutcome = byOutcome
        self.lostIfDeleted = lostIfDeleted
    }
}

/// The one button the screen makes prominent.
public enum PlanPrimary: Sendable, Equatable {
    case step(PlanStep.Kind)
    case item(String)
}

public struct Plan: Sendable, Equatable {
    public var steps: [PlanStep]
    public var summary: PlanSummary
    /// The vault the moves go to (its UUID), when there is a usable one: the Run sheets open on its standard folders.
    public var vaultUUID: String?

    /// The screen's one primary action: the first step that is next or partly available and has a button — the step's
    /// own, or, for the move step, which has none, its first open item's.
    public var primary: PlanPrimary? {
        for step in steps where step.state == .next || step.state == .partly {
            if step.action != nil { return .step(step.kind) }
            // Never an item that loses the user's data (N1): it is listed, tagged, and never the thing to do next.
            if let item = step.items.first(where: { !$0.isDone && !$0.losesUserData && $0.action != nil }) { return .item(item.id) }
        }
        return nil
    }

    /// Whether something can be done now: a step is next, or partly available. The app opens on the Plan then. Items that
    /// lose the user's data never make a step next (N1), so they never open the app on the Plan either.
    public var hasSomethingToDo: Bool { steps.contains { $0.state == .next || $0.state == .partly } }

    public func step(_ kind: PlanStep.Kind) -> PlanStep? { steps.first { $0.kind == kind } }
}

public enum PlanBuilder {
    /// The plan for this Mac now. Pure: the same inputs give the same plan.
    public static func plan(
        report: ScanReport, drives: [DriveAssessment], vaults: [VaultVolumeCheck], locations: XcodeLocations?, parked: [ParkedRuntime],
        findings: [Finding]
    ) -> Plan {
        let usable = vaults.filter { $0.isUsable && $0.currentMountPoint != nil }
        // A good vault: usable, and not on a volume whose case-sensitivity or ignored ownership the drive's own fix is for
        // (PABLO's case: the plan's path goes through the recommended new volume first).
        let good = usable.first { v in !isFixable(v, drives) }
        let fixableVolume = { (v: VaultVolumeCheck) -> Volume? in
            drives.lazy.compactMap { d in d.volumes.first { $0.volumeUUID?.uppercased() == v.volume.volumeUUID.uppercased() } }.first
        }
        let fixable = good == nil ? usable.first { v in isFixable(v, drives) } : nil
        let chosen = chosenDrive(good: good, fixable: fixable, drives: drives)
        let candidate = chosen.flatMap(registrationCandidate)

        // 1. Choose a drive. Shadow data at a vault's mount point is reported first (rule 6).
        var choose = step(.chooseDrive)
        if let good {
            choose.state = .done
            choose.subject = good.volume.volumeName
            if let shadowed = vaults.first(where: { $0.state == .ambiguous }) {
                choose.note = .otherVaultShadowed(name: shadowed.volume.volumeName, bytes: shadowed.shadowBytes)
            }
        } else if let shadowed = vaults.first(where: { $0.state == .ambiguous }) {
            choose.state = .blocked(.vaultShadowed(name: shadowed.volume.volumeName, bytes: shadowed.shadowBytes))
            choose.action = .showHealth
        } else if let chosen {
            choose.state = .done
            choose.subject = chosen.displayName
            if let fixable, let volume = fixableVolume(fixable), let issue = VolumeIssue.of(volume) {
                choose.note = .vaultWrongKind(drive: chosen.displayName, issue: issue, ownershipVolume: chosen.ownershipFixVolume?.volumeName)
            }
        } else {
            choose.action = .showDrives
            if let replaced = vaults.first(where: { $0.state == .foreign || $0.state == .sentinelMissing }) {
                choose.state = .blocked(.vaultReplaced(replaced.volume.volumeName))
            } else if let offline = vaults.first(where: { !$0.isUsable }) {
                choose.state = .blocked(.vaultOffline(offline.volume.volumeName))
            } else {
                choose.state = .blocked(drives.isEmpty ? .noExternalDrive : .noUsableDrive)
            }
        }
        let chooseDone = choose.state == .done

        // 2. Prepare it: only when the chosen drive needs it, with its recommended option.
        var prepare = step(.prepareDrive)
        prepare.subject = chosen?.displayName
        if !chooseDone {
            prepare.state = .blocked(.needsEarlierStep)
        } else if let good {
            // The vault is suitable: done when its drive also has the unsuitable volume the fix was for, else not needed.
            let drive = drives.first { $0.vault?.volume.volumeUUID == good.volume.volumeUUID }
            if let drive, DriveEvaluation.wantsANewVolume(drive.volumes) {
                prepare.state = .done
                prepare.note = .suitableVolume(drive: drive.displayName, volume: good.volume.volumeName)
            } else {
                prepare.state = .notNeeded
            }
        } else if let chosen, let candidate {
            // A suitable volume is there: the fix is in place (or was never needed). Says what is there, not who made it.
            if DriveEvaluation.wantsANewVolume(chosen.volumes) {
                prepare.state = .done
                prepare.note = .suitableVolume(drive: chosen.displayName, volume: candidate.volumeName)
            } else {
                prepare.state = .notNeeded
            }
        } else if let chosen {
            // Only the recommended option, which erases nothing (`DriveAssessment.isRecommended`): never an erase. Fixing an
            // existing volume comes first (R7-D): ownership off on a volume that is otherwise right.
            if case .enableOwnership(let mp)? = chosen.recommendedOption, let volume = chosen.ownershipFixVolume {
                prepare.state = .next
                prepare.option = chosen.recommendedOption
                prepare.subject = volume.volumeName
                prepare.note = .turnOnOwnership(volume: volume.volumeName)
                prepare.action = .showInFinder(path: mp)
                prepare.secondaryAction = .copyOwnershipCommand(mountPoint: mp)
            } else if let option = chosen.recommendedOption {
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
        } else if chooseDone, let chosen, let candidate, let uuid = candidate.volumeUUID {
            register.state = .next
            register.subject = candidate.volumeName
            register.action = .useDrive(diskID: chosen.disk.id, volumeUUID: uuid)
            if let fixable { register.note = .secondVault(existing: fixable.volume.volumeName) }
        } else if prepare.state == .next, case .turnOnOwnership(let volume)? = prepare.note {
            register.state = .blocked(.ownershipFirst(volume))
        } else if prepare.state == .next {
            register.state = .blocked(.addVolumeFirst)
        } else {
            register.state = .blocked(.needsEarlierStep)
        }

        // 4. Move what can move. No step-level button: each item has its own.
        let items = moveItems(report: report, vault: good, locations: locations, parked: parked)
        var move = step(.moveItems)
        move.items = items.map { item in
            var i = item
            // Without a vault nothing can go to it yet; deleting needs none.
            if good == nil && i.outcome != .deletedRebuilt && i.outcome != .deletedLost { i.action = nil }
            return i
        }
        move.isExperimental = items.contains { $0.isExperimental && !$0.isDone }
        let open = items.filter { !$0.isDone }
        let headline = open.filter { !$0.losesUserData }
        move.bytes = headline.reduce(0) { add($0, $1.bytes) }
        // Items that lose the user's data never drive the step (N1): with only those left, the step is done.
        let actionable = move.items.contains { !$0.isDone && !$0.losesUserData && $0.action != nil }
        if good == nil {
            move.state = actionable ? .partly : .blocked(.needsEarlierStep)
        } else {
            move.state = actionable ? .next : .done
        }

        // 5. Check health: done when the last read found nothing that is a warning or worse.
        var health = step(.checkHealth)
        health.findingCount = findings.filter { $0.severity >= .warning }.count
        health.state = health.findingCount == 0 ? .done : .next
        health.action = .showHealth

        let summary = PlanSummary(
            upTo: headline.reduce(0) { add($0, $1.bytes) }, done: items.filter(\.isDone).reduce(0) { add($0, $1.doneBytes) },
            byOutcome: Dictionary(grouping: headline.filter { $0.bytes > 0 }, by: \.outcome).mapValues { $0.reduce(0) { add($0, $1.bytes) } },
            lostIfDeleted: open.filter(\.losesUserData).reduce(0) { add($0, $1.bytes) })
        return Plan(steps: [choose, prepare, register, move, health], summary: summary, vaultUUID: good?.volume.volumeUUID)
    }

    private static func step(_ kind: PlanStep.Kind) -> PlanStep {
        PlanStep(
            kind: kind, state: .notNeeded, subject: nil, note: nil, bytes: nil, isExperimental: false, action: nil, items: [], option: nil,
            findingCount: 0)
    }

    // MARK: - The drive

    /// A usable vault on a volume of the wrong kind — case-sensitive, or ownership ignored — whose drive has a way to a
    /// right one: a recommended fix (a new volume, or ownership on an existing one), or a right volume already there to
    /// register (R7-D: after ownership is turned on, the path still goes through that volume, not the old vault).
    static func isFixable(_ vault: VaultVolumeCheck, _ drives: [DriveAssessment]) -> Bool {
        guard let drive = drives.first(where: { $0.vault?.volume.volumeUUID == vault.volume.volumeUUID }) else { return false }
        guard let volume = drive.volumes.first(where: { $0.volumeUUID?.uppercased() == vault.volume.volumeUUID.uppercased() }) else { return false }
        return !isGoodVolume(volume) && (drive.recommendedOption != nil || registrationCandidate(drive) != nil)
    }

    /// The drive the path goes through: the good vault's; else the drive holding a vault that needs its fix (PABLO); else
    /// one that can be used; else one that needs preparation. `drives` is already ranked (`DriveEvaluation`).
    static func chosenDrive(good: VaultVolumeCheck?, fixable: VaultVolumeCheck?, drives: [DriveAssessment]) -> DriveAssessment? {
        if let good { return drives.first { $0.vault?.volume.volumeUUID == good.volume.volumeUUID } }
        if let fixable, let drive = drives.first(where: { $0.vault?.volume.volumeUUID == fixable.volume.volumeUUID }) { return drive }
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
    /// planner and the Storage chart share — split where one button does not do the whole job: DerivedData's location
    /// moves new builds only, so the DerivedData already here is its own item, deleted (F2/I1); Archives have a new-data
    /// item and an existing-data item. Plus the runtimes the whole journal shows parked (F3). Keep-local items are not in
    /// the plan; Archives are never deleted (rule 5).
    static func moveItems(report: ScanReport, vault: VaultVolumeCheck?, locations: XcodeLocations?, parked: [ParkedRuntime]) -> [PlanItem] {
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
        func option(_ id: String, _ bucket: SavingsBucket) -> SavingsOption? {
            StorageCatalog.category(id)?.savingsOptionDetails.first { $0.bucket == bucket }
        }
        var newData: [PlanItem] = []
        var rest: [PlanItem] = []

        // DerivedData: new builds go to the drive (0 bytes, done when Xcode's location is on the vault, the tests caveat
        // always shown), and the DerivedData already here is deleted and rebuilt on demand, with its bytes.
        let derivedLocal = internalBytes["derivedData"] ?? 0
        let newBuildsDone = isOnVault(locations?.derivedData, vaultMount)
        if SavingsPlanner.command(categoryID: "derivedData", bucket: .runFromExternal) != nil {
            newData.append(
                PlanItem(
                    id: "runFromExternal:derivedData", outcome: .runsFromDrive, categoryID: "derivedData", name: .newDerivedData, bytes: 0,
                    doneBytes: 0, isDone: newBuildsDone, isExperimental: option("derivedData", .runFromExternal)?.isExperimental ?? false,
                    losesUserData: false, warnings: ["derivedDataTests"],
                    action: newBuildsDone ? nil : .run(categoryID: "derivedData", bucket: .runFromExternal)))
        }
        if derivedLocal > 0 || newBuildsDone {
            let deleteOption = option("derivedData", .deleteAndRegenerate)
            rest.append(
                PlanItem(
                    id: "deleteAndRegenerate:derivedData", outcome: .deletedRebuilt, categoryID: "derivedData", name: .oldDerivedData,
                    bytes: derivedLocal, doneBytes: 0, isDone: derivedLocal == 0, isExperimental: deleteOption?.isExperimental ?? false,
                    losesUserData: false, warnings: [], action: derivedLocal == 0 ? nil : .showBucket(.deleteAndRegenerate)))
        }

        // New Archives: Xcode's Archives location, new data only (0 bytes now). Done when it is on the vault.
        if SavingsPlanner.command(categoryID: "archives", bucket: .runFromExternal) != nil {
            let done = isOnVault(locations?.archives, vaultMount)
            newData.append(
                PlanItem(
                    id: "runFromExternal:archives", outcome: .runsFromDrive, categoryID: "archives", name: .newArchives, bytes: 0, doneBytes: 0,
                    isDone: done, isExperimental: option("archives", .runFromExternal)?.isExperimental ?? false, losesUserData: false, warnings: [],
                    action: done ? nil : .run(categoryID: "archives", bucket: .runFromExternal)))
        }

        let order: [SavingsBucket] = [.runFromExternal, .parkExternally, .deleteAndRegenerate]
        let ids = bucketOf.keys.filter { $0 != "derivedData" }.sorted { a, b in
            let (ba, bb) = (order.firstIndex(of: bucketOf[a]!) ?? 9, order.firstIndex(of: bucketOf[b]!) ?? 9)
            if ba != bb { return ba < bb }
            let (sa, sb) = (internalBytes[a] ?? 0, internalBytes[b] ?? 0)
            return sa != sb ? sa > sb : a < b
        }
        var moved: [PlanItem] = []
        var deleted: [PlanItem] = []
        for id in ids {
            guard let bucket = bucketOf[id], StorageCatalog.category(id) != nil else { continue }
            let bytes = internalBytes[id] ?? 0
            let onVault = vaultBytes[id] ?? 0
            let opt = option(id, bucket)
            let outcome = outcome(categoryID: id, bucket: bucket, losesUserData: opt?.losesUserData ?? false)
            var item = PlanItem(
                id: bucket.rawValue + ":" + id, outcome: outcome, categoryID: id, name: id == "archives" ? .existingArchives : .category(id),
                bytes: bytes, doneBytes: onVault, isDone: false, isExperimental: opt?.isExperimental ?? false,
                losesUserData: opt?.losesUserData ?? false, warnings: [], action: nil)
            switch outcome {
            case .runsFromDrive: item.isDone = false
            case .movedToDrive, .parkedOnDrive: item.isDone = bytes == 0 && onVault > 0
            case .deletedRebuilt, .deletedLost: item.isDone = false
            }
            if bytes == 0 && !item.isDone { continue }
            item.action = item.isDone ? nil : action(categoryID: id, bucket: bucket)
            if outcome == .deletedRebuilt || outcome == .deletedLost { deleted.append(item) } else { moved.append(item) }
        }
        // Runtimes the whole journal shows parked now: done, each once, with their recorded installer size.
        let parkedItems = parked.map { r in
            PlanItem(
                id: "parked:" + r.operationID, outcome: .parkedOnDrive, categoryID: "simulatorRuntimeAssets", name: .parkedRuntime(r.name),
                bytes: 0, doneBytes: r.bytes ?? 0, isDone: true, isExperimental: true, losesUserData: false, warnings: [], action: nil)
        }
        return newData + moved + parkedItems + rest + deleted
    }

    /// The outcome of an item counted in `bucket`: the kinds the user asked to tell apart.
    public static func outcome(categoryID: String, bucket: SavingsBucket, losesUserData: Bool = false) -> PlanOutcome {
        switch bucket {
        case .runFromExternal: .runsFromDrive
        case .parkExternally: categoryID == "archives" ? .movedToDrive : .parkedOnDrive
        case .deleteAndRegenerate, .keepLocal: losesUserData ? .deletedLost : .deletedRebuilt
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

    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (v, o) = a.addingReportingOverflow(b)
        return o ? .max : v
    }
}
