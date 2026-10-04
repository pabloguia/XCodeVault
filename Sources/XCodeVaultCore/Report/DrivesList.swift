import Foundation

// What the app's Drives screen lists (R1), decided here so the view only draws it: one row per drive the user would
// call a drive, the vault state on the row of the volume it lives on, and a section only for the vaults that are not
// connected. Nothing here is text: the app renders the labels.

/// One row of the Drives screen.
public struct DriveRow: Sendable, Equatable, Identifiable {
    /// The volume whose facts the row shows. For the boot volume group it is the Data volume: the one that holds the
    /// user's files and the free space the user can use.
    public let volume: Volume
    /// Every mounted volume the row stands for, `volume` among them; one, except for the boot volume group.
    public let members: [Volume]
    /// The row is the running system's volume group (the System volume at `/` and its Data sibling at
    /// `/System/Volumes/Data`, or either alone): the app names it "Internal disk (boot)" instead of a volume name.
    public let isBootGroup: Bool
    /// `VolumeQualification.evaluate(volume)`: for the boot group, the boot blocker once, not once per member.
    public let qualification: VolumeQualification
    /// The registered vault this volume is, matched by volume UUID: shown as a badge on the row, never as a second row.
    public let vault: VaultVolumeCheck?
    /// Further registry entries with the same volume UUID. `vault init` refuses a second one, so this is a damaged or
    /// hand-edited registry; the entries are shown on the row rather than dropped from the screen.
    public let duplicateVaults: [VaultVolumeCheck]

    public var id: String { volume.id }

    /// The vault badge's SF Symbol: a checkmark when the vault is usable, an exclamation mark when it is mounted and not
    /// usable. Always shown with the state's words, never alone.
    public var vaultSymbolName: String? {
        guard let vault else { return nil }
        return vault.isUsable ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    /// A mounted vault that is not usable shows its check's sentence (what is wrong, what not to do) as visible text under
    /// the row, as blockers are, not only as a tooltip; a usable vault's sentence stays in the tooltip.
    public var showsVaultDetail: Bool { vault.map { !$0.isUsable } ?? false }

    /// Long warnings (IOPS, case-sensitivity) start folded behind a one-line count; blockers are always shown.
    public var warningsStartCollapsed: Bool { !qualification.warnings.isEmpty }
}

public struct DrivesList: Sendable, Equatable {
    public let rows: [DriveRow]
    /// Registered vaults whose volume is not among the mounted ones: the only vaults with a section of their own.
    public let offlineVaults: [VaultVolumeCheck]
    /// No vault is registered at all: the screen says how to register one.
    public let hasNoVaults: Bool

    /// The scan's volumes in their order, except that the running system's volume group becomes one row, in the place of
    /// the first of its members. The group is the boot-role internal volume mounted at `/` and the one mounted at
    /// `/System/Volumes/Data` — where macOS mounts the running system, a path and not a name — when they share an APFS
    /// container (`containerKey`). Another macOS install's System or Data volume, even in the same container, is mounted
    /// elsewhere and keeps its own row. `Volume` carries no APFS volume-group UUID, so the mount points are what tie System
    /// to its Data sibling.
    public static func make(volumes: [Volume], checks: [VaultVolumeCheck]) -> DrivesList {
        let anchor = volumes.first { isRunningSystemVolume($0) && $0.mountPoint == "/" } ?? volumes.first(where: isRunningSystemVolume)
        let anchorKey = anchor.map { containerKey($0.deviceNode) }
        let members = volumes.filter { isRunningSystemVolume($0) && containerKey($0.deviceNode) == anchorKey }
        var rows: [DriveRow] = []
        var emitted = false
        var matched = Set<String>()
        func row(_ shown: Volume, members: [Volume], isBootGroup: Bool) -> DriveRow {
            var same: [VaultVolumeCheck] = []
            if let uuid = shown.volumeUUID {
                same = checks.filter { $0.volume.volumeUUID == uuid }
                if !same.isEmpty { matched.insert(uuid) }
            }
            return DriveRow(
                volume: shown, members: members, isBootGroup: isBootGroup, qualification: VolumeQualification.evaluate(shown), vault: same.first,
                duplicateVaults: Array(same.dropFirst()))
        }
        for v in volumes {
            if members.contains(v) {
                guard !emitted else { continue }
                emitted = true
                rows.append(row(representative(of: members), members: members, isBootGroup: true))
            } else {
                rows.append(row(v, members: [v], isBootGroup: false))
            }
        }
        let offline = checks.filter { !matched.contains($0.volume.volumeUUID) }
        return DrivesList(rows: rows, offlineVaults: offline, hasNoVaults: checks.isEmpty)
    }

    /// The running system's System or Data volume: boot role, internal, and mounted where macOS mounts the running system.
    static func isRunningSystemVolume(_ v: Volume) -> Bool {
        v.isBootVolume && v.isInternal && (v.mountPoint == "/" || v.mountPoint == "/System/Volumes/Data")
    }

    /// The symbol of a vault in the not-mounted section: a crossed-out drive only when it is simply absent; an exclamation
    /// mark when something is wrong (foreign volume at its path, shadow data, sentinel missing), as the state words say.
    public static func offlineSymbol(for check: VaultVolumeCheck) -> String {
        switch check.state {
        case .absent: "externaldrive.badge.xmark"
        case .verified, .movedMountPoint: "externaldrive.badge.checkmark"
        case .foreign, .ambiguous, .sentinelMissing: "externaldrive.badge.exclamationmark"
        }
    }

    /// The APFS container a volume lives in, from its device node: `/dev/disk3s5` → `disk3`, the container's synthesized
    /// disk that all its volumes share — the sealed system snapshot `/dev/disk3s1s1` included. A node that is not
    /// `disk<N>…` is its own key.
    public static func containerKey(_ deviceNode: String) -> String {
        let name = deviceNode.split(separator: "/").last.map(String.init) ?? deviceNode
        guard name.hasPrefix("disk") else { return name }
        let digits = name.dropFirst(4).prefix(while: \.isNumber)
        return digits.isEmpty ? name : "disk" + digits
    }

    /// The Data volume of the group: the member mounted at `/System/Volumes/Data`, else the only member.
    static func representative(of members: [Volume]) -> Volume {
        members.first { $0.mountPoint == "/System/Volumes/Data" } ?? members[0]
    }
}
