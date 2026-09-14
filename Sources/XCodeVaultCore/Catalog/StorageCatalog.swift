import Foundation

/// The seeded catalog. Every entry carries an evidence pointer or is `unverified` (and therefore
/// experimental). Paths and facts below were **observed on macOS 26.6.2 / Xcode 26.5** (E1 evidence)
/// and cross-checked with docs/research/FINDINGS-2026-09-05.md; older Xcodes may differ — the
/// scanner reports what exists rather than assuming.
public enum StorageCatalog {
    public static let version = "2026-09-13.1"

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
            notes: [
                "Relocate via Xcode ▸ Settings ▸ Locations (IDECustomDerivedDataLocation).",
                "Known caveat: framework unit tests may fail to load from an external volume (F4/H6) — the scanner warns before you point DerivedData at external storage.",
            ]),
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
            pathTemplates: [
                "~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport",
                "~/Library/Developer/Xcode/xrOS DeviceSupport",
            ],
            description:
                "Per-OS-build symbol caches copied from connected physical devices. Re-created on next connection (Xcode 26.5 also has `xcodebuild -prepareDeviceSupport`).",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .high,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup],
            evidence: "E8 evidence (xcodebuild -prepareDeviceSupport on 26.5); community consensus (DevCleaner)", evidenceStatus: .probable,
            notes: [
                "Deleting old OS builds you no longer debug is the classic safe win. Keep the builds of devices you still use to avoid a multi-minute re-copy."
            ]),
        StorageCategory(
            id: "previews", name: "SwiftUI Preview data", subsystem: .previews,
            pathTemplates: ["~/Library/Developer/Xcode/UserData/Previews/Simulator Devices"],
            description: "The SwiftUI Previews simulator device set (emptied with `simctl --set … delete all`, never rm).", regenerability: .regenerable,
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
            evidence: "H5/F3 + E9 (2026-09-08): symlinking ~/Library/Developer/CoreSimulator is unsupported — the Aug 2025 Files-app breakage did not reproduce on macOS 26.6.2/Xcode 26.5, but the layout leaves shadow device sets behind",
            evidenceStatus: .probable,
            notes: [
                "No relocation strategy at any risk level. Unconditional (CLAUDE.md rule 7) — not contingent on E9, which has now run without reproducing the reported breakage; the rule stands on 'unverified, and known to produce shadow data'.",
                "Never deleted through the filesystem: `simctl delete <udid>` removes one device; `simctl erase` frees its data without deleting it.",
                "`simctl delete unavailable` is PERMANENT and is not a cleanup step. A device is unavailable whenever its runtime is off the machine — including a runtime XCodeVault offloaded on purpose, which comes back with its devices intact on re-import. Check `xcodevaultctl doctor`, which reads the journal and refuses to suggest deletion while an offloaded installer exists or the vault is merely unplugged.",
            ],
            // Was `xcrun simctl delete unavailable`, which `clean` printed verbatim on every run —
            // the same permanent, unconditional advice `doctor` was corrected for, reaching the user
            // through a second door. "Unavailable" is not a synonym for disposable: a device is
            // unavailable whenever its runtime is off the machine, including one XCodeVault offloaded
            // on purpose. The per-device form is kept instead: it is still the official tool and
            // still delete-only, but it names what is being destroyed and cannot sweep up a device
            // the user is about to get back.
            cleanupCommand: "xcrun simctl delete <udid>"),

        // ───── Regenerable data *inside* each device (F18, F22) ─────
        // The three largest user-owned, root-free targets on a developer's machine. Reported per
        // device rather than as one number, because devices are independently disposable — and
        // declared `isBreakdownOf: "simulatorDevices"`, because these bytes are a decomposition of
        // that category rather than storage on top of it.
        //
        // None is offered to `clean`, for three different reasons that the notes on each spell out:
        // the dead containers because the system already collects them, the MobileAsset payloads
        // because deleting them is a write behind the daemon that keeps their records, and the log
        // store because its documented narrow verb is one we have not reproduced. No `simctl` verb
        // reclaims any of them narrowly, so any surgical deletion would be of our own design — and
        // none of these notes may answer that by naming a destructive command instead. See the
        // comment on the dead-container hint below for why that last sentence is there.
        StorageCategory(
            id: "simulatorDeadContainers", name: "Dead app containers (per device)", subsystem: .coreSimulator,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"],
            description:
                "Bundle containers of apps that were replaced or uninstalled, moved aside by containermanagerd. One `temp.XXXXXX` entry per superseded install; on this machine each was ~125 MB, dominated by the app's `.debug.dylib`.",
            regenerability: .regenerable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            evidence:
                "F22 (2026-09-13): a booted device reaped 19 of 19 pre-existing entries (1.5 GB → 306 MB) in a single sweep while a shutdown sibling stayed byte-identical at 676 MB; the three entries created just before the sweep were still present an hour later",
            evidenceStatus: .verified,
            notes: [
                "Never cleaned by us, and this is a conclusion rather than a hesitation: the system already does it. Measured 2026-09-13 — a booted device went from 15 entries / 1.5 GB to 3 / 306 MB, while a shutdown sibling did not change by a single byte over the same hours.",
                "What is NOT known is the cadence, and an earlier draft of this note overclaimed it. The sweep was a single bulk event, not a rolling timer: it removed everything that predated it, and the three entries created shortly before it were still there an hour later, untouched. So the honest statement is `booting gets it collected`, not `booting collects it within N minutes`. Do not promise a schedule this evidence does not show.",
                "What the size therefore means is the opposite of what it looks like: a large number here is not a leak to reclaim, it is a device that has not been booted lately. Deleting it would buy the user nothing they were not already going to get, while racing the daemon that owns the directory on any device that is running.",
                "The 2026-09-13 measurement is an observation with a control, not a controlled experiment: an `xcodebuild test` was driving the booted device for part of the window. It cannot separate containermanagerd's own timer from something the test triggered — but a test run only *adds* entries (four appeared mid-window and were reaped with the rest), and the untouched shutdown device is the control that makes the direction unambiguous.",
                "This is not `simctl erase` territory. Erasing reclaims this and destroys every app, setting and container on the device with it; the point of the category is that this part is separable — and, as it turns out, self-reclaiming.",
            ],
            perDeviceSubpaths: ["data/Library/Caches/com.apple.containermanagerd/Dead"],
            // No remediation — the same answer the other two give, and now for the same reason.
            //
            // Two drafts of this hint were wrong in opposite ways. The first named
            // `simctl delete <udid>`, which is permanent, journal-blind device-deletion advice on an
            // INFO finding that lists devices largest-first — the third time this repo has had to
            // remove that pattern (see `clean`'s note above, and `checkUnavailableDevices`, the one
            // rule allowed to say it and only from a journal-verified state). The second said "boot
            // the device and the system reclaims it", inferred from a sweep that followed a boot;
            // the same device, left booted for three hours after, accumulated 2 GB and reaped none
            // of it. Nil is what is left, and it is the accurate answer rather than a fallback: the
            // space does come back, on a schedule we have not characterised, and there is nothing a
            // user can do to bring it forward.
            isBreakdownOf: "simulatorDevices"),
        StorageCategory(
            id: "simulatorMobileAssets", name: "In-simulator MobileAsset downloads (per device)", subsystem: .mobileAsset,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"],
            description:
                "Assets downloaded by the simulated OS from inside the device — Siri understanding and text-to-speech models, linguistic data, ContextKit. Distinct from the host-side runtime asset store (`simulatorRuntimeAssets`), which holds the runtime image itself.",
            regenerability: .redownloadable, deletionRisk: .high, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            evidence:
                "F22 (2026-09-13): 3.3 GB across two devices; on one, `UAF_Siri_Understanding` 767 MB + `UAF_Siri_TextToSpeech` 496 MB + `LinguisticData` 264 MB, each a `<sha1>.asset` bundle under `AssetsV2/`",
            evidenceStatus: .probable,
            notes: [
                "Reported, not cleaned, and the risk here is higher than for Dead containers. `mobileassetd` inside the simulator keeps its own bookkeeping beside the payloads (`AssetsV2/analytics`, and per-type state); deleting the payloads from the host is a write behind the back of the daemon that owns the records — the same shape of mistake F16 documents on the host side.",
                "Redownloadable is not free: reclaiming this costs a network round trip per asset the simulator next asks for, on Apple's schedule rather than the user's.",
            ],
            perDeviceSubpaths: ["data/private/var/MobileAsset"], isBreakdownOf: "simulatorDevices"),
        StorageCategory(
            id: "simulatorLogStore", name: "Simulated unified log store (per device)", subsystem: .coreSimulator,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"],
            description:
                "The simulated OS's own unified-log datastore and the symbolication table that goes with it. Written continuously by a booted device, whether or not anyone reads it.",
            regenerability: .regenerable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            evidence: "F18 (2026-09-09): 1.2 GB of `db/diagnostics` + 0.3 GB of `db/uuidtext` across three devices",
            evidenceStatus: .probable,
            notes: [
                "Reported, not cleaned — but for a different reason than the other two: here a documented narrower verb *does* exist. `man log` defines `log erase --all`, runnable inside a device with `simctl spawn`. We have not reproduced it (F18), and an unreproduced verb is not a product feature.",
                "Deleting the datastore from the host instead of through `log` would be the same mistake as for MobileAsset: writing behind a daemon that holds the file open on a booted device.",
            ],
            perDeviceSubpaths: ["data/var/db/diagnostics", "data/var/db/uuidtext"], isBreakdownOf: "simulatorDevices"),

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
            description:
                "Root-owned dyld shared caches built per runtime when simulators boot. Observed at 7.4 GB on one Xcode 26.5 machine (E1), 9.4 GiB on another. "
                + "Rebuilt on next boot — so deleting a cache whose runtime is installed buys a slow first boot, not free space. The exception is a cache whose "
                + "runtime was removed: nothing rebuilds that, and nothing reclaimed it over more than a day of uptime (F10) — whether a restart does is untested. "
                + "`doctor` reports those separately. A cache for an older macOS build should be dead too, but none has been observed, so that stays conjecture.",
            regenerability: .regenerable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup], privilege: .root,
            evidence: nil,
            notes: [
                "Cleanup requires the privileged helper (M3). Until a functional probe (boot after delete) is recorded in the matrix this stays experimental.",
                "Do NOT infer root-deletability from the absence of SIP flags: the stranded Inbox file had no BSD flags and was absent from rootless.conf either, and root still got EPERM — a restart reclaimed it (F1 2026-09-06, F10). The next probe here is a reboot, not sudo.",
            ]),
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
            description:
                "Sealed runtime bundles installed via simctl runtime add / -importPlatform. On Xcode 26.5 with MobileAsset-delivered runtimes this directory is empty (E1).",
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
            pathTemplates: [
                "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
                "/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime",
                "/System/Library/AssetsV2/com_apple_MobileAsset_tvOSSimulatorRuntime",
                "/System/Library/AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime",
                "/System/Library/AssetsV2/com_apple_MobileAsset_visionOSSimulatorRuntime",
            ],
            description:
                "Where the runtime gigabytes actually live on Xcode 26 (E1: 100% of installed runtime bytes on the test machine). Behind a /System path but on the Data volume. Managed by mobileassetd + simdiskimaged.",
            regenerability: .redownloadable, deletionRisk: .medium, relocationRisk: .critical,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged], privilege: .root,
            evidence: "E1 evidence file (simctl runtime list -j paths); F1 [COMMUNITY-REPRO]", evidenceStatus: .verified,
            notes: [
                "Delete runtimes only with `xcrun simctl runtime delete <id>`; never touch the asset files directly (CLAUDE.md rule 2).",
                "Keep installers on external storage instead (Runtime Library: `-downloadPlatform … -exportPath` + `-importPlatform`).",
                "`doctor` flags assets present here that no runtime references (orphaned NeverCollected assets, F1).",
            ],
            cleanupCommand: "xcrun simctl runtime delete <identifier>"),

        // ───────────── Runtime Library (external, ours) ─────────────
        StorageCategory(
            id: "runtimeLibrary", name: "Runtime Library (external installers)", subsystem: .coreSimulator,
            pathTemplates: [],
            description:
                "Runtime installer .dmg files exported with `xcodebuild -downloadPlatform <p> -exportPath <dir>` and re-installed with `-importPlatform`. Apple's supported way to keep multi-GB runtimes off the internal disk.",
            regenerability: .redownloadable, deletionRisk: .low, relocationRisk: .low,
            recommendedStrategy: .downloadRepository, allowedStrategies: [.downloadRepository, .restoreOnDemand],
            evidence: "F2 [APPLE-DOC]; E8 evidence (flags present on Xcode 26.5)", evidenceStatus: .probable, minimumXcodeMajor: 14,
            notes: [
                "Installing a 9–25 GB runtime needs internal staging space (~2–3× the image, reported ~40 GB) — E11.",
                "`-architectureVariant arm64` shrinks downloads on Apple Silicon; not applicable on Intel Macs.",
            ]),

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
