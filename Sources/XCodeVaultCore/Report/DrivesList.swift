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
    /// The row is the running system's volume group (the System volume and its Data sibling, or either alone): the app
    /// names it "Internal disk (boot)" instead of a volume name.
    public let isBootGroup: Bool
    /// `VolumeQualification.evaluate(volume)`: for the boot group, the boot blocker once, not once per member.
    public let qualification: VolumeQualification
    /// The registered vault this volume is, matched by volume UUID: shown as a badge on the row, never as a second row.
    public let vault: VaultVolumeCheck?

    public var id: String { volume.id }

    /// The vault badge's SF Symbol: a checkmark when the vault is usable, an exclamation mark when it is mounted and not
    /// usable. Always shown with the state's words, never alone.
    public var vaultSymbolName: String? {
        guard let vault else { return nil }
        return vault.isUsable ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    /// Long warnings (IOPS, case-sensitivity) start folded behind a one-line count; blockers are always shown.
    public var warningsStartCollapsed: Bool { !qualification.warnings.isEmpty }
}

public struct DrivesList: Sendable, Equatable {
    public let rows: [DriveRow]
    /// Registered vaults whose volume is not among the mounted ones: the only vaults with a section of their own.
    public let offlineVaults: [VaultVolumeCheck]
    /// No vault is registered at all: the screen says how to register one.
    public let hasNoVaults: Bool

    /// The scan's volumes in their order, except that the running system's volumes on one APFS container become one row,
    /// in the place of the first of them. A volume belongs to that group when it is the boot volume (`isBootVolume`),
    /// internal, and on the same container as the group's other members (`containerKey`); no volume name is looked at.
    public static func make(volumes: [Volume], checks: [VaultVolumeCheck]) -> DrivesList {
        var groups: [String: [Volume]] = [:]
        for v in volumes where isBootGroupMember(v) { groups[containerKey(v.deviceNode), default: []].append(v) }
        var rows: [DriveRow] = []
        var emitted = Set<String>()
        var matched = Set<String>()
        func vault(for v: Volume) -> VaultVolumeCheck? {
            guard let uuid = v.volumeUUID, let check = checks.first(where: { $0.volume.volumeUUID == uuid }) else { return nil }
            matched.insert(uuid)
            return check
        }
        for v in volumes {
            if isBootGroupMember(v) {
                let key = containerKey(v.deviceNode)
                guard !emitted.contains(key), let members = groups[key] else { continue }
                emitted.insert(key)
                let shown = representative(of: members)
                rows.append(
                    DriveRow(
                        volume: shown, members: members, isBootGroup: true, qualification: VolumeQualification.evaluate(shown), vault: vault(for: shown)))
            } else {
                rows.append(DriveRow(volume: v, members: [v], isBootGroup: false, qualification: VolumeQualification.evaluate(v), vault: vault(for: v)))
            }
        }
        let offline = checks.filter { !matched.contains($0.volume.volumeUUID) }
        return DrivesList(rows: rows, offlineVaults: offline, hasNoVaults: checks.isEmpty)
    }

    static func isBootGroupMember(_ v: Volume) -> Bool { v.isBootVolume && v.isInternal }

    /// The APFS container a volume lives in, from its device node: `/dev/disk3s5` → `disk3`, the container's synthesized
    /// disk that all its volumes share — the sealed system snapshot `/dev/disk3s1s1` included. A node that is not
    /// `disk<N>…` is its own key.
    public static func containerKey(_ deviceNode: String) -> String {
        let name = deviceNode.split(separator: "/").last.map(String.init) ?? deviceNode
        guard name.hasPrefix("disk") else { return name }
        let digits = name.dropFirst(4).prefix(while: \.isNumber)
        return digits.isEmpty ? name : "disk" + digits
    }

    /// The Data volume of the group: the member mounted at `/System/Volumes/Data` (the path macOS mounts it at, not a
    /// name), else the one that is not mounted at `/`, else the first.
    static func representative(of members: [Volume]) -> Volume {
        members.first { $0.mountPoint == "/System/Volumes/Data" } ?? members.first { $0.mountPoint != "/" } ?? members[0]
    }
}
