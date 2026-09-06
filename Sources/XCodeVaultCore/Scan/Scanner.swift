import Foundation

/// Produces a `ScanReport`: environment, Xcodes, runtimes, devices, volumes and the catalog
/// resolved against the filesystem. Read-only. Sizes are `du -x` semantics (see `DiskUsage`).
public struct Scanner: Sendable {
    public var runner: CommandRunning
    public var home: String
    public var catalog: [StorageCategory]
    public var measureSizes: Bool
    public var detectXcodeCapabilities: Bool

    public init(
        runner: CommandRunning = ProcessCommandRunner(), home: String = NSHomeDirectory(),
        catalog: [StorageCategory] = StorageCatalog.all, measureSizes: Bool = true,
        detectXcodeCapabilities: Bool = true
    ) {
        self.runner = runner; self.home = home; self.catalog = catalog
        self.measureSizes = measureSizes; self.detectXcodeCapabilities = detectXcodeCapabilities
    }

    public func scan() -> ScanReport {
        var warnings: [String] = []
        let host = HostEnvironment.discover(runner: runner, home: home)
        let xcodes = XcodeDiscovery.discover(runner: runner, detectCapabilities: detectXcodeCapabilities)
        if xcodes.isEmpty { warnings.append("No Xcode installation found in /Applications or via xcode-select.") }
        var runtimes: [SimulatorRuntime] = []
        var devices: [SimulatorDevice] = []
        do { runtimes = try SimulatorDiscovery.runtimes(runner: runner) } catch { warnings.append("simctl runtime list failed: \(error)") }
        do { devices = try SimulatorDiscovery.devices(runner: runner) } catch { warnings.append("simctl list devices failed: \(error)") }
        var volumes: [Volume] = []
        do { volumes = try VolumeDiscovery.mountedVolumes(runner: runner) } catch { warnings.append("diskutil enumeration failed: \(error)") }

        let items = resolveItems()
        let summary = summarize(items: items, runtimes: runtimes)

        // Disclose-don't-bury warnings (NON_GOALS_AND_SAFETY.md).
        if host.dataVolumeFreeBytes < 40 * 1_000_000_000 {
            warnings.append(
                "Only \(ByteCount.format(host.dataVolumeFreeBytes)) free on the internal volume. Installing a simulator runtime needs internal staging space (reported ~40 GB) even when the installer is stored externally (E11)."
            )
        }
        if !host.isAppleSilicon {
            warnings.append("Intel Mac: `-architectureVariant arm64` does not apply; runtime downloads are universal.")
        }
        for r in runtimes where r.mountPath != nil && !r.isMounted && r.state == "Ready" {
            warnings.append(
                "Runtime \(r.runtimeIdentifier ?? r.identifier) reports Ready but its image is not mounted at \(r.mountPath!) — Xcode may not see it (F1).")
        }
        return ScanReport(
            generatedAt: Date(), toolVersion: XCodeVaultVersion.current, catalogVersion: StorageCatalog.version,
            host: host, xcodes: xcodes, runtimes: runtimes, devices: devices, volumes: volumes,
            items: items, summary: summary, warnings: warnings)
    }

    /// Resolves every catalog path template on this machine. Sizes are measured in parallel.
    public func resolveItems() -> [StorageItem] {
        let bootFS = MountStatus.filesystem(containing: home)?.mountPoint
        var pending: [(String, String)] = []
        for c in catalog { for t in c.pathTemplates { pending.append((c.id, t.expandingTilde(home: home))) } }
        let results = ConcurrentResults<StorageItem>(count: pending.count)
        DispatchQueue.concurrentPerform(iterations: pending.count) { i in
            let (cid, path) = pending[i]
            results[i] = resolve(categoryID: cid, path: path, bootMountPoint: bootFS)
        }
        return results.values.compactMap { $0 }
    }

    func resolve(categoryID: String, path: String, bootMountPoint: String?) -> StorageItem {
        var st = stat()
        let exists = lstat(path, &st) == 0
        let isLink = exists && (st.st_mode & S_IFMT) == S_IFLNK
        let target = isLink ? (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) : nil
        let isMount = exists && !isLink && MountStatus.isMountPoint(path)
        let fs = exists ? MountStatus.filesystem(containing: path) : nil
        let usage = (exists && measureSizes) ? DiskUsage.measure(path) : nil
        return StorageItem(
            categoryID: categoryID, path: path, exists: exists, isSymlink: isLink, symlinkTarget: target,
            isMountPoint: isMount, usage: usage, volumeMountPoint: fs?.mountPoint,
            onBootVolume: fs != nil && fs?.mountPoint == bootMountPoint)
    }

    func summarize(items: [StorageItem], runtimes: [SimulatorRuntime]) -> ScanSummary {
        var s = ScanSummary()
        for item in items where item.exists && !item.isSymlink {
            guard let c = StorageCatalog.category(item.categoryID) ?? catalog.first(where: { $0.id == item.categoryID }) else { continue }
            let bytes = item.allocatedBytes
            if item.usage?.isLowerBound == true { s.lowerBound = true }
            if item.onBootVolume { s.internalDeveloperBytes += bytes }
            if c.isRelocatable { s.relocatableBytes += bytes }
            if c.isCleanable { s.cleanableBytes += bytes }
            if c.allowedStrategies.contains(.coldStorage) { s.coldStorageEligibleBytes += bytes }
            if c.recommendedStrategy == .appleManaged { s.appleManagedBytes += bytes }
            if c.recommendedStrategy == .neverMove { s.mustRemainLocalBytes += bytes }
            if item.onBootVolume && (c.isCleanable || c.isRelocatable) {
                s.estimatedInternalSavingsBytes += bytes
                if !c.isExperimental { s.verifiedSavingsBytes += bytes }
            }
        }
        s.runtimeImageBytes = runtimes.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        return s
    }
}

/// Fixed-size result slot array for `concurrentPerform` (each index written by exactly one iteration).
final class ConcurrentResults<T: Sendable>: @unchecked Sendable {
    private var storage: [T?]
    private let lock = NSLock()
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    subscript(i: Int) -> T? {
        get { lock.withLock { storage[i] } }
        set { lock.withLock { storage[i] = newValue } }
    }
    var values: [T?] { lock.withLock { storage } }
}
