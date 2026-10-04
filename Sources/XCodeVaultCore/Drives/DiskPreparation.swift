import Foundation

// R6 (ADR-0012): preparing an external drive — add an APFS volume, add an APFS partition in free space, erase one
// volume, or erase the whole disk — as a plan the user previews, then a run that re-checks everything first.
//
// EXPERIMENTAL (CLAUDE.md rule 10). H17 measured these exact `diskutil` verbs without sudo on disk images only. The run
// never asks for a password and never escalates: a command that fails is reported with the command to copy instead.
//
// Rules this file enforces (NON_GOALS_AND_SAFETY, brief §4):
//   - every change is refused by `DiskSafety` on an internal, boot, disk-image, Time Machine or read-only disk, and every
//     erase also on a disk holding a registered vault — at planning AND again right before the command runs;
//   - an erase needs the exact name typed (`confirmationAccepted`) and lists every volume it destroys;
//   - the run re-reads the disks and refuses unless the disk is still the one previewed (`DiskIdentity`);
//   - nothing is chained: one plan runs one command;
//   - the argv is built from a closed set of verbs; the only user text in it is a validated volume name.

/// The new volume's settings (brief §3's form).
public struct VolumeConfiguration: Sendable, Equatable, Codable {
    public var name: String
    /// Off by default and recommended off: macOS is case-insensitive, and so is the data that comes from it.
    public var caseSensitive: Bool
    /// Adding a volume only: the most the new volume may use of the container (`-quota`), in whole gigabytes.
    public var quotaGigabytes: Int?

    public static let defaultName = "XCodeVault"

    public init(name: String = VolumeConfiguration.defaultName, caseSensitive: Bool = false, quotaGigabytes: Int? = nil) {
        self.name = name; self.caseSensitive = caseSensitive; self.quotaGigabytes = quotaGigabytes
    }

    /// The `diskutil` file system personality.
    public var personality: String { caseSensitive ? "Case-sensitive APFS" : "APFS" }

    /// Why the settings cannot be used, in English; empty when they can. A name is passed to `diskutil` as one argument,
    /// never through a shell, but one starting with `-` would be read as an option.
    public func problems(for action: DiskPreparationAction) -> [String] {
        var out: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { out.append("Give the volume a name.") }
        if trimmed != name { out.append("The name cannot start or end with a space.") }
        if name.hasPrefix("-") || name.hasPrefix(".") { out.append("The name cannot start with “-” or “.”.") }
        // Every Unicode control (Cc: C0, DEL, C1) and format character (Cf: bidi overrides, zero-width spaces): a name the
        // confirmation shows must be the name diskutil writes, with nothing invisible or reordering in it.
        let invisible = name.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
        if name.contains(where: { $0 == ":" || $0 == "/" }) || invisible {
            out.append("The name cannot contain “:”, “/”, control or invisible formatting characters.")
        }
        if name.utf8.count > 255 { out.append("The name is too long.") }
        if let q = quotaGigabytes {
            if action != .addVolume { out.append("A size limit applies only to a new volume in an existing container.") }
            if q < 1 { out.append("The size limit must be at least 1 GB.") }
        }
        return out
    }
}

public enum DiskPreparationAction: String, Sendable, Codable, CaseIterable {
    case addVolume, addPartition, eraseVolume, eraseDisk

    public var erases: Bool { self == .eraseVolume || self == .eraseDisk }
}

/// A volume an erase destroys, as the confirmation lists it.
public struct DestroyedVolume: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// Bytes in use, when known (an APFS volume's `CapacityInUse`, a mounted volume's used space).
    public var usedBytes: UInt64?
}

/// Exactly what the confirmation runs.
public struct DiskPreparationPlan: Sendable, Equatable, Codable {
    public var action: DiskPreparationAction
    /// The device the command names: the container, the partition the new one follows, the volume, or the disk.
    public var target: String
    /// The disk as previewed; the run refuses if the disk at `identity.wholeDisk` no longer matches.
    public var identity: DiskIdentity
    public var configuration: VolumeConfiguration
    /// Every volume the command destroys; empty for adding a volume or a partition.
    public var destroys: [DestroyedVolume]
    /// What the user must type to enable the destructive button; nil when nothing is erased.
    public var confirmationName: String?
    /// `diskutil` arguments, built from the closed set of verbs below.
    public var arguments: [String]
    /// What `target` IS, as previewed (M2): its UUID — the APFS volume's or container's, else the partition's volume or
    /// partition UUID — and its name. `revalidate` re-derives both from the fresh disks and refuses if either changed, so a
    /// volume deleted and re-added under the same device id is not the one the user confirmed.
    public var targetUUID: String?
    public var targetName: String

    /// The command, quoted for Terminal: what **Copy Command** copies and what the sheet shows.
    public var command: String { (["diskutil"] + arguments).map(DiskPreparation.shellQuoted).joined(separator: " ") }
}

public struct DiskPreparationError: DescribedError, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// How a preparation ended well.
public struct DiskPreparationOutcome: Sendable, Equatable {
    public var plan: DiskPreparationPlan
    /// The journal operation id.
    public var journalID: String
}

public enum DiskPreparation {
    // MARK: - Planning

    /// The plan for `option` on the assessed drive. Throws when the option is not one the assessment offers, when the
    /// settings are not valid, or when `DiskSafety` refuses — the same checks `revalidate` repeats before the run.
    public static func plan(
        _ option: PreparationOption, configuration: VolumeConfiguration, on assessment: DriveAssessment, snapshot: DriveSnapshot,
        registeredVaultUUIDs: Set<String>
    ) throws -> DiskPreparationPlan {
        guard assessment.options.contains(option) else { throw DiskPreparationError("This option is not offered for this drive.") }
        let disk = assessment.disk
        let action: DiskPreparationAction
        let target: String
        switch option {
        case .addVolume(let c):
            action = .addVolume
            target = c
        case .addPartition(let after, _):
            action = .addPartition
            target = after
        case .eraseVolume(let v, _):
            action = .eraseVolume
            target = v
        case .eraseDisk(let d):
            action = .eraseDisk
            target = d
        case .enableOwnership:
            throw DiskPreparationError("Ownership is turned on in Finder's Get Info, or with `sudo diskutil enableOwnership`; XCodeVault runs nothing for it.")
        }
        let problems = configuration.problems(for: action)
        guard problems.isEmpty else { throw DiskPreparationError(problems.joined(separator: " ")) }
        try refuseUnsafe(action, target: target, disk: disk, snapshot: snapshot, registeredVaultUUIDs: registeredVaultUUIDs)
        let destroys = destroyedVolumes(action, target: target, disk: disk, snapshot: snapshot)
        let facts = targetFacts(target, on: disk)
        return DiskPreparationPlan(
            action: action, target: target, identity: disk.identity, configuration: configuration, destroys: destroys,
            confirmationName: confirmationName(action, target: target, disk: disk, destroys: destroys),
            arguments: arguments(action, target: target, configuration: configuration), targetUUID: facts.uuid, targetName: facts.name)
    }

    /// The target's UUID and name on `disk`: an APFS volume, a container, a partition, or the disk itself (whose identity
    /// is `DiskIdentity`, so its UUID is nil and its name the media name).
    public static func targetFacts(_ target: String, on disk: PhysicalDisk) -> (uuid: String?, name: String) {
        if let v = disk.containers.flatMap(\.volumes).first(where: { $0.id == target }) { return (v.uuid?.uppercased(), v.name) }
        if let c = disk.containers.first(where: { $0.reference == target }) { return (c.uuid?.uppercased(), "") }
        if let p = disk.partitions.first(where: { $0.id == target }) { return ((p.volumeUUID ?? p.diskUUID)?.uppercased(), p.volumeName ?? "") }
        return (nil, disk.mediaName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The `diskutil` arguments. A closed set: these four verb shapes, and nothing else, ever reach `diskutil` from R6.
    public static func arguments(_ action: DiskPreparationAction, target: String, configuration c: VolumeConfiguration) -> [String] {
        switch action {
        case .addVolume:
            return ["apfs", "addVolume", target, c.personality, c.name] + (c.quotaGigabytes.map { ["-quota", "\($0)g"] } ?? [])
        case .addPartition:
            // Size 0: the rest of the gap after `target` (E-diskprep). APFS makes the partition's container too.
            return ["addPartition", target, c.personality, c.name, "0"]
        case .eraseVolume:
            return ["eraseVolume", c.personality, c.name, target]
        case .eraseDisk:
            return ["eraseDisk", c.personality, c.name, "GPT", target]
        }
    }

    /// What must be typed to enable an erase: the volume's name for one volume, the disk's media name for the whole disk —
    /// the names the confirmation shows. A nameless one falls back to its device id, which is shown too.
    static func confirmationName(_ action: DiskPreparationAction, target: String, disk: PhysicalDisk, destroys: [DestroyedVolume]) -> String? {
        switch action {
        case .addVolume, .addPartition: return nil
        case .eraseVolume: return destroys.first.map { $0.name.isEmpty ? $0.id : $0.name } ?? target
        case .eraseDisk:
            let media = disk.mediaName.trimmingCharacters(in: .whitespacesAndNewlines)
            return media.isEmpty ? disk.id : media
        }
    }

    /// Whether the typed text enables the destructive button: exactly the name, case included; surrounding spaces from a
    /// paste are ignored. Always true when nothing is erased.
    public static func confirmationAccepted(typed: String, plan: DiskPreparationPlan) -> Bool {
        guard let name = plan.confirmationName else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines) == name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func destroyedVolumes(_ action: DiskPreparationAction, target: String, disk: PhysicalDisk, snapshot: DriveSnapshot) -> [DestroyedVolume] {
        func used(_ id: String) -> UInt64? {
            if let v = disk.containers.flatMap(\.volumes).first(where: { $0.id == id }) { return v.usedBytes }
            if let m = snapshot.volumes.first(where: { DriveSnapshot.deviceID($0.deviceNode) == id }), m.totalBytes >= m.freeBytes {
                return m.totalBytes - m.freeBytes
            }
            return nil
        }
        func name(_ id: String) -> String {
            disk.containers.flatMap(\.volumes).first { $0.id == id }?.name ?? disk.partitions.first { $0.id == id }?.volumeName ?? ""
        }
        switch action {
        case .addVolume, .addPartition:
            return []
        case .eraseVolume:
            // Erasing an APFS volume erases that volume; erasing a partition erases the file system on it.
            return [DestroyedVolume(id: target, name: name(target), usedBytes: used(target))]
        case .eraseDisk:
            return disk.volumeIDs.map { DestroyedVolume(id: $0, name: name($0), usedBytes: used($0)) }
        }
    }

    /// The guard, for one action on one target: the target must be on `disk`, and `DiskSafety` must allow the change.
    static func refuseUnsafe(
        _ action: DiskPreparationAction, target: String, disk: PhysicalDisk, snapshot: DriveSnapshot, registeredVaultUUIDs: Set<String>
    ) throws {
        guard disk.contains(target) else { throw DiskPreparationError("\(target) is not on \(disk.id).") }
        switch action {
        case .addVolume:
            guard disk.containers.contains(where: { $0.reference == target }) else {
                throw DiskPreparationError("\(target) is not an APFS container on \(disk.id).")
            }
        case .addPartition:
            guard disk.isGPT, disk.partitions.contains(where: { $0.id == target }) else {
                throw DiskPreparationError("\(target) is not a partition of a GUID partition map on \(disk.id).")
            }
        case .eraseVolume:
            guard disk.volumeIDs.contains(target) else { throw DiskPreparationError("\(target) is not a volume of \(disk.id).") }
        case .eraseDisk:
            guard target == disk.id else { throw DiskPreparationError("\(target) is not the whole disk \(disk.id).") }
        }
        let refusals = DiskSafety.refusals(for: action, target: target, on: disk, in: snapshot, registeredVaultUUIDs: registeredVaultUUIDs)
        guard refusals.isEmpty else {
            throw DiskPreparationError("Refused: " + refusals.map(\.reason).joined(separator: " ") + " Nothing was changed.")
        }
    }

    // MARK: - Running

    /// Re-checks `plan` against a fresh snapshot (brief §4): the disk at the planned id is still the same disk — same
    /// media name, size and partition UUIDs — the target is still on it, and `DiskSafety` still allows the change.
    public static func revalidate(_ plan: DiskPreparationPlan, current: DriveSnapshot, registeredVaultUUIDs: Set<String>) throws {
        guard let disk = current.disks.first(where: { $0.id == plan.identity.wholeDisk }) else {
            throw DiskPreparationError("\(plan.identity.wholeDisk) is no longer connected. Nothing was changed.")
        }
        guard disk.identity == plan.identity else {
            throw DiskPreparationError(
                "The disk changed: \(plan.identity.wholeDisk) is not the disk that was previewed (its name, size, partitions or volumes "
                    + "differ). Nothing was changed — check the drive and preview again.")
        }
        try refuseUnsafe(plan.action, target: plan.target, disk: disk, snapshot: current, registeredVaultUUIDs: registeredVaultUUIDs)
        // The target itself, and the name the user typed, re-derived from the fresh disks (M2).
        let facts = targetFacts(plan.target, on: disk)
        guard facts.uuid == plan.targetUUID, facts.name == plan.targetName else {
            throw DiskPreparationError(
                "The disk changed: \(plan.target) is no longer the volume that was previewed. Nothing was changed — preview again.")
        }
        let fresh = confirmationName(
            plan.action, target: plan.target, disk: disk, destroys: destroyedVolumes(plan.action, target: plan.target, disk: disk, snapshot: current))
        guard fresh == plan.confirmationName else {
            throw DiskPreparationError("The disk changed: its name is no longer “\(plan.confirmationName ?? "")”. Nothing was changed — preview again.")
        }
        guard plan.arguments == arguments(plan.action, target: plan.target, configuration: plan.configuration),
            plan.configuration.problems(for: plan.action).isEmpty
        else { throw DiskPreparationError("The prepared command does not match its plan. Nothing was changed.") }
    }

    /// Runs one plan: journal the plan, read the disks again and `revalidate`, run the ONE `diskutil` command, journal
    /// how it ended. `confirmedName` is what the user typed; an erase refuses without the exact name, whatever the caller
    /// decided. Never chains a second command; never retries with privileges.
    public static func execute(
        _ plan: DiskPreparationPlan, confirmedName: String, runner: CommandRunning, journal: Journal, registeredVaultUUIDs: () throws -> Set<String>,
        snapshot: () throws -> DriveSnapshot
    ) throws -> DiskPreparationOutcome {
        guard confirmationAccepted(typed: confirmedName, plan: plan) else {
            throw DiskPreparationError("The name typed does not match “\(plan.confirmationName ?? "")”. Nothing was changed.")
        }
        let id = UUID().uuidString
        let detail = ["action": plan.action.rawValue, "disk": plan.identity.wholeDisk, "target": plan.target, "command": plan.command]
        try journal.record(id: id, kind: .diskPreparation, state: .planned, summary: summary(plan), paths: [], detail: detail)
        do {
            try revalidate(plan, current: try snapshot(), registeredVaultUUIDs: try registeredVaultUUIDs())
        } catch {
            _ = try? journal.record(id: id, kind: .diskPreparation, state: .failed, summary: "refused before running: \(error)", paths: [], detail: detail)
            throw error
        }
        try journal.record(id: id, kind: .diskPreparation, state: .started, summary: summary(plan), paths: [], detail: detail)
        let result: CommandResult
        do {
            result = try runner.run(Tools.diskutil, plan.arguments)
        } catch {
            _ = try? journal.record(id: id, kind: .diskPreparation, state: .failed, summary: "could not run diskutil: \(error)", paths: [], detail: detail)
            throw DiskPreparationError("Could not run diskutil: \(error). To try it yourself in Terminal:\n\(plan.command)")
        }
        guard result.succeeded else {
            let why =
                [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "exit \(result.status)"
            _ = try? journal.record(
                id: id, kind: .diskPreparation, state: .failed, summary: "diskutil failed (exit \(result.status)): \(why.prefix(200))", paths: [],
                detail: detail)
            throw DiskPreparationError(
                "diskutil failed (exit \(result.status)): \(why)\nXCodeVault did not retry and did not ask for a password. "
                    + "To run it yourself in Terminal:\n\(plan.command)")
        }
        try journal.record(id: id, kind: .diskPreparation, state: .completed, summary: "done: " + summary(plan), paths: [], detail: detail)
        return DiskPreparationOutcome(plan: plan, journalID: id)
    }

    /// The journal's one-line record (English, never translated).
    public static func summary(_ plan: DiskPreparationPlan) -> String {
        let name = plan.configuration.name
        return switch plan.action {
        case .addVolume: "add APFS volume \(name) to \(plan.target) on \(plan.identity.wholeDisk) (\(plan.identity.mediaName))"
        case .addPartition: "add APFS partition \(name) after \(plan.target) on \(plan.identity.wholeDisk) (\(plan.identity.mediaName))"
        case .eraseVolume: "erase volume \(plan.target) as \(plan.configuration.personality) \(name) on \(plan.identity.wholeDisk) (\(plan.identity.mediaName))"
        case .eraseDisk: "erase disk \(plan.identity.wholeDisk) (\(plan.identity.mediaName)) as GUID + \(plan.configuration.personality) \(name)"
        }
    }

    /// Single-quoted for a POSIX shell when the word needs it.
    public static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=@%+:,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Ownership (d): never run, only explained

    /// The command for Terminal; it needs root, which the app never asks for (ADR-0012).
    public static func enableOwnershipCommand(mountPoint: String) -> String {
        "sudo diskutil enableOwnership " + shellQuoted(mountPoint)
    }
}
