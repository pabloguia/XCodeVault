import Foundation

// What the app's Details screens list (spec 2026-10-03 §6.1, S4 Task 6), decided here so the views only draw it: which
// rows, in which order, and which savings bucket each storage row counts under. Nothing here is text: names and labels
// are the catalog's English (category data) or Core's records, and the app renders them.

/// One row of the Storage screen: a storage item the scan found, with its category's facts and the bucket the savings
/// model counts it under (`StorageCategory.primaryBucket`, the bucket the Overview's disk bar uses).
public struct StorageRow: Sendable, Equatable, Identifiable {
    public let item: StorageItem
    /// The catalog's English name, or the category id when the catalog does not know it.
    public let categoryName: String
    /// `StorageCategory.outcomeLabel`; empty when the catalog does not know the category.
    public let outcome: String
    /// `StorageCategory.recommendedStrategy`; nil when the catalog does not know the category.
    public let strategy: Strategy?
    public let isExperimental: Bool
    /// Nil only when the catalog does not know the category: a row is never put in a bucket by guess.
    public let bucket: SavingsBucket?

    public var id: String { item.id }
}

public enum StorageTable {
    /// The items that exist, largest first; equal sizes by path, so the order does not change between redraws.
    public static func rows(report: ScanReport) -> [StorageRow] {
        report.items.filter(\.exists)
            .sorted { ($0.allocatedBytes, $1.path) > ($1.allocatedBytes, $0.path) }
            .map { item in
                let category = report.category(for: item)
                return StorageRow(
                    item: item, categoryName: category?.name ?? item.categoryID, outcome: category?.outcomeLabel ?? "",
                    strategy: category?.recommendedStrategy, isExperimental: category?.isExperimental ?? false, bucket: category?.primaryBucket)
            }
    }
}

/// One simulator device of the Simulators screen, with the size of its data folder and the runtime it runs.
public struct SimulatorDeviceRow: Sendable, Equatable, Identifiable {
    public let device: SimulatorDevice
    /// The installed runtime's platform and version ("iOS 26.0"), or the device's runtime identifier when no installed
    /// runtime matches it (a device whose runtime was deleted).
    public let runtime: String
    /// `SimulatorDevice.dataPathSize`; nil when the scan did not measure it.
    public let bytes: UInt64?

    public var id: String { device.id }
}

public enum SimulatorsTable {
    /// The installed runtimes, largest first (unmeasured last), then by platform and version.
    public static func runtimes(report: ScanReport) -> [SimulatorRuntime] {
        report.runtimes.sorted { a, b in
            let (sa, sb) = (a.sizeBytes ?? 0, b.sizeBytes ?? 0)
            if sa != sb { return sa > sb }
            return (a.platformName, a.version ?? "", a.identifier) < (b.platformName, b.version ?? "", b.identifier)
        }
    }

    /// The devices, largest data first (unmeasured last), then by name and UDID.
    public static func devices(report: ScanReport) -> [SimulatorDeviceRow] {
        var names: [String: String] = [:]
        for runtime in report.runtimes {
            guard let id = runtime.runtimeIdentifier, names[id] == nil else { continue }
            names[id] = [runtime.platformName, runtime.version].compactMap { $0 }.joined(separator: " ")
        }
        return report.devices
            .map { SimulatorDeviceRow(device: $0, runtime: names[$0.runtimeIdentifier] ?? $0.runtimeIdentifier, bytes: $0.dataPathSize) }
            .sorted { a, b in
                let (sa, sb) = (a.bytes ?? 0, b.bytes ?? 0)
                if sa != sb { return sa > sb }
                return (a.device.name, a.device.udid) < (b.device.name, b.device.udid)
            }
    }

    /// The devices' measured data, summed: the Simulators screen's devices total.
    public static func devicesBytes(report: ScanReport) -> UInt64 {
        report.devices.reduce(UInt64(0)) { $0 + ($1.dataPathSize ?? 0) }
    }

    /// The runtimes' measured images, summed (what `ScanSummary.runtimeImageBytes` holds, recomputed from the rows shown).
    public static func runtimesBytes(report: ScanReport) -> UInt64 {
        report.runtimes.reduce(UInt64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }
}
