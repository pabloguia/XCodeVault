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
        XCTAssertEqual(VaultStatus.make([check("A", .absent), check("B", .foreign)]), .offline)
        XCTAssertEqual(VaultStatus.make([check("A", .absent), check("B", .movedMountPoint), check("C", .verified)]), .ready(volumeName: "B"))
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
