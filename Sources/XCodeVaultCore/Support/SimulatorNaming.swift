import Foundation

/// How CoreSimulator names things on disk, in one place.
///
/// This lived as a private helper on `Scanner` until 2026-09-15, when a safety review found the
/// rule restated by omission somewhere else: `StorageCategory.containsPath` treated *any* single
/// directory name as "the device", so a hand-made `Backup 2026-09-01` sitting in the device set
/// satisfied containment for a per-device category, and from there reached a deletion path. The
/// scanner had always been stricter. Two definitions of "is this a device" is the duplication that
/// keeps producing this repository's worst bugs, so there is now one.
public enum SimulatorNaming {
    /// 8-4-4-4-12 hex, the form CoreSimulator gives device directories.
    ///
    /// Case-insensitive on purpose. CoreSimulator writes these uppercase, but the two failure modes
    /// are not symmetric: rejecting a lowercase UUID would silently drop a real device's bytes from
    /// the accounting, which is this tool's whole job, while accepting one opens nothing — the names
    /// this guard exists to exclude ("Backup", "old-devices") are not hex either way.
    public static func isDeviceUDID(_ name: String) -> Bool {
        let groups = name.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }
}
