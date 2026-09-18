import Foundation

/// A registered external volume. Identity is the APFS volume UUID plus a sentinel file we wrote;
/// the mount point is only where we last saw it (MIGRATION_ENGINE.md §Split-brain safety).
public struct VaultVolume: Sendable, Codable, Equatable, Identifiable {
    public init(
        volumeUUID: String, volumeName: String, lastMountPoint: String, registeredAt: Date, sentinelID: String,
        relativeDirectory: String = VaultVolume.directoryName
    ) {
        self.volumeUUID = volumeUUID; self.volumeName = volumeName; self.lastMountPoint = lastMountPoint; self.registeredAt = registeredAt
        self.sentinelID = sentinelID; self.relativeDirectory = relativeDirectory
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeUUID = try c.decode(String.self, forKey: .volumeUUID); volumeName = try c.decode(String.self, forKey: .volumeName)
        lastMountPoint = try c.decode(String.self, forKey: .lastMountPoint); registeredAt = try c.decode(Date.self, forKey: .registeredAt)
        sentinelID = try c.decode(String.self, forKey: .sentinelID)
        relativeDirectory = try c.decodeIfPresent(String.self, forKey: .relativeDirectory) ?? VaultVolume.directoryName
    }
    public var id: String { volumeUUID }
    public var volumeUUID: String
    public var volumeName: String
    public var lastMountPoint: String
    public var registeredAt: Date
    public var sentinelID: String  // random token stored in the sentinel file
    /// Vault directory relative to the volume root. Default "XCodeVault"; volume roots are usually
    /// root-owned, so users without the privileged helper may register a subdirectory they can write.
    public var relativeDirectory: String

    /// Deliberately a literal, not a reference to `VaultDirectory.name` in
    /// `XCodeVaultHelperProtocol`: `XCodeVaultCore` is declared with no dependencies at all
    /// ("no UI, no privileged calls, no shell"), and linking the XPC contract into the domain
    /// layer to share one string would blur that. The drift this risks is caught instead by
    /// `HelperContractTests.testVaultDirectoryNameMatchesTheHelperContract`.
    /// Capital "C": on a case-sensitive volume this is a different directory from "XcodeVault".
    public static let directoryName = "XCodeVault"
    public static let sentinelName = ".xcodevault-volume.json"
    public var lastVaultDirectory: String { lastMountPoint + "/" + relativeDirectory }
    public func vaultDirectory(atMountPoint mp: String) -> String { mp + "/" + relativeDirectory }
}

public struct VaultSentinel: Sendable, Codable, Equatable {
    public var volumeUUID: String
    public var sentinelID: String
    public var createdAt: Date
    public var createdBy: String  // tool version
}

/// What we can say about a registered volume right now. `ambiguous` and `foreign` are refusal
/// states: nothing that depends on the volume may run.
public enum VaultVolumeState: String, Sendable, Codable {
    case verified  // mounted at a real mount point, UUID and sentinel match
    case absent  // nothing mounted at the last mount point and the volume is not mounted elsewhere
    case movedMountPoint  // mounted, verified, but at a different path than last time (e.g. "Name 1")
    case foreign  // something is mounted at the path but UUID/sentinel do not match
    case ambiguous  // not mounted, but the last mount point exists as a local directory with content (shadow data)
    case sentinelMissing  // right UUID but our sentinel is gone (reformatted? restored from backup?)
}

public struct VaultVolumeCheck: Sendable, Codable, Equatable {
    public var volume: VaultVolume
    public var state: VaultVolumeState
    public var currentMountPoint: String?
    public var shadowBytes: UInt64?  // bytes found at the local path when ambiguous
    public var detail: String
    public var isUsable: Bool { state == .verified || state == .movedMountPoint }
}

public struct VaultError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Registry of vault volumes, persisted as JSON next to the journal.
public struct VaultRegistry: Sendable {
    public let url: URL
    public static let defaultURL = Journal.defaultURL.deletingLastPathComponent().appendingPathComponent("volumes.json")
    public init(url: URL = VaultRegistry.defaultURL) { self.url = url }

    public func volumes() throws -> [VaultVolume] {
        // `FileManager.contents(atPath:)` returns nil for a permission error exactly as it does for
        // a missing file, so the earlier `guard let … else { return [] }` reported "no vault
        // volumes" — a clean bill of health — for an unreadable registry. `doctor` then had nothing
        // to report and exited 0. Same idiom as `Journal.read()`: check existence, then let the
        // read throw. Found by the migration-safety review of 2026-09-18, which noticed that the
        // do/catch added to `Doctor+Vault` that day could not fire for the case it was written for.
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([VaultVolume].self, from: data)
    }

    public func save(_ volumes: [VaultVolume]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(volumes).write(to: url, options: .atomic)
    }

    /// Registers a mounted, qualified volume: creates `<mount>/<relativeDirectory>/` (default
    /// `XCodeVault`) and the sentinel. Refuses unsuitable volumes, the boot volume, and any
    /// directory that escapes the volume.
    /// `isMountPoint` and `volumeUUID` are injectable for the same reason `VaultVerifier` takes a
    /// closure: without them a unit test cannot distinguish "refused by the check at the top" from
    /// "refused by the re-assertion before the write", because both use the same predicates. They
    /// also keep the happy path testable at all — the fixtures use synthetic UUIDs against a real
    /// mount point, which the identity guard below rejects by construction.
    @discardableResult
    public func register(
        _ v: Volume, relativeDirectory: String = VaultVolume.directoryName, journal: Journal = Journal(),
        isMountPoint: @Sendable (String) -> Bool = { MountStatus.isMountPoint($0) },
        volumeUUID: @Sendable (String) -> String? = { MountStatus.volumeUUID(at: $0) }
    ) throws -> VaultVolume {
        guard let mp = v.mountPoint, let uuid = v.volumeUUID else { throw VaultError("Volume has no mount point or UUID.") }
        let q = VolumeQualification.evaluate(v)
        guard q.verdict != .unsuitable else { throw VaultError("Volume \(v.volumeName) is not suitable: \(q.blockers.joined(separator: " "))") }
        guard isMountPoint(mp) else { throw VaultError("\(mp) is not a mount point.") }
        let rel = relativeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty, !rel.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw VaultError("Invalid vault directory '\(relativeDirectory)'.")
        }
        let dir = mp + "/" + rel
        guard PathSafety.isContained(dir, in: mp) else { throw VaultError("\(dir) is not inside \(mp).") }
        if rel.hasPrefix(".TemporaryItems") {
            try journal.record(
                kind: .migration, state: .planned, summary: "warning: vault directory under .TemporaryItems is not durable (macOS may purge it)", paths: [dir])
        }
        let sentinelPath = dir + "/" + VaultVolume.sentinelName
        var existing = try volumes()
        if let already = existing.first(where: { $0.volumeUUID == uuid }) {
            // Re-registration: verify the sentinel instead of overwriting it.
            let check = VaultVerifier(registry: self).check(already)
            if check.state == .verified || check.state == .movedMountPoint { return already }
            throw VaultError(
                "Volume \(uuid) is already registered but in state \(check.state.rawValue): \(check.detail). Use `vault forget` first if this is intentional.")
        }
        // Re-assert the volume BEFORE creating anything. Ordering is the whole point: with the
        // mkdir first, a guard failure left a directory behind — on the internal disk, at the
        // canonical vault path, in exactly the failure mode being guarded against — while the error
        // said "Nothing was written". Guards first make that sentence true and remove the orphan.
        //
        // What makes this safe is NOT that `isMountPoint` runs first: these are separate syscalls
        // with a gap between them, the same class of gap this code exists to close. It is that the
        // UUID check is a *positive identity assertion that fails closed*. Every degradation —
        // unmounted and the directory gone (nil), unmounted with the mount directory persisting (the
        // boot volume's UUID), a different volume mounted in its place (that volume's UUID) — fails
        // the comparison and refuses. Do not rewrite this as `if let now = …, now != uuid { throw }`:
        // that form lets nil *pass* and silently reinstates the bug.
        guard isMountPoint(mp) else {
            throw VaultError("\(mp) is no longer a mount point — the volume was unmounted during registration. Nothing was written; re-run with it mounted.")
        }
        // Read once. Re-reading it for the error message is a third syscall and a fresh race, so the
        // message could name a different volume than the one that actually failed the comparison.
        let observed = volumeUUID(mp)
        guard let nowUUID = observed else {
            throw VaultError(
                "Could not read the volume identity at \(mp) (permissions, or an I/O error) — refusing rather than guessing. Nothing was written.")
        }
        guard nowUUID.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw VaultError(
                "\(mp) is now volume \(nowUUID), not \(uuid) — a different volume was mounted here during registration. Nothing was written.")
        }

        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            throw VaultError(
                "Cannot create \(dir): \(error.localizedDescription)\n" + OwnershipAdvice.createVaultDirectory(dir))
        }
        // The directory may pre-exist (created by the privileged step, by Finder, or by a previous
        // run). Creating it is not enough — it has to be *ours*, or every later write fails in a
        // place much harder to diagnose than here.
        if let problem = OwnershipAdvice.writabilityProblem(dir) {
            // Journalled because by this point a directory may exist that we created and are now
            // refusing to use; without a record it is an orphan nothing downstream will look at.
            //
            // `try?` and not `try`: a journal write that fails here must not replace the real
            // error, which is the one the user can act on. The trade is that if the journal is
            // itself unwritable the orphan goes unrecorded — exactly the thing the paragraph above
            // says must not happen. That is the lesser of the two, and it is stated rather than
            // implied. `_ =` because discarding the result is the decision, not an oversight.
            _ = try? journal.record(kind: .migration, state: .failed, summary: "vault directory unusable: \(problem.prefix(120))", paths: [dir])
            throw VaultError(problem)
        }

        let sentinel = VaultSentinel(volumeUUID: uuid, sentinelID: UUID().uuidString, createdAt: Date(), createdBy: XCodeVaultVersion.current)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sentinel).write(to: URL(fileURLWithPath: sentinelPath), options: .atomic)
        let vv = VaultVolume(
            volumeUUID: uuid, volumeName: v.volumeName, lastMountPoint: mp, registeredAt: Date(), sentinelID: sentinel.sentinelID, relativeDirectory: rel)
        existing.append(vv)
        try save(existing)
        try journal.record(kind: .migration, state: .completed, summary: "registered vault volume \(v.volumeName) (\(uuid))", paths: [dir])
        return vv
    }

    public func forget(uuid: String) throws {
        var all = try volumes()
        all.removeAll { $0.volumeUUID == uuid }
        try save(all)
    }
}

/// Answers "is this really our volume, right now?" without trusting names or paths.
public struct VaultVerifier: Sendable {
    public var registry: VaultRegistry
    public var mountedVolumes: @Sendable () -> [Volume]
    /// Mount-point predicate; defaults to `ATTR_DIR_MOUNTSTATUS`. Injectable so tests can stand in a directory for a volume.
    public var isMountPoint: @Sendable (String) -> Bool
    public init(
        registry: VaultRegistry = VaultRegistry(), mountedVolumes: @escaping @Sendable () -> [Volume] = { (try? VolumeDiscovery.mountedVolumes()) ?? [] },
        isMountPoint: @escaping @Sendable (String) -> Bool = { MountStatus.isMountPoint($0) }
    ) {
        self.registry = registry; self.mountedVolumes = mountedVolumes; self.isMountPoint = isMountPoint
    }

    public static func readSentinel(at vaultDir: String) -> VaultSentinel? {
        guard let data = FileManager.default.contents(atPath: vaultDir + "/" + VaultVolume.sentinelName) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(VaultSentinel.self, from: data)
    }

    public func check(_ v: VaultVolume) -> VaultVolumeCheck {
        let mounted = mountedVolumes()
        // 1. Is the volume (by UUID) mounted anywhere?
        if let live = mounted.first(where: { $0.volumeUUID == v.volumeUUID }), let mp = live.mountPoint, isMountPoint(mp) {
            let sentinel = VaultVerifier.readSentinel(at: v.vaultDirectory(atMountPoint: mp))
            guard let sentinel else {
                return VaultVolumeCheck(
                    volume: v, state: .sentinelMissing, currentMountPoint: mp, shadowBytes: nil,
                    detail: "Volume \(v.volumeUUID) is mounted at \(mp) but \(v.relativeDirectory)/\(VaultVolume.sentinelName) is missing.")
            }
            guard sentinel.sentinelID == v.sentinelID, sentinel.volumeUUID == v.volumeUUID else {
                return VaultVolumeCheck(
                    volume: v, state: .foreign, currentMountPoint: mp, shadowBytes: nil,
                    detail: "Sentinel at \(mp) does not match the registry (expected \(v.sentinelID), found \(sentinel.sentinelID)).")
            }
            if mp != v.lastMountPoint {
                return VaultVolumeCheck(
                    volume: v, state: .movedMountPoint, currentMountPoint: mp, shadowBytes: nil,
                    detail: "Verified, but mounted at \(mp) instead of \(v.lastMountPoint). Absolute paths recorded earlier will not resolve.")
            }
            return VaultVolumeCheck(volume: v, state: .verified, currentMountPoint: mp, shadowBytes: nil, detail: "Mounted at \(mp); UUID and sentinel match.")
        }
        // 2. Not mounted. Is something else mounted at our last path?
        if isMountPoint(v.lastMountPoint) {
            return VaultVolumeCheck(
                volume: v, state: .foreign, currentMountPoint: v.lastMountPoint, shadowBytes: nil,
                detail: "A different volume is mounted at \(v.lastMountPoint) (our UUID \(v.volumeUUID) is not mounted).")
        }
        // 3. Not mounted. Does the last path exist as a plain local directory with content? That is shadow data.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: v.lastMountPoint, isDirectory: &isDir), isDir.boolValue {
            let usage = DiskUsage.measure(v.lastMountPoint)
            let bytes = usage?.allocatedBytes ?? 0
            let files = usage?.fileCount ?? 0
            if files > 0 {
                return VaultVolumeCheck(
                    volume: v, state: .ambiguous, currentMountPoint: nil, shadowBytes: bytes,
                    detail:
                        "\(v.lastMountPoint) exists as a local directory containing \(files) file(s), \(ByteCount.format(bytes)) — written while the volume was absent (shadow data). Refusing to proceed until reconciled."
                )
            }
        }
        return VaultVolumeCheck(
            volume: v, state: .absent, currentMountPoint: nil, shadowBytes: nil, detail: "Volume \(v.volumeName) (\(v.volumeUUID)) is not connected.")
    }

    public func checkAll() throws -> [VaultVolumeCheck] { try registry.volumes().map(check) }

    /// Resolves a user-supplied vault reference (UUID, name, or mount point) to a usable, verified volume.
    public func resolveUsable(_ ref: String) throws -> (VaultVolume, String) {
        let all = try registry.volumes()
        guard let v = all.first(where: { $0.volumeUUID == ref || $0.volumeName == ref || $0.lastMountPoint == ref }) else {
            throw VaultError("No registered vault volume matches '\(ref)'. Register one with `vault init <mount point>`.")
        }
        let c = check(v)
        guard c.isUsable, let mp = c.currentMountPoint else { throw VaultError("Vault volume \(v.volumeName) is \(c.state.rawValue): \(c.detail)") }
        return (v, v.vaultDirectory(atMountPoint: mp))
    }
}
