import Foundation

/// The seeded catalog. Every entry carries an evidence pointer or is `unverified` (and therefore
/// experimental). Paths and facts below were **observed on macOS 26.6.2 / Xcode 26.5** (E1 evidence)
/// and cross-checked with docs/research/FINDINGS-2026-09-05.md; older Xcodes may differ — the
/// scanner reports what exists rather than assuming.
public enum StorageCatalog {
    public static let version = "2026-09-06.1"

    public static let all: [StorageCategory] = [
        // ───────────── Xcode IDE (user domain) ─────────────
        StorageCategory(
            id: "derivedData", name: "DerivedData", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Developer/Xcode/DerivedData"],
            description: "Build intermediates, products, indexes, module caches, SourcePackages checkouts. Fully regenerable by building again.",
            regenerability: .regenerable, deletionRisk: .low, relocationRisk: .medium,
            recommendedStrategy: .nativeConfiguration,
            allowedStrategies: [.nativeConfiguration, .safeCleanup],
            evidence: "F2 (Apple DTS: DerivedData/Archives/Compilation Cache are the supported relocatable set); E2/H6 for external-volume caveat",
            evidenceStatus: .probable,
            notes: ["Relocate via Xcode ▸ Settings ▸ Locations (IDECustomDerivedDataLocation).",
                    "Known caveat: framework unit tests may fail to load from an external volume (F4/H6) — the scanner warns before you point DerivedData at external storage."]),
        StorageCategory(
            id: "archives", name: "Archives", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Developer/Xcode/Archives"],
            description: "Xcode archives (.xcarchive) with dSYMs — the only copy of shipped symbol files. Non-regenerable.",
            regenerability: .nonRegenerable, deletionRisk: .critical, relocationRisk: .low,
            recommendedStrategy: .nativeConfiguration,
            allowedStrategies: [.nativeConfiguration, .coldStorage],
            evidence: "F2 (Apple DTS: supported relocation via Locations)", evidenceStatus: .probable,
            notes: ["Never auto-deleted. Relocate via Xcode ▸ Settings ▸ Locations, or cold-store with verified copy."]),
        StorageCategory(
            id: "deviceSupport", name: "Device Support symbols", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                            "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport",
                            "~/Library/Developer/Xcode/xrOS DeviceSupport"],
            description: "Per-OS-build symbol caches copied from connected physical devices. Re-created on next connection (Xcode 26.5 also has `xcodebuild -prepareDeviceSupport`).",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .high,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "E8 evidence (xcodebuild -prepareDeviceSupport on 26.5); community consensus (DevCleaner)", evidenceStatus: .probable,
            notes: ["Deleting old OS builds you no longer debug is the classic safe win. Keep the builds of devices you still use to avoid a multi-minute re-copy."]),
        StorageCategory(
            id: "previews", name: "SwiftUI Preview data", subsystem: .previews,
            pathTemplates: ["~/Library/Developer/Xcode/UserData/Previews"],
            description: "Preview simulator devices and caches.", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .high, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus (DevCleaner)", evidenceStatus: .probable),
        StorageCategory(
            id: "xcodePackages", name: "Xcode component packages", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Developer/Packages"],
            description: "Apple-documented cache written by `xcodebuild -runFirstLaunch -checkForNewerComponents`. Almost no cleanup tool knows it exists.",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .medium,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "F2 [APPLE-DOC] downloading-and-installing-additional-xcode-components", evidenceStatus: .probable),
        StorageCategory(
            id: "xcodeCaches", name: "Xcode caches", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Caches/com.apple.dt.Xcode"],
            description: "IDE caches (documentation, symbol index caches).", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .medium, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus (DevCleaner, ClearDisk)", evidenceStatus: .probable),
        StorageCategory(
            id: "deviceLogs", name: "Device logs", subsystem: .xcodeIDE,
            pathTemplates: ["~/Library/Developer/Xcode/DeviceLogs", "~/Library/Logs/CoreSimulator"],
            description: "Crash/console logs from devices and simulators.", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .low, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus", evidenceStatus: .probable),

        // ───────────── Swift Package Manager ─────────────
        StorageCategory(
            id: "swiftPMCaches", name: "SwiftPM caches", subsystem: .swiftPM,
            pathTemplates: ["~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm"],
            description: "Package repository clones, manifest and artifact caches.", regenerability: .redownloadable,
            deletionRisk: .low, relocationRisk: .medium, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus", evidenceStatus: .probable),

        // ───────────── CoreSimulator (user domain) ─────────────
        StorageCategory(
            id: "simulatorDevices", name: "Simulator devices", subsystem: .coreSimulator,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"],
            description: "Per-device data containers (apps, user data, caches). Delete unwanted devices with `simctl delete`; never symlink this tree.",
            regenerability: .userRecreatable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            evidence: "H5/F3 (symlinking ~/Library/Developer/CoreSimulator breaks the Simulator even same-disk)", evidenceStatus: .probable,
            notes: ["No relocation strategy at any risk level until E9 says otherwise (CLAUDE.md rule 7).",
                    "Never deleted through the filesystem: `simctl delete unavailable` removes devices whose runtime is gone; `simctl delete <udid>` removes one; `simctl erase` frees data without deleting the device."],
            cleanupCommand: "xcrun simctl delete unavailable"),
        StorageCategory(
            id: "simulatorUserCaches", name: "Simulator user caches", subsystem: .coreSimulator,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Caches", "~/Library/Developer/CoreSimulator/Temp"],
            description: "Per-user simulator caches (dyld caches per runtime) and temp files.", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .critical, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus", evidenceStatus: .probable),
        StorageCategory(
            id: "xctestDevices", name: "XCTest devices", subsystem: .xctest,
            pathTemplates: ["~/Library/Developer/XCTestDevices"],
            description: "Clone devices created for parallel testing.", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .high, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus", evidenceStatus: .probable),
        StorageCategory(
            id: "playgroundDevices", name: "Playground devices", subsystem: .playgrounds,
            pathTemplates: ["~/Library/Developer/XCPGDevices"],
            description: "Simulator devices used by Playgrounds.", regenerability: .regenerable,
            deletionRisk: .low, relocationRisk: .high, recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "community consensus", evidenceStatus: .probable),

        // ───────────── CoreSimulator (system domain, root) ─────────────
        StorageCategory(
            id: "coreSimulatorSystemCaches", name: "CoreSimulator system dyld caches", subsystem: .coreSimulator,
            pathTemplates: ["/Library/Developer/CoreSimulator/Caches/dyld"],
            description: "Root-owned dyld shared caches built per runtime when simulators boot. Observed at 7.4 GB on one Xcode 26.5 machine (E1). Rebuilt on next boot.",
            regenerability: .regenerable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup], privilege: .root,
            evidence: nil,
            notes: ["Cleanup requires the privileged helper (M3). Until a functional probe (boot after delete) is recorded in the matrix this stays experimental."]),
        StorageCategory(
            id: "runtimeInbox", name: "Runtime download staging (Inbox)", subsystem: .coreSimulator,
            pathTemplates: ["/Library/Developer/CoreSimulator/Cryptex/Images/Inbox", "/Library/Developer/CoreSimulator/Images/Inbox"],
            description: "In-flight runtime downloads. Anything left here after a failed install is stranded multi-GB garbage (F1).",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .high,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged], privilege: .root,
            evidence: "F1 [COMMUNITY-REPRO]; E1 layout confirmed (empty on a healthy install)", evidenceStatus: .probable,
            notes: ["`doctor` reports stranded .dmg files here; removal is a helper verb in M3."]),
        StorageCategory(
            id: "runtimeBundles", name: "Runtime bundles (Cryptex store)", subsystem: .coreSimulator,
            pathTemplates: ["/Library/Developer/CoreSimulator/Cryptex/Images/bundle"],
            description: "Sealed runtime bundles installed via simctl runtime add / -importPlatform. On Xcode 26.5 with MobileAsset-delivered runtimes this directory is empty (E1).",
            regenerability: .redownloadable, deletionRisk: .high, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged], privilege: .root,
            evidence: "F1; E1", evidenceStatus: .probable,
            notes: ["Manage only with `xcrun simctl runtime delete`. Apple DTS: never with Disk Utility or manual unmounts."]),
        StorageCategory(
            id: "runtimeMounts", name: "Runtime mount points", subsystem: .coreSimulator,
            pathTemplates: ["/Library/Developer/CoreSimulator/Volumes"],
            description: "Mount points for sealed runtime images managed by simdiskimaged. Not storage — a mount graft.",
            regenerability: .regenerable, deletionRisk: .critical, relocationRisk: .critical,
            recommendedStrategy: .neverMove, allowedStrategies: [.neverMove], privilege: .root,
            evidence: "F1; E1 (two nested mounts observed)", evidenceStatus: .verified, isMountGraft: true),
        StorageCategory(
            id: "simulatorRuntimeAssets", name: "Simulator runtime images (MobileAsset store)", subsystem: .mobileAsset,
            pathTemplates: ["/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
                            "/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime",
                            "/System/Library/AssetsV2/com_apple_MobileAsset_tvOSSimulatorRuntime",
                            "/System/Library/AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime",
                            "/System/Library/AssetsV2/com_apple_MobileAsset_visionOSSimulatorRuntime"],
            description: "Where the runtime gigabytes actually live on Xcode 26 (E1: 100% of installed runtime bytes on the test machine). Behind a /System path but on the Data volume. Managed by mobileassetd + simdiskimaged.",
            regenerability: .redownloadable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged], privilege: .root,
            evidence: "E1 evidence file (simctl runtime list -j paths); F1 [COMMUNITY-REPRO]", evidenceStatus: .verified,
            notes: ["Delete runtimes only with `xcrun simctl runtime delete <id>`; never touch the asset files directly (CLAUDE.md rule 2).",
                    "Keep installers on external storage instead (Runtime Library: `-downloadPlatform … -exportPath` + `-importPlatform`).",
                    "`doctor` flags assets present here that no runtime references (orphaned NeverCollected assets, F1)."],
            cleanupCommand: "xcrun simctl runtime delete <identifier>"),

        // ───────────── Runtime Library (external, ours) ─────────────
        StorageCategory(
            id: "runtimeLibrary", name: "Runtime Library (external installers)", subsystem: .coreSimulator,
            pathTemplates: [],
            description: "Runtime installer .dmg files exported with `xcodebuild -downloadPlatform <p> -exportPath <dir>` and re-installed with `-importPlatform`. Apple's supported way to keep multi-GB runtimes off the internal disk.",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .low,
            recommendedStrategy: .downloadRepository, allowedStrategies: [.downloadRepository, .restoreOnDemand],
            evidence: "F2 [APPLE-DOC]; E8 evidence (flags present on Xcode 26.5)", evidenceStatus: .probable, minimumXcodeMajor: 14,
            notes: ["Installing a 9–25 GB runtime needs internal staging space (~2–3× the image, reported ~40 GB) — E11.",
                    "`-architectureVariant arm64` shrinks downloads on Apple Silicon; not applicable on Intel Macs."]),

        // ───────────── Device support / CoreDevice ─────────────
        StorageCategory(
            id: "developerDiskImages", name: "Developer Disk Images", subsystem: .coreDevice,
            pathTemplates: ["/Library/Developer/DeveloperDiskImages", "~/Library/Developer/DeveloperDiskImages"],
            description: "DDIs for physical-device debugging. Must remain real directories (FB12363725).",
            regenerability: .redownloadable, deletionRisk: .high, relocationRisk: .critical,
            recommendedStrategy: .neverMove, allowedStrategies: [.neverMove],
            evidence: "F3/H2 FB12363725", evidenceStatus: .probable),
        StorageCategory(
            id: "coreDevice", name: "CoreDevice data", subsystem: .coreDevice,
            pathTemplates: ["/Library/Developer/CoreDevice", "~/Library/Developer/CoreDevice"],
            description: "Physical-device pairing and CoreDevice state.", regenerability: .userRecreatable,
            deletionRisk: .high, relocationRisk: .critical, recommendedStrategy: .neverMove, allowedStrategies: [.neverMove],
            evidence: "F3 (symlinking breaks device discovery)", evidenceStatus: .probable),

        // ───────────── Toolchains ─────────────
        StorageCategory(
            id: "toolchains", name: "Alternative toolchains", subsystem: .toolchain,
            pathTemplates: ["~/Library/Developer/Toolchains", "/Library/Developer/Toolchains"],
            description: "User-installed Swift toolchains (.xctoolchain). Managed by the user; re-downloadable from swift.org.",
            regenerability: .redownloadable, deletionRisk: .medium, relocationRisk: .high,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            evidence: "swift.org install docs", evidenceStatus: .probable),
        StorageCategory(
            id: "commandLineTools", name: "Command Line Tools", subsystem: .commandLineTools,
            pathTemplates: ["/Library/Developer/CommandLineTools"],
            description: "Apple Command Line Tools package. Reinstall with `xcode-select --install`.",
            regenerability: .redownloadable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged], privilege: .root,
            evidence: "Apple docs", evidenceStatus: .probable),
    ]

    public static func category(_ id: String) -> StorageCategory? { all.first { $0.id == id } }
}
