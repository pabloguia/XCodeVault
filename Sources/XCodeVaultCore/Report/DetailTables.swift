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
    /// The bucket the row's bytes count once in on the Storage chart (`SavingsCalculator.countedOnceBucket`); nil for a
    /// symlink, a breakdown of another row's bytes, an unknown category, or data no option applies to.
    public let countedBucket: SavingsBucket?

    /// The row's bytes are in its bucket's bar.
    public var countsInBucketTotal: Bool { countedBucket != nil }

    public var id: String { item.id }
}

public enum StorageTable {
    /// The items that exist, in `defaultSortOrder` (largest first; ties as `sorted(_:using:)` breaks them), so the
    /// table's default order and this one are the same order.
    public static func rows(report: ScanReport) -> [StorageRow] {
        let rows = report.items.filter(\.exists)
            .map { item in
                let category = report.category(for: item)
                return StorageRow(
                    item: item, categoryName: category?.name ?? item.categoryID, outcome: category?.outcomeLabel ?? "",
                    strategy: category?.recommendedStrategy, isExperimental: category?.isExperimental ?? false, bucket: category?.primaryBucket,
                    countedBucket: SavingsCalculator.countedOnceBucket(item, category: category))
            }
        return sorted(rows, using: defaultSortOrder)
    }
}

/// One simulator device of the Simulators screen, with the size of its data folder and the runtime it runs.
public struct SimulatorDeviceRow: Sendable, Equatable, Identifiable {
    public let device: SimulatorDevice
    /// The installed runtime's platform and version ("iOS 26.0", `SimulatorRuntime.platformDisplayName`), or the device's
    /// runtime identifier when no installed runtime matches it (a device whose runtime was deleted).
    public let runtime: String
    /// `SimulatorDevice.dataPathSize`; nil when the scan did not measure it.
    public let bytes: UInt64?

    public var id: String { device.id }
}

public enum SimulatorsTable {
    /// The installed runtimes in `defaultRuntimeSortOrder`: largest first (unmeasured last), ties as `sorted(_:using:)`
    /// breaks them (platform, version, identifier).
    public static func runtimes(report: ScanReport) -> [SimulatorRuntime] {
        sorted(report.runtimes, using: defaultRuntimeSortOrder)
    }

    /// The devices in `defaultDeviceSortOrder`: largest data first (unmeasured last), ties as `sorted(_:using:)` breaks
    /// them (name, UDID).
    public static func devices(report: ScanReport) -> [SimulatorDeviceRow] {
        var names: [String: String] = [:]
        for runtime in report.runtimes {
            guard let id = runtime.runtimeIdentifier, names[id] == nil else { continue }
            names[id] = [runtime.platformDisplayName, runtime.version].compactMap { $0 }.joined(separator: " ")
        }
        let rows = report.devices.map {
            SimulatorDeviceRow(device: $0, runtime: names[$0.runtimeIdentifier] ?? $0.runtimeIdentifier, bytes: $0.dataPathSize)
        }
        return sorted(rows, using: defaultDeviceSortOrder)
    }

    /// The devices' measured data, summed: the Simulators screen's devices total.
    public static func devicesBytes(report: ScanReport) -> UInt64 {
        report.devices.reduce(UInt64(0)) { $0 + ($1.dataPathSize ?? 0) }
    }

    /// The runtimes' measured images: `ScanSummary.runtimeImageBytes`, the one number the scanner stores. The Overview's
    /// runtime line and the Simulators screen both read it here, so they can never disagree.
    public static func runtimesBytes(report: ScanReport) -> UInt64 {
        report.summary.runtimeImageBytes
    }

    /// The height a table on the Simulators screen is given (R1): its header plus every row, so it never scrolls inside
    /// the screen's one scroll view and never asks for more than its rows. Points; at least one row's worth, so an empty
    /// table still shows its header. `rowHeight` and `headerHeight` are macOS's default `Table` metrics with a little room.
    public static func fittedTableHeight(rowCount: Int, rowHeight: Double = 24, headerHeight: Double = 28) -> Double {
        headerHeight + Double(max(rowCount, 1)) * rowHeight + 2
    }
}

extension SimulatorRuntime {
    /// The platform as Apple names it — iOS, watchOS, tvOS, visionOS — from `platformIdentifier`
    /// (`com.apple.platform.iphonesimulator` → iOS). A platform this does not know keeps `platformName`, the identifier's
    /// short form; a runtime simctl gave no platform for shows "?", as a missing version does.
    public var platformDisplayName: String {
        guard platformIdentifier != nil else { return "?" }
        return switch platformName {
        case "iphone": "iOS"
        case "watch": "watchOS"
        case "appletv": "tvOS"
        case "xr": "visionOS"
        case "macosx", "macos": "macOS"
        default: platformName
        }
    }
}
