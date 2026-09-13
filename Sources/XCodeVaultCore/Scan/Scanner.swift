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

        let items = resolveItems(warnings: &warnings)
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
        var ignored: [String] = []
        return resolveItems(warnings: &ignored)
    }

    /// - Parameter warnings: receives a line for every device set that exists but could not be
    ///   enumerated. Without this the two cases "no per-device data" and "the device set is a
    ///   symlink to a vault that is unplugged" render identically — several GB leave the report with
    ///   nothing on screen to say so. Failing closed is right (rule 6); failing closed *quietly* is
    ///   the thing NON_GOALS lists under Never.
    func resolveItems(warnings: inout [String]) -> [StorageItem] {
        let bootFS = MountStatus.filesystem(containing: home)?.mountPoint
        var pending: [(String, String)] = []
        for c in catalog {
            for t in c.pathTemplates {
                let root = t.expandingTilde(home: home)
                guard !c.perDeviceSubpaths.isEmpty else { pending.append((c.id, root)); continue }
                // Per-device categories resolve to one item inside each device, never to the device
                // set itself — reporting the set would hide which device the bytes belong to, and the
                // devices are independently disposable.
                let (devices, enumerationError) = Scanner.deviceRoots(in: root)
                if let enumerationError {
                    warnings.append(
                        "\(root) exists but could not be read (\(enumerationError)); per-device storage there is missing from this report, not absent.")
                }
                for device in devices {
                    for sub in c.perDeviceSubpaths { pending.append((c.id, device + "/" + sub)) }
                }
            }
        }
        let results = ConcurrentResults<StorageItem>(count: pending.count)
        DispatchQueue.concurrentPerform(iterations: pending.count) { i in
            let (cid, path) = pending[i]
            results[i] = resolve(categoryID: cid, path: path, bootMountPoint: bootFS)
        }
        return results.values.compactMap { $0 }
    }

    /// Device directories directly inside a device set, by filesystem enumeration rather than
    /// `simctl`: the bytes are on disk whether or not the daemon will talk to us, and a scan that
    /// depended on `simctl` would under-report exactly when the user most needs the number.
    ///
    /// Only UUID-shaped names are accepted. CoreSimulator names every device directory after its
    /// UDID, so this loses nothing real, and it is what keeps a category that carries a
    /// `perDeviceSubpath` from wandering into a sibling directory someone happened to leave here.
    /// - Returns: the device roots, and a description of why enumeration failed when it did. A
    ///   device set that simply is not there is not a failure and reports no error; one that exists
    ///   and cannot be read is, and the caller turns that into a user-visible warning.
    static func deviceRoots(in deviceSet: String) -> (roots: [String], error: String?) {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: deviceSet) } catch {
            var st = stat()
            let present = lstat(deviceSet, &st) == 0
            return ([], present ? (error as NSError).localizedDescription : nil)
        }
        return (
            names
            .filter { isDeviceUDID($0) }
            .sorted()
            .map { deviceSet + "/" + $0 }
            .filter { var st = stat(); return lstat($0, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR }, nil)
    }

    /// 8-4-4-4-12 hex, the form CoreSimulator gives device directories.
    ///
    /// Case-insensitive on purpose. CoreSimulator writes these uppercase, but the two failure modes
    /// are not symmetric: rejecting a lowercase UUID would silently drop a real device's bytes from
    /// the accounting, which is this tool's whole job, while accepting one opens nothing — the names
    /// this guard exists to exclude ("Backup", "old-devices") are not hex either way.
    static func isDeviceUDID(_ name: String) -> Bool {
        let groups = name.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
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
            // A breakdown category's bytes are already inside its parent's total. Counting them here
            // too would inflate every headline by the size of the slice — over-reporting, which is
            // exactly as wrong as under-reporting and harder to notice, because the number only
            // looks bigger. The per-item lines still list them.
            guard c.isBreakdownOf == nil else { continue }
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
