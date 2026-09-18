import XCTest

@testable import XCodeVaultCore

/// F22/F18: the regenerable data that lives *inside* each simulator device — dead app containers,
/// MobileAsset downloads, and the simulated log store. The product reports these and does not clean
/// them; these tests pin both halves, because "we chose not to offer it" and "we forgot to wire it
/// up" look identical from outside and only one of them is a decision.
final class PerDeviceRegenerablesTests: XCTestCase {
    /// Read from the catalog rather than listed here: a category added with `perDeviceSubpaths` and
    /// no thought about `clean` should fail these tests, not quietly escape them.
    static let perDeviceIDs = Set(StorageCatalog.all.filter { !$0.perDeviceSubpaths.isEmpty }.map(\.id))

    private let deviceA = "AAAAAAAA-1111-2222-3333-444444444444"
    private let deviceB = "BBBBBBBB-5555-6666-7777-888888888888"

    /// A device set holding two real (uppercase-UDID) devices and two directories that are not
    /// devices at all — each carrying the same per-device subpaths. There is deliberately no
    /// lowercase-UDID device here; `SimulatorNaming.isDeviceUDID` is pinned for case separately.
    private func makeDeviceSet(_ t: TempDir) {
        let set = "Library/Developer/CoreSimulator/Devices"
        let dead = "data/Library/Caches/com.apple.containermanagerd/Dead"
        let assets = "data/private/var/MobileAsset/AssetsV2"
        t.file("\(set)/\(deviceA)/\(dead)/temp.aaaaaa/container/payload.bin", bytes: 40_000)
        t.file("\(set)/\(deviceA)/\(assets)/com_apple_MobileAsset_Siri/a.asset", bytes: 30_000)
        t.file("\(set)/\(deviceB)/\(dead)/temp.bbbbbb/container/payload.bin", bytes: 20_000)
        t.file("\(set)/\(deviceA)/data/var/db/diagnostics/Persist/0000.tracev3", bytes: 25_000)
        t.file("\(set)/\(deviceA)/data/var/db/uuidtext/AB/CDEF", bytes: 5_000)
        // Not a device: same shape, must never be reported as one.
        t.file("\(set)/NotADevice/\(dead)/temp.cccccc/container/payload.bin", bytes: 90_000)
        t.file("\(set)/Backup 2026-09-01/\(dead)/temp.dddddd/container/payload.bin", bytes: 90_000)
    }

    private func items(_ t: TempDir) -> [StorageItem] {
        Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, measureSizes: true,
            detectXcodeCapabilities: false
        ).resolveItems()
    }

    private func report(home: String, items: [StorageItem]) -> ScanReport {
        let host = HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "x", architecture: "arm64", homeDirectory: home,
            dataVolumeFreeBytes: 500_000_000_000, dataVolumeTotalBytes: 1_000_000_000_000, userName: "t", isRoot: false)
        return ScanReport(
            generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: [],
            devices: [], volumes: [], items: items, summary: ScanSummary(), warnings: [])
    }

    // MARK: discovery

    func testResolvesOneItemPerDeviceRatherThanOneForTheDeviceSet() {
        let t = TempDir()
        makeDeviceSet(t)
        let dead = items(t).filter { $0.categoryID == "simulatorDeadContainers" && $0.exists }
        XCTAssertEqual(dead.count, 2, "expected one item per device, got \(dead.map(\.path))")
        for udid in [deviceA, deviceB] {
            XCTAssertTrue(
                dead.contains { $0.path.contains("/\(udid)/") && $0.path.hasSuffix("com.apple.containermanagerd/Dead") },
                "no item for \(udid) in \(dead.map(\.path))")
        }
        // The device set itself must not be reported under this category: that number would hide
        // which device the bytes belong to, and the devices are independently disposable.
        XCTAssertFalse(dead.contains { $0.path.hasSuffix("/Devices") })
    }

    func testDirectoriesThatAreNotDevicesAreNeverReportedAsDevices() {
        let t = TempDir()
        makeDeviceSet(t)
        let paths = items(t).filter { $0.categoryID == "simulatorDeadContainers" }.map(\.path)
        XCTAssertFalse(paths.contains { $0.contains("NotADevice") }, paths.description)
        XCTAssertFalse(paths.contains { $0.contains("Backup") }, paths.description)
    }

    /// Rejecting a lowercase UDID would silently drop a real device's bytes from the accounting,
    /// which is a worse failure than the one the guard exists to prevent.
    func testUDIDGuardAcceptsBothCasesAndRejectsEverythingElse() {
        XCTAssertTrue(SimulatorNaming.isDeviceUDID("AAAAAAAA-1111-2222-3333-444444444444"))
        XCTAssertTrue(SimulatorNaming.isDeviceUDID("aaaaaaaa-1111-2222-3333-444444444444"))
        for bad in [
            "NotADevice", "Backup 2026-09-01", "", "..", ".",
            "AAAAAAAA-1111-2222-3333-44444444444",  // 11 in the last group
            "AAAAAAAA-1111-2222-3333",  // four groups
            "ZZZZZZZZ-1111-2222-3333-444444444444",  // not hex
            "AAAAAAAA_1111_2222_3333_444444444444",  // underscores
        ] {
            XCTAssertFalse(SimulatorNaming.isDeviceUDID(bad), "accepted \(bad)")
        }
    }

    func testSizesAreMeasuredPerDeviceAndNotSummedIntoOne() throws {
        let t = TempDir()
        makeDeviceSet(t)
        let dead = items(t).filter { $0.categoryID == "simulatorDeadContainers" && $0.exists }
        let a = try XCTUnwrap(dead.first { $0.path.contains(deviceA) })
        let b = try XCTUnwrap(dead.first { $0.path.contains(deviceB) })
        XCTAssertGreaterThan(a.allocatedBytes, b.allocatedBytes, "device A holds twice device B's payload")
    }

    // MARK: labeling

    func testEveryPerDeviceCategoryIsReportOnlyAndCarriesEvidence() throws {
        // Driven off the catalog, but pinned to the set we actually reviewed: a new per-device
        // category must either be reviewed and added here, or fail.
        XCTAssertEqual(
            PerDeviceRegenerablesTests.perDeviceIDs,
            ["simulatorDeadContainers", "simulatorMobileAssets", "simulatorLogStore"],
            "a per-device category was added or removed without revisiting these safety expectations")
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() {
            let c = try XCTUnwrap(StorageCatalog.category(id), id)
            XCTAssertFalse(c.isCleanable, "\(id) must not advertise cleaning while the sweep is unverified")
            XCTAssertFalse(c.isRelocatable, "\(id) lives inside a device set that is never relocated (rule 7)")
            XCTAssertEqual(c.recommendedStrategy, .appleManaged)
            XCTAssertNil(c.cleanupCommand, "no official command reclaims these narrowly; inventing one would be worse than saying so")
            // Nil is allowed and means "nothing we can stand behind". What is not allowed is advice
            // that tells the user to delete these by hand, which is the one thing the product refuses.
            // A hint on a report-only finding must not name ANY destructive command. An earlier
            // version of this test banned `rm` and `simctl erase` but tolerated `simctl delete`,
            // which is what let a device-destroying suggestion through — a test can pin the wrong
            // behaviour just as firmly as the right one.
            if let hint = c.remediationHint {
                for forbidden in ["rm -", "rm ", "simctl erase", "simctl delete", "rmdir"] {
                    XCTAssertFalse(hint.contains(forbidden), "\(id) hint names a destructive command (\(forbidden)): \(hint)")
                }
            }
            XCTAssertNotNil(c.evidence, "rule 10: no evidence pointer means unverified")
            XCTAssertFalse(c.notes.isEmpty, "the reason it is not offered has to be written down somewhere the user can reach")
            XCTAssertFalse(c.perDeviceSubpaths.isEmpty, "\(id) is only ever resolved inside a device")
        }
    }

    func testPerDeviceCategoriesPassTheCatalogSafetyRules() {
        XCTAssertEqual(CatalogRules.validate(StorageCatalog.all).map(\.description), [])
    }

    // MARK: clean must not offer them

    /// The load-bearing part is the first assertion: without it this test would also pass if the
    /// scanner stopped finding the directories at all, which is the opposite of what it claims.
    func testCleanProducesNoActionForPerDeviceCategoriesEvenThoughTheBytesAreThere() {
        let t = TempDir()
        makeDeviceSet(t)
        let all = items(t)
        let mine = all.filter { PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }
        XCTAssertGreaterThan(mine.filter { $0.exists }.count, 0, "fixture produced nothing — the rest of this test would be vacuous")
        XCTAssertGreaterThan(mine.reduce(0) { $0 + $1.allocatedBytes }, 0, "bytes must be non-zero or `clean` would skip them for an unrelated reason")

        let plan = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: all))
        let offered = plan.actions.filter { PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }
        XCTAssertTrue(offered.isEmpty, "clean offered \(offered.map(\.path))")
    }

    // MARK: totals must not double-count

    /// These categories are slices of `simulatorDevices`, not storage on top of it. Summing both
    /// would inflate every headline by the size of the slice — over-reporting, which is as wrong as
    /// under-reporting and harder to spot, because a bigger number looks like better accounting.
    func testBreakdownCategoriesAreNotCountedOnTopOfTheCategoryTheyDecompose() {
        let t = TempDir()
        makeDeviceSet(t)
        let scanner = Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, measureSizes: true, detectXcodeCapabilities: false)
        let all = scanner.resolveItems()

        let slices = all.filter { PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }
        let sliceBytes = slices.reduce(0) { $0 + $1.allocatedBytes }
        XCTAssertGreaterThan(sliceBytes, 0, "fixture produced no slices — the rest of this test would be vacuous")

        let root = all.first { $0.categoryID == "simulatorDevices" && $0.exists }
        XCTAssertNotNil(root, "the parent category must still be resolved")

        let summary = scanner.summarize(items: all, runtimes: [])
        let withoutSlices = scanner.summarize(items: all.filter { !PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }, runtimes: [])
        XCTAssertEqual(
            summary.internalDeveloperBytes, withoutSlices.internalDeveloperBytes,
            "adding the breakdown changed the machine-wide total by \(Int64(summary.internalDeveloperBytes) - Int64(withoutSlices.internalDeveloperBytes)) bytes"
        )
        XCTAssertEqual(summary.appleManagedBytes, withoutSlices.appleManagedBytes)
        XCTAssertEqual(summary.cleanableBytes, withoutSlices.cleanableBytes)
        XCTAssertEqual(summary.relocatableBytes, withoutSlices.relocatableBytes)
    }

    /// Every breakdown category must name a parent that exists, or the exclusion above silently
    /// drops bytes from the totals instead of de-duplicating them.
    func testEveryBreakdownCategoryNamesARealParent() throws {
        for c in StorageCatalog.all {
            guard let parent = c.isBreakdownOf else { continue }
            let p = try XCTUnwrap(StorageCatalog.category(parent), "\(c.id) is a breakdown of unknown category \(parent)")
            XCTAssertNil(p.isBreakdownOf, "\(c.id) -> \(parent) -> ... : breakdowns must be one level deep or the totals stop being a partition")
            for sub in c.perDeviceSubpaths {
                XCTAssertFalse(sub.hasPrefix("/"), "\(c.id) subpath must be relative to the device root: \(sub)")
                XCTAssertFalse(sub.contains(".."), "\(c.id) subpath must not escape the device root: \(sub)")
            }
        }
    }

    // MARK: the rest of the product must not be able to reach these

    /// `planRestore` used to have no strategy gate at all, so any category whose `pathTemplates`
    /// named a live tree could be a restore destination — our own engine writing shadow data into
    /// the CoreSimulator device set at a canonical path (rule 6).
    func testRestoreRefusesACategoryThatWasNeverEligibleToLeave() {
        let t = TempDir()
        let engine = MigrationEngine(journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")), home: t.path, volumeUUIDAt: { _ in "VU" })
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() + ["simulatorDevices"] {
            XCTAssertThrowsError(
                try engine.planRestore(
                    categoryID: id, vaultRef: t.path + "/vault", name: "x",
                    to: t.path + "/Library/Developer/CoreSimulator/Devices/\(deviceA)/data/private/var/MobileAsset/x"),
                "\(id) was accepted as a restore destination")
        }
    }

    /// `abort` deletes directly, so the `.coldStorage` gate that `planExternalize`, `planRestore`,
    /// `removeSource` and `resume` all apply has to be here too. It was missing, and a mutation run
    /// caught that adding it changed no test — a guard nothing distinguishes is a guard that can
    /// stop working unnoticed.
    func testAbortWillNotDeleteForACategoryThatWasNeverEligibleToLeave() throws {
        let t = TempDir()
        makeDeviceSet(t)
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl"))
        let engine = MigrationEngine(journal: journal, home: t.path, volumeUUIDAt: { _ in "VU" })
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() {
            guard let c = StorageCatalog.category(id) else { continue }
            // A destination that IS a real path of the category, so nothing else can be what
            // refuses: containment passes, the directory exists, and only the strategy gate is left.
            let destination = set + "/" + deviceA + "/" + c.perDeviceSubpaths[0]
            XCTAssertTrue(c.containsPath(destination, home: t.path), "fixture is wrong: \(destination) is not a path of \(c.id)")
            let op = UUID().uuidString
            try journal.record(
                id: op, kind: .migration, state: .planned, summary: "planted",
                paths: [t.path + "/vault/\(c.id)/x", destination],
                detail: ["direction": "restore", "category": c.id, "vault": ""])

            let disposition = engine.abortDisposition(entries: try journal.entries().filter { $0.id == op }, operationID: op)
            switch disposition {
            case .declined(let why): XCTAssertTrue(why.contains("coldStorage"), "declined for another reason: \(why)")
            default: XCTFail("\(c.id): abort was willing to act (\(disposition))")
            }
            XCTAssertThrowsError(try engine.abort(operationID: op), "\(c.id): abort did not refuse")
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination), "\(c.id): abort deleted a live per-device path")
        }
    }

    /// `clean` declines these on purpose. Declining in silence is indistinguishable from having
    /// missed them, for a user who just saw the gigabytes in `scan`.
    func testCleanExplainsWhyItIsNotOfferingTheseRatherThanSayingNothing() {
        let t = TempDir()
        makeDeviceSet(t)
        let all = items(t)
        let plan = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: all))
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() {
            let name = StorageCatalog.category(id)?.name ?? id
            XCTAssertTrue(plan.skipped.contains { $0.hasPrefix(name) }, "no explanation for \(name) in \(plan.skipped)")
        }
    }

    /// The catalog invariants the review asked for: a breakdown that lies about its parent silently
    /// removes bytes from the totals instead of de-duplicating them.
    func testCatalogRulesRejectABreakdownThatLiesAboutItsParent() {
        let orphan = StorageCategory(
            id: "orphan", name: "Orphan", subsystem: .coreSimulator, pathTemplates: ["~/somewhere"],
            description: "d", regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            isBreakdownOf: "noSuchCategory")
        XCTAssertFalse(CatalogRules.validate([orphan]).isEmpty, "a breakdown of a nonexistent parent was accepted")

        let outside = StorageCategory(
            id: "outside", name: "Outside", subsystem: .coreSimulator, pathTemplates: ["~/elsewhere"],
            description: "d", regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            isBreakdownOf: "simulatorDevices")
        XCTAssertFalse(
            CatalogRules.validate(StorageCatalog.all + [outside]).isEmpty,
            "a breakdown whose paths are not inside its parent was accepted")

        let escaping = StorageCategory(
            id: "escaping", name: "Escaping", subsystem: .coreSimulator,
            pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"], description: "d",
            regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
            recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
            perDeviceSubpaths: ["../../../etc"], isBreakdownOf: "simulatorDevices")
        XCTAssertFalse(CatalogRules.validate(StorageCatalog.all + [escaping]).isEmpty, "an escaping subpath was accepted")
    }

    /// `removeSource` is the only function in the product that deletes a source directory. Its
    /// protection used to be an argument spanning four functions and a journal file the user can
    /// edit; now it is a check in the function that does the deleting.
    func testSourceRemovalRefusesACategoryThatCouldNeverHaveBeenExternalized() throws {
        let t = TempDir()
        let src = t.dir("Library/Developer/CoreSimulator/Devices/\(deviceA)/data/private/var/MobileAsset")
        t.file("Library/Developer/CoreSimulator/Devices/\(deviceA)/data/private/var/MobileAsset/a.bin", bytes: 1000)
        let engine = MigrationEngine(
            journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")), home: t.path,
            isXcodeRunning: { false })
        let plan = MigrationPlan(
            operationID: "op", direction: .externalize, categoryID: "simulatorMobileAssets",
            source: src, destination: t.path + "/vault/x", vaultUUID: nil,
            sourceBytes: 1000, sourceFiles: 1, deepVerify: false, warnings: [])
        // A verification report that says the copy is perfect: the point is that even a plan which
        // has passed everything downstream still cannot aim source removal at this category.
        let verified = TreeVerifier.Report(
            sourceFiles: 1, destinationFiles: 1, sourceBytes: 1000, destinationBytes: 1000,
            hashedFiles: 0, mismatches: [], truncated: false)
        let outcome = MigrationOutcome(plan: plan, verification: verified, sourceRemoved: false)
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: true)) { e in
            XCTAssertTrue("\(e)".contains("coldStorage"), "\(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src), "the source directory was removed anyway")
    }

    /// A device set that exists and cannot be read must not render identically to one with nothing
    /// in it: several GB would leave the report with nothing on screen to say so.
    func testAnUnreadableDeviceSetWarnsInsteadOfSilentlyReportingNothing() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        defer { _ = chmod(set, 0o755) }
        XCTAssertEqual(chmod(set, 0o000), 0, "could not make the fixture unreadable")

        var warnings: [String] = []
        let found = Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, measureSizes: false, detectXcodeCapabilities: false
        ).resolveItems(warnings: &warnings)
        XCTAssertTrue(found.filter { PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }.isEmpty, "fails closed")
        XCTAssertTrue(warnings.contains { $0.contains(set) }, "failed closed silently: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("not absent") }, warnings.description)
    }

    /// ...but a device set that simply does not exist is not a failure and must not cry wolf.
    func testAnAbsentDeviceSetProducesNoWarning() {
        let t = TempDir()
        var warnings: [String] = []
        _ = Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, measureSizes: false, detectXcodeCapabilities: false
        ).resolveItems(warnings: &warnings)
        XCTAssertTrue(warnings.isEmpty, warnings.description)
    }

    // MARK: doctor reports them

    func testDoctorReportsTheTotalPerDeviceAndOffersNoRemediation() throws {
        let t = TempDir()
        makeDeviceSet(t)
        let doctor = Doctor(
            home: t.path, runner: FakeRunner(responses: [:]), dyldCacheRoot: t.path + "/no-such-dyld-cache",
            journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")))
        // Through `diagnose`, not the rule in isolation: a rule that is never called is not a check.
        let findings = doctor.diagnose(report: report(home: t.path, items: items(t)))

        let dead = try XCTUnwrap(
            findings.first { $0.id == "perDeviceRegenerable.simulatorDeadContainers" }, findings.map(\.id).description)
        XCTAssertEqual(dead.severity, .info)
        XCTAssertNotNil(dead.evidence)
        // No remediation on any of the three. This assertion has changed twice and both changes were
        // retreats: the hint first named `simctl delete <udid>`, then said "boot the device and the
        // system reclaims it" — falsified when the same device, left booted three hours, accumulated
        // 2 GB and reaped none of it. There is no action to offer, so the finding offers none.
        XCTAssertNil(dead.remediation, "an INFO finding acquired advice again: \(dead.remediation ?? "")")
        for f in findings where f.id.hasPrefix("perDeviceRegenerable.") {
            XCTAssertNil(f.remediation, "\(f.id) offers a remediation this evidence does not support")
        }
        XCTAssertTrue(dead.detail.contains(deviceA), "the per-device breakdown is the actionable part")
        XCTAssertTrue(dead.detail.contains(deviceB))
        XCTAssertTrue(dead.detail.contains("Not offered by `clean`"), dead.detail)

        XCTAssertNotNil(findings.first { $0.id == "perDeviceRegenerable.simulatorMobileAssets" })
        // The log store occupies two subpaths under one device; it must still read as one finding.
        let logs = try XCTUnwrap(findings.first { $0.id == "perDeviceRegenerable.simulatorLogStore" })
        XCTAssertTrue(logs.detail.contains(deviceA), logs.detail)
    }

    /// `doctor` scans with `measureSizes: false`. The first version of this rule read
    /// `item.allocatedBytes` and so reported nothing at all on a real machine, while every test
    /// passed — because the tests built their items with a measuring scanner, which is a value the
    /// production caller never produces. This test uses the caller's own configuration.
    func testDoctorReportsRealSizesEvenWhenTheScanDidNotMeasureThem() throws {
        let t = TempDir()
        makeDeviceSet(t)
        let unmeasured = Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, measureSizes: false,
            detectXcodeCapabilities: false
        ).resolveItems()
        XCTAssertEqual(
            unmeasured.filter { PerDeviceRegenerablesTests.perDeviceIDs.contains($0.categoryID) }.reduce(0) { $0 + $1.allocatedBytes }, 0,
            "precondition: an unmeasured scan carries no bytes — if this ever changes, this test stops testing anything")

        let doctor = Doctor(
            home: t.path, runner: FakeRunner(responses: [:]), dyldCacheRoot: t.path + "/no-such-dyld-cache",
            journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")))
        let dead = try XCTUnwrap(
            doctor.diagnose(report: report(home: t.path, items: unmeasured))
                .first { $0.id == "perDeviceRegenerable.simulatorDeadContainers" },
            "the rule must not depend on a caller's measuring choice it cannot see")
        XCTAssertFalse(dead.title.contains("0 B"), dead.title)
        XCTAssertTrue(dead.detail.contains(deviceA), dead.detail)
    }

    /// The log store occupies two subpaths inside one device; the reader must see one line per
    /// device, not one per directory.
    func testLogStoreIsOneLinePerDeviceEvenThoughItOccupiesTwoSubpaths() throws {
        let t = TempDir()
        makeDeviceSet(t)
        let doctor = Doctor(
            home: t.path, runner: FakeRunner(responses: [:]), dyldCacheRoot: t.path + "/no-such-dyld-cache",
            journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")))
        let logs = try XCTUnwrap(
            doctor.diagnose(report: report(home: t.path, items: items(t)))
                .first { $0.id == "perDeviceRegenerable.simulatorLogStore" })
        XCTAssertEqual(logs.detail.components(separatedBy: deviceA).count - 1, 1, "device listed twice:\n" + logs.detail)
        XCTAssertTrue(logs.title.contains("1 device"), logs.title)
    }

    func testDoctorSaysNothingWhenThereIsNothingToReport() {
        let t = TempDir()
        t.dir("Library/Developer/CoreSimulator/Devices")
        let doctor = Doctor(
            home: t.path, runner: FakeRunner(responses: [:]), dyldCacheRoot: t.path + "/no-such-dyld-cache",
            journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")))
        let findings = doctor.diagnose(report: report(home: t.path, items: items(t)))
        XCTAssertFalse(findings.contains { $0.id.hasPrefix("perDeviceRegenerable.") }, "an empty device set must not produce a 0-byte finding")
    }

    // MARK: containment — what a per-device category actually IS

    /// Every negative assertion below names a path that EXISTS. `containsPath` canonicalizes, and
    /// canonicalization fails for a path whose parent is absent — so a negative case built on a
    /// made-up path would pass because the check errored, not because it refused. This asserts the
    /// canonicalization succeeds first, so the test cannot pass through the fail-closed door.
    private func assertNotContained(
        _ path: String, in c: StorageCategory, home: String, _ why: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(try? PathSafety.canonicalize(path), "\(path) does not canonicalize; this case proves nothing", file: file, line: line)
        XCTAssertFalse(c.containsPath(path, home: home), "\(c.id) accepted \(path) — \(why)", file: file, line: line)
    }

    /// `pathTemplates` for these names the enclosing device set, which is not the category. Before
    /// this, containment was a prefix test against that root, so the set itself, any device root,
    /// and every byte of every device passed as "inside the category".
    func testTheDeviceSetAndTheDevicesAreNotTheCategory() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers") else { return XCTFail("no category") }
        assertNotContained(set, in: dead, home: t.path, "the device set is the enclosure, not the category")
        assertNotContained(set + "/" + deviceA, in: dead, home: t.path, "a device root is the device, not the category")
        assertNotContained(set + "/" + deviceA + "/data", in: dead, home: t.path, "a prefix of the subpath is not the subpath")
        assertNotContained(
            set + "/" + deviceA + "/data/Library/Caches", in: dead, home: t.path,
            "a parent of the subpath holds the user's other caches too")
    }

    func testTheSubpathInsideADeviceIsTheCategory() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers") else { return XCTFail("no category") }
        let exact = set + "/" + deviceA + "/data/Library/Caches/com.apple.containermanagerd/Dead"
        XCTAssertTrue(dead.containsPath(exact, home: t.path), "the category's own path was rejected")
        XCTAssertTrue(dead.containsPath(exact + "/temp.aaaaaa", home: t.path), "a path inside the category was rejected")
        XCTAssertTrue(
            dead.containsPath(set + "/" + deviceB + "/data/Library/Caches/com.apple.containermanagerd/Dead", home: t.path),
            "the subpath in a second device was rejected")
    }

    /// Two categories share the device set as their template. Containment must still tell them
    /// apart, or the engine could act on one while believing it was checking the other.
    func testOnePerDeviceCategoryDoesNotContainAnother() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers"),
            let assets = StorageCatalog.category("simulatorMobileAssets")
        else { return XCTFail("missing category") }
        let assetPath = set + "/" + deviceA + "/data/private/var/MobileAsset"
        XCTAssertTrue(assets.containsPath(assetPath, home: t.path), "MobileAsset rejected its own path")
        assertNotContained(assetPath, in: dead, home: t.path, "MobileAsset is not dead containers")
    }

    /// The case every earlier negative here was too shallow to reach. All of them stopped inside
    /// the device before the subpath had as many components as the category's, so they exercised
    /// the length guard and never the comparison — a mutation that made the subpath match
    /// unconditional survived the whole suite. This one is deep enough that only the comparison
    /// can reject it.
    func testADeepPathInsideTheDeviceThatIsNotTheSubpathIsRejected() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers") else { return XCTFail("no category") }
        let deadComponents = dead.perDeviceSubpaths[0].split(separator: "/").count
        // The log store's own directory, reached from the dead-containers category. It exists, and
        // it is at least as deep as the subpath being matched, so the length guard cannot be what
        // rejects it.
        let other = set + "/" + deviceA + "/data/var/db/diagnostics/Persist"
        XCTAssertGreaterThanOrEqual(
            other.split(separator: "/").count - (set + "/" + deviceA).split(separator: "/").count, deadComponents,
            "this case must be deep enough to reach the comparison, or it proves nothing")
        assertNotContained(other, in: dead, home: t.path, "a deep path in another category is not dead containers")

        // Shares the first component (`data`) with the subpath, so a check that compared only the
        // head would accept it.
        XCTAssertEqual(String(dead.perDeviceSubpaths[0].split(separator: "/")[0]), "data")
    }

    /// The scanner has always refused to call a non-UDID directory a device; the containment
    /// predicate did not, so a directory a user left in the device set satisfied containment for a
    /// per-device category and from there reached a deletion path. Both decoys already existed in
    /// the fixture — only the scanner half was pinned.
    func testADirectoryInTheDeviceSetThatIsNotADeviceIsNotPartOfTheCategory() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers") else { return XCTFail("no category") }
        let sub = dead.perDeviceSubpaths[0]
        for decoy in ["NotADevice", "Backup 2026-09-01"] {
            assertNotContained(
                set + "/" + decoy + "/" + sub, in: dead, home: t.path,
                "\(decoy) is not a device, so what is under it is not ours to act on")
        }
        // The engine's own gate, not just the predicate.
        let engine = MigrationEngine(journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")), home: t.path, volumeUUIDAt: { _ in "VU" })
        XCTAssertThrowsError(
            try engine.preflightSource(set + "/Backup 2026-09-01/" + sub, category: dead),
            "preflight accepted a non-device directory as a source")
    }

    /// `containsPath` answers false when canonicalization fails, and every negative test above
    /// leans on that being the *safe* direction rather than an accident. Nothing pinned it until a
    /// mutation made the failure path return true and survived the whole suite.
    func testAPathThatCannotBeCanonicalizedIsNotContained() {
        let t = TempDir()
        makeDeviceSet(t)
        t.file("Library/Developer/Xcode/DerivedData/x/y.o", bytes: 10)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let dead = StorageCatalog.category("simulatorDeadContainers"),
            let dd = StorageCatalog.category("derivedData")
        else { return XCTFail("missing category") }
        // `..` is rejected by canonicalize outright; a missing parent makes realpath fail.
        for bad in [
            set + "/" + deviceA + "/../" + deviceA + "/" + dead.perDeviceSubpaths[0],
            set + "/" + deviceA + "/no/such/parent/here",
        ] {
            XCTAssertFalse(dead.containsPath(bad, home: t.path), "per-device accepted \(bad)")
        }
        for bad in [t.path + "/Library/Developer/Xcode/DerivedData/../DerivedData", t.path + "/Library/Developer/Xcode/DerivedData/no/such/parent"] {
            XCTAssertFalse(dd.containsPath(bad, home: t.path), "ordinary accepted \(bad)")
        }
    }

    /// A category whose subpaths split to nothing would make the prefix comparison match the empty
    /// array — accepting every path in the device set, app containers included. `CatalogRules`
    /// rejects such a category, but it is not a startup invariant: it runs only in the
    /// `compatibility` subcommand, so the predicate must hold the line itself.
    func testACategoryWhoseSubpathIsEmptyContainsNothing() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        for empty in [[""], ["/"], ["//"]] {
            let broken = StorageCategory(
                id: "broken", name: "Broken", subsystem: .coreSimulator,
                pathTemplates: ["~/Library/Developer/CoreSimulator/Devices"], description: "d",
                regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
                recommendedStrategy: .appleManaged, allowedStrategies: [.appleManaged],
                perDeviceSubpaths: empty)
            XCTAssertFalse(
                broken.containsPath(set + "/" + deviceA + "/data/Library/Caches", home: t.path),
                "a category with subpaths \(empty) accepted an arbitrary path in the device set")
        }
    }

    /// The log store is two directories. A category with several subpaths must accept each — the
    /// plural exists so one concept is not reported as two numbers.
    func testEverySubpathOfAMultiPartCategoryIsContained() {
        let t = TempDir()
        makeDeviceSet(t)
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        guard let logs = StorageCatalog.category("simulatorLogStore") else { return XCTFail("no category") }
        XCTAssertFalse(logs.perDeviceSubpaths.count < 2, "this test assumes a multi-subpath category")
        for sub in logs.perDeviceSubpaths {
            XCTAssertTrue(logs.containsPath(set + "/" + deviceA + "/" + sub, home: t.path), "\(sub) was rejected")
        }
    }

    /// An ordinary category keeps the old meaning: its template IS its path.
    func testAnOrdinaryCategoryStillContainsItsOwnTemplateRoot() {
        let t = TempDir()
        t.file("Library/Developer/Xcode/DerivedData/x/y.o", bytes: 10)
        guard let dd = StorageCatalog.all.first(where: { $0.perDeviceSubpaths.isEmpty && $0.id == "derivedData" })
        else { return XCTFail("no derivedData category") }
        let root = t.path + "/Library/Developer/Xcode/DerivedData"
        XCTAssertTrue(dd.containsPath(root, home: t.path), "an ordinary category rejected its own root")
        XCTAssertTrue(dd.containsPath(root + "/x", home: t.path), "an ordinary category rejected a path inside it")
    }

    /// The engine's own gate, not just the predicate: `preflightSource` used to accept the whole
    /// device set as a source for a per-device category.
    func testPreflightRefusesTheDeviceSetAsASourceForAPerDeviceCategory() {
        let t = TempDir()
        makeDeviceSet(t)
        let engine = MigrationEngine(journal: Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl")), home: t.path, volumeUUIDAt: { _ in "VU" })
        let set = t.path + "/Library/Developer/CoreSimulator/Devices"
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() {
            guard let c = StorageCatalog.category(id) else { continue }
            XCTAssertThrowsError(try engine.preflightSource(set, category: c), "\(id) accepted the device set as a source")
            XCTAssertThrowsError(try engine.preflightSource(set + "/" + deviceA, category: c), "\(id) accepted a device root as a source")
        }
    }

    /// The CLI defaults `--source`/`--to` to `pathTemplates.first!`. For these categories that is
    /// the device set, which is not a place any of them lives — so there is no default to offer.
    func testThereIsNoSingleStandardPathForAPerDeviceCategory() {
        let t = TempDir()
        for id in PerDeviceRegenerablesTests.perDeviceIDs.sorted() {
            guard let c = StorageCatalog.category(id) else { continue }
            XCTAssertNil(c.singleStandardPath(home: t.path), "\(id) offered a single standard path")
        }
        guard let dd = StorageCatalog.category("derivedData") else { return XCTFail("no derivedData") }
        XCTAssertNotNil(dd.singleStandardPath(home: t.path), "an ordinary category lost its standard path")
        // Not defence in depth, whatever the first draft of this claimed: `runtimeLibrary` has no
        // path templates at all, so `pathTemplates.first!` trapped before any strategy gate could
        // refuse. `xcodevaultctl externalize --category runtimeLibrary --vault X` crashed.
        guard let rl = StorageCatalog.category("runtimeLibrary") else { return XCTFail("no runtimeLibrary") }
        XCTAssertTrue(rl.pathTemplates.isEmpty, "this case assumes a category with no templates")
        XCTAssertNil(rl.singleStandardPath(home: t.path), "a category with no templates offered a path")
    }
}
