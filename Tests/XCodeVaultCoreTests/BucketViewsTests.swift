import XCTest

@testable import XCodeVaultCore

/// What the app's Delete, Park and Run-externally views show (S4 Task 4), decided in Core.
final class BucketViewsTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func item(_ id: String, _ bytes: UInt64) -> StorageItem {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        return StorageItem(
            categoryID: id, path: "/fixture/\(id)/\(bytes)", exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false,
            usage: usage, volumeMountPoint: nil, onBootVolume: true)
    }

    private func action(_ id: String, _ bytes: UInt64, path: String? = nil, root: Bool = false, experimental: Bool = false) -> CleanAction {
        CleanAction(
            categoryID: id, categoryName: StorageCatalog.category(id)?.name ?? id, path: path ?? "/fixture/\(id)/\(bytes)", bytes: bytes,
            isExperimental: experimental, risk: .low, requiresRoot: root, notes: [])
    }

    private func device(_ udid: String) -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: "iPhone", runtimeIdentifier: "r", state: "Shutdown", isAvailable: true)
    }

    private func report(_ items: [StorageItem], devices: [SimulatorDevice] = []) -> ScanReport {
        var r = Fixtures.minimalReport()
        r.items = items
        r.devices = devices
        return r
    }

    // MARK: - Delete

    /// Rule 5, at the view's own guard: a plan that somehow carried Archives still does not list them.
    func testTheDeleteListNeverListsArchives() {
        let r = report([item("archives", 9_000), item("derivedData", 100)])
        let forged = CleanPlan(actions: [action("archives", 9_000), action("derivedData", 100)], skipped: [], warnings: [])
        let list = DeleteList.make(plan: forged, report: r)
        XCTAssertEqual(list.groups.map(\.categoryID), ["derivedData"])
        XCTAssertFalse(list.otherTools.contains { $0.categoryID == "archives" })
        XCTAssertEqual(list.deletable(selected: Set(forged.actions.map(\.id))).map(\.categoryID), ["derivedData"])
        // And through the real planner, as the app builds it.
        let planned = DeleteList.make(plan: CleanPlanner(home: "/nonexistent").plan(report: r, granular: false), report: r)
        XCTAssertFalse(planned.groups.contains { $0.categoryID == "archives" })
        XCTAssertFalse(planned.groups.isEmpty, "the control category is listed")
    }

    /// Review I2 / LOW-2: the view fails closed on its own. Devices and runtimes (another tool's), and an id the catalog
    /// does not know, never become deletable rows, whatever a plan carries; the other-tool rows still list devices.
    func testAForgedPlanCannotMakeDevicesRuntimesOrUnknownCategoriesDeletable() {
        let r = report([item("simulatorDevices", 6_000), item("simulatorRuntimeAssets", 4_000)], devices: [device("A")])
        let forged = CleanPlan(
            actions: [
                action("simulatorDevices", 6_000), action("simulatorRuntimeAssets", 4_000), action("noSuchCategory", 5_000),
                action("derivedData", 100),
            ], skipped: [], warnings: [])
        let list = DeleteList.make(plan: forged, report: r)
        XCTAssertEqual(list.groups.map(\.categoryID), ["derivedData"])
        XCTAssertEqual(list.deletable(selected: Set(forged.actions.map(\.id))).map(\.categoryID), ["derivedData"])
        XCTAssertNil(list.undo(of: action("noSuchCategory", 5_000)), "no default undo cost for an unknown id")
        XCTAssertEqual(Set(list.otherTools.map(\.categoryID)), ["simulatorDevices", "simulatorRuntimeAssets"])
        // The planner agrees: neither devices nor runtimes are ever in a clean plan.
        let planned = CleanPlanner(home: "/nonexistent").plan(report: r, granular: false)
        XCTAssertFalse(planned.actions.contains { ["simulatorDevices", "simulatorRuntimeAssets"].contains($0.categoryID) })
    }

    /// LOW-1: after a rescan only rows still listed stay selected.
    func testARescanKeepsOnlyTheSelectedRowsStillListed() {
        let a = action("derivedData", 100, path: "/d/a"), b = action("derivedData", 50, path: "/d/b")
        let list = DeleteList.make(plan: CleanPlan(actions: [a], skipped: [], warnings: []), report: report([]))
        XCTAssertEqual(list.retained([a.id, b.id, "/gone"]), [a.id])
        XCTAssertEqual(list.retained([]), [])
    }

    /// Simulator devices go through `simctl`: the clean planner never plans them, and the list shows them with that
    /// command and the data-loss marker, outside the deletable groups.
    func testSimulatorDevicesAreListedWithSimctlAndAreNotDeletableHere() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let r = report([item("simulatorDevices", 6_000), item("derivedData", 100)], devices: [device("A"), device("B")])
        let plan = CleanPlanner(home: "/nonexistent").plan(report: r, granular: false)
        XCTAssertFalse(plan.actions.contains { $0.categoryID == "simulatorDevices" }, "the clean planner never plans devices")
        let list = DeleteList.make(plan: plan, report: r)
        XCTAssertFalse(list.groups.contains { $0.categoryID == "simulatorDevices" })
        let devices = list.otherTools.first { $0.categoryID == "simulatorDevices" }
        XCTAssertEqual(devices?.command, "xcrun simctl delete <udid>")
        // Experimental because the category's evidence is not verified (rule 10 reaches this row too).
        XCTAssertEqual(devices.map(SavingsMarker.markers(for:)), [.experimental, .losesUserData, .actsImmediately, .perItem(2)])
        XCTAssertFalse(list.otherTools.contains { $0.command.hasPrefix("xcodevaultctl clean ") }, "clean's rows are the table's")
        XCTAssertEqual(
            list.otherTools, SavingsPlanner.rows(report: r, bucket: .deleteAndRegenerate).filter { !$0.command.hasPrefix("xcodevaultctl clean ") })
    }

    func testGroupsAreByCategoryLargestFirstWithTheirCostToUndo() {
        let plan = CleanPlan(
            actions: [action("derivedData", 500, path: "/d/a"), action("deviceSupport", 700), action("derivedData", 400, path: "/d/b")], skipped: [],
            warnings: [])
        let list = DeleteList.make(plan: plan, report: report([]))
        XCTAssertEqual(list.groups.map(\.categoryID), ["derivedData", "deviceSupport"], "900 before 700")
        XCTAssertEqual(list.groups.first?.bytes, 900)
        XCTAssertEqual(list.groups.first?.actions.map(\.path), ["/d/a", "/d/b"], "the plan's order within a group")
        XCTAssertEqual(list.groups.first?.undo, StorageCatalog.category("derivedData")?.regenerability)
        XCTAssertEqual(list.undo(of: plan.actions[1]), StorageCatalog.category("deviceSupport")?.regenerability)
        XCTAssertNil(list.undo(of: action("archives", 1)))
    }

    /// The exact-count rule: what the confirmation counts is what is deleted — selected, listed, not root-owned.
    func testDeletableIsTheSelectedRowsThatDoNotNeedRoot() {
        let dyld = action("coreSimulatorSystemCaches", 3_000, path: PrivilegeRequirement.coreSimulatorDyldCachePath, root: true, experimental: true)
        let derived = action("derivedData", 100)
        let support = action("deviceSupport", 50)
        let list = DeleteList.make(plan: CleanPlan(actions: [dyld, derived, support], skipped: [], warnings: []), report: report([]))
        XCTAssertEqual(list.deletable(selected: [dyld.id, derived.id]).map(\.id), [derived.id])
        XCTAssertEqual(list.deletable(selected: []), [])
        XCTAssertEqual(DeleteList.markers(for: dyld), [.experimental, .needsRoot(.helperWithFullDiskAccess)])
        XCTAssertEqual(DeleteList.markers(for: derived), [])
    }

    // MARK: - Park and Run externally

    func testPlanMarkersFollowTheRowsFacts() {
        let r = report([item("derivedData", 1_000), item("archives", 200), item("simulatorRuntimeAssets", 4_000)])
        let run = SavingsPlanner.rows(report: r, bucket: .runFromExternal)
        let archives = run.first { $0.categoryID == "archives" }
        XCTAssertEqual(archives.map(SavingsMarker.markers(for:)), [.experimental, .actsImmediately, .newDataOnly])
        let park = SavingsPlanner.rows(report: r, bucket: .parkExternally)
        let runtime = park.first { $0.categoryID == "simulatorRuntimeAssets" }
        XCTAssertEqual(runtime.flatMap { SavingsMarker.markers(for: $0).first }, .experimental)
    }

    func testNotesAreTheCLIsTextsInTheLanguageAndUnknownIdsAreLeftOut() {
        let row = SavingsPlanRow(
            categoryID: "x", categoryName: "X", bytes: 0,
            option: SavingsOption(bucket: .parkExternally, isExperimental: false, appliesToExistingData: true, losesUserData: false),
            command: "c", itemCount: 0, actsImmediately: false, noteIDs: ["archivesPark", "nope", "rootOnly"])
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(row.localizedNotes, [L10n.tr("cli.plan.note.archivesPark"), L10n.tr("cli.plan.note.rootOnly")], locale)
            for marker in [SavingsMarker.experimental, .losesUserData, .actsImmediately, .newDataOnly, .perItem(3), .needsRoot(.helper)] {
                XCTAssertFalse(marker.localizedText.isEmpty || marker.localizedText.contains("cli.plan"), "\(marker) in \(locale)")
            }
        }
    }

    func testTheVaultStatusIsNoneOfflineOrTheFirstUsableVault() {
        func check(_ name: String, _ state: VaultVolumeState) -> VaultVolumeCheck {
            let v = VaultVolume(volumeUUID: name, volumeName: name, lastMountPoint: "/Volumes/" + name, registeredAt: Date(), sentinelID: "s")
            return VaultVolumeCheck(volume: v, state: state, currentMountPoint: nil, shadowBytes: nil, detail: "")
        }
        XCTAssertEqual(VaultStatus.make([]), .noVault)
        XCTAssertEqual(VaultStatus.make([check("A", .absent)]), .offline)
        XCTAssertEqual(VaultStatus.make([check("A", .absent), check("B", .foreign)]), .needsAttention(volumeName: "B"))
        XCTAssertEqual(VaultStatus.make([check("C", .sentinelMissing)]), .needsAttention(volumeName: "C"))
        XCTAssertEqual(VaultStatus.make([check("A", .absent), check("B", .movedMountPoint), check("C", .verified)]), .ready(volumeName: "B"))
    }

    /// M6: the intro quotes the "acts immediately" marker; in every language it must be that marker's own words.
    func testThePlanIntroQuotesTheActsImmediatelyMarkerInEveryLanguage() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertTrue(L10n.tr("app.plan.intro").contains(SavingsMarker.actsImmediately.localizedText), locale)
        }
    }

    /// M1: the CLI's `plan` text, whole, for a fixed report in English — markers, their order, separators, parentheses
    /// and notes — so moving the markers to `SavingsMarker` cannot change a byte unnoticed.
    func testThePlanTextIsPinnedInEnglish() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let gb: UInt64 = 1_000_000_000
        let r = report(
            [
                item("derivedData", 10 * gb), item("simulatorDevices", 3 * gb), item("simulatorRuntimeAssets", 40 * gb), item("archives", 2 * gb),
                item("runtimeLibrary", 5 * gb),
            ], devices: [device("A"), device("B")])
        func f(_ bytes: UInt64) -> String { ByteCount.format(bytes) }
        let delete = SavingsPlanner.render(rows: SavingsPlanner.rows(report: r, bucket: .deleteAndRegenerate), bucket: .deleteAndRegenerate)
        XCTAssertEqual(
            delete,
            "Delete — comes back on demand\n"
                + "Freed now; it grows back as Xcode rebuilds it or downloads it again.\n"
                + "Rebuild or re-download time.\n\n"
                + "  Simulator runtime images (MobileAsset store)  \(f(40 * gb))\n"
                + "      xcodevaultctl runtime delete <identifier> --dry-run\n"
                + "      The size shown counts only the MobileAsset store; `xcodevaultctl runtime list` shows each runtime's real size.\n"
                + "  DerivedData  \(f(10 * gb))  (experimental)\n"
                + "      xcodevaultctl clean --category derivedData\n"
                + "  Simulator devices  \(f(3 * gb))  (experimental, deletes the apps' data, acts immediately, 2 items; one per command)\n"
                + "      xcrun simctl delete <udid>\n"
                + "      Shut the device down first; its apps and their data are deleted.\n")
        let run = SavingsPlanner.render(rows: SavingsPlanner.rows(report: r, bucket: .runFromExternal), bucket: .runFromExternal)
        XCTAssertEqual(
            run,
            "Run from an external drive\n"
                + "Freed for good: it lives on the external drive and stops growing on this Mac.\n"
                + "Nothing to download; the drive must be connected while you work.\n\n"
                + "  Runtime Library (external installers)  \(f(5 * gb))  (experimental)\n"
                + "      xcodevaultctl runtime export <platform> --to <dir> --preflight\n"
                + "  DerivedData  \(f(10 * gb))  (experimental, acts immediately)\n"
                + "      xcodevaultctl locations set-derived-data <dir>\n"
                + "      Existing DerivedData stays where it is; `xcodevaultctl clean --category derivedData` reclaims it.\n"
                + "  Archives  (experimental, acts immediately, new data only)\n"
                + "      xcodevaultctl locations set-archives <dir>\n")
    }

    // MARK: - Backticks

    func testInlineCodeSplitsAtBackticks() {
        typealias R = InlineCode.Run
        XCTAssertEqual(InlineCode.runs("Run `a b` now."), [R("Run ", isCode: false), R("a b", isCode: true), R(" now.", isCode: false)])
        XCTAssertEqual(InlineCode.runs("`x` then `y`"), [R("x", isCode: true), R(" then ", isCode: false), R("y", isCode: true)])
        XCTAssertEqual(InlineCode.runs("no code"), [R("no code", isCode: false)])
        XCTAssertEqual(InlineCode.runs(""), [])
        XCTAssertEqual(InlineCode.runs("``"), [], "an empty span is nothing")
        XCTAssertEqual(InlineCode.runs("a `b` c `d"), [R("a ", isCode: false), R("b", isCode: true), R(" c `d", isCode: false)], "unmatched stays text")
        // Every note and vault line the views show comes apart with no backtick left over.
        for text in [L10n.tr("cli.plan.note.rootOnly"), L10n.tr("cli.plan.note.exportFirst"), L10n.tr("app.plan.vault.none")] {
            XCTAssertFalse(InlineCode.runs(text).contains { $0.text.contains("`") }, text)
            XCTAssertTrue(InlineCode.runs(text).contains(where: \.isCode), text)
        }
    }
}
