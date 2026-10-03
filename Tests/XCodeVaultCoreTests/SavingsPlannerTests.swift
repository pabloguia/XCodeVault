import XCTest

@testable import XCodeVaultCore

final class SavingsPlannerTests: XCTestCase {
    private func item(_ id: String, _ bytes: UInt64, onBoot: Bool = true) -> StorageItem {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        return StorageItem(
            categoryID: id, path: "/fixture/\(id)/\(bytes)", exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false,
            usage: usage, volumeMountPoint: nil, onBootVolume: onBoot)
    }

    private func report() -> ScanReport {
        var r = Fixtures.minimalReport()
        r.items = [
            item("derivedData", 1000), item("xcodeCaches", 30), item("archives", 200), item("simulatorDeadContainers", 7),
            item("xcodeCaches", 17, onBoot: false),
        ]
        return r
    }

    func testEveryOfferedPairHasACommandAndNoOtherDoes() {
        for c in StorageCatalog.all {
            let offered = Set(c.savingsOptions)
            for bucket in SavingsBucket.allCases where bucket != .keepLocal {
                let command = SavingsPlanner.command(categoryID: c.id, bucket: bucket)
                if offered.contains(bucket) {
                    XCTAssertNotNil(command, "\(c.id) offers \(bucket) but has no command")
                } else {
                    XCTAssertNil(command, "\(c.id) does not offer \(bucket) but has a command")
                }
            }
        }
    }

    func testArchivesAreNeverOfferedForDeletion() {
        XCTAssertNil(SavingsPlanner.command(categoryID: "archives", bucket: .deleteAndRegenerate))
        XCTAssertFalse(SavingsPlanner.rows(report: report(), bucket: .deleteAndRegenerate).contains { $0.categoryID == "archives" })
    }

    func testRowsCountTheSameBytesAsTheSummary() {
        let r = report()
        let rows = SavingsPlanner.rows(report: r, bucket: .deleteAndRegenerate)
        let summary = SavingsCalculator.summarize(items: r.items, category: StorageCatalog.category)
        XCTAssertGreaterThan(summary.deleteAndRegenerate.optionBytes, 0)
        XCTAssertEqual(rows.reduce(UInt64(0)) { $0 + $1.bytes }, summary.deleteAndRegenerate.optionBytes)
        XCTAssertEqual(rows.map(\.bytes), rows.map(\.bytes).sorted(by: >))
        XCTAssertFalse(rows.contains { $0.categoryID == "simulatorDeadContainers" }, "a breakdown is not a row")
    }

    func testNewDataOnlyOptionsAreListedWithZeroBytes() {
        let rows = SavingsPlanner.rows(report: report(), bucket: .runFromExternal)
        let archives = rows.first { $0.categoryID == "archives" }
        XCTAssertEqual(archives?.bytes, 0)
        XCTAssertEqual(archives?.option.appliesToExistingData, false)
        XCTAssertEqual(rows.first { $0.categoryID == "derivedData" }?.bytes, 1000)
    }

    func testRowsCarryTheOptionFacts() {
        var r = report()
        r.items += [item("simulatorDevices", 50), item("simulatorRuntimeAssets", 4000)]
        let devices = SavingsPlanner.rows(report: r, bucket: .deleteAndRegenerate).first { $0.categoryID == "simulatorDevices" }
        XCTAssertEqual(devices?.option.losesUserData, true)
        let runtime = SavingsPlanner.rows(report: r, bucket: .parkExternally).first { $0.categoryID == "simulatorRuntimeAssets" }
        XCTAssertEqual(runtime?.option.isExperimental, true)
    }

    func testRenderListsHeaderRowsAndCommandsOrTheEmptyNote() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let rows = SavingsPlanner.rows(report: report(), bucket: .runFromExternal)
        let text = SavingsPlanner.render(rows: rows, bucket: .runFromExternal)
        XCTAssertTrue(text.contains(SavingsBucket.runFromExternal.localizedTitle))
        XCTAssertTrue(text.contains("xcodevaultctl locations set-derived-data <dir>"))
        XCTAssertTrue(text.contains("new data only"))
        XCTAssertTrue(SavingsPlanner.render(rows: [], bucket: .parkExternally).contains("Nothing on this Mac offers this option."))
    }

    func testNoCommandIsAnythingButAPreview() {
        for c in StorageCatalog.all {
            for bucket in SavingsBucket.allCases {
                guard let command = SavingsPlanner.command(categoryID: c.id, bucket: bucket) else { continue }
                for flag in ["--apply", "--yes", "--remove-source-after-verify", "--i-confirm"] {
                    XCTAssertFalse(command.contains(flag), "\(c.id)/\(bucket): \(command)")
                }
            }
        }
        XCTAssertEqual(
            SavingsPlanner.command(categoryID: "simulatorRuntimeAssets", bucket: .deleteAndRegenerate), "xcodevaultctl runtime delete <identifier> --dry-run")
    }

    func testRenderShowsMarkersAndNotesOnTheRowsThatNeedThem() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        var r = report()
        r.items += [item("simulatorDevices", 50), item("simulatorRuntimeAssets", 4000)]
        let del = SavingsPlanner.render(rows: SavingsPlanner.rows(report: r, bucket: .deleteAndRegenerate), bucket: .deleteAndRegenerate)
        XCTAssertFalse(del.contains("Each command below shows what it would do first"))
        XCTAssertTrue(del.contains("deletes the apps' data"))
        XCTAssertTrue(del.contains("Shut the device down first; its apps and their data are deleted."))
        let park = SavingsPlanner.render(rows: SavingsPlanner.rows(report: r, bucket: .parkExternally), bucket: .parkExternally)
        let runtimeLine = park.split(separator: "\n").first { $0.contains("Simulator runtime images") }
        XCTAssertTrue(runtimeLine?.contains("experimental") == true, "the runtime park row carries its own marker")
        XCTAssertTrue(park.contains("the original is removed only in a second, explicit step."))
    }

    func testRowsWithoutAPreviewSayTheyActImmediately() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        var r = report()
        r.items += [item("simulatorDevices", 50), item("simulatorRuntimeAssets", 4000), item("runtimeLibrary", 9)]
        let previews = ["xcodevaultctl clean", "xcodevaultctl runtime delete", "xcodevaultctl runtime offload", "xcodevaultctl externalize"]
        let immediatePairs = [
            "simulatorDevices/deleteAndRegenerate", "derivedData/runFromExternal", "archives/runFromExternal", "runtimeLibrary/runFromExternal",
        ]
        var seen = 0
        for bucket in SavingsBucket.allCases where bucket != .keepLocal {
            let rows = SavingsPlanner.rows(report: r, bucket: bucket)
            let text = SavingsPlanner.render(rows: rows, bucket: bucket)
            XCTAssertFalse(text.contains("Each command below shows what it would do first"))
            let lines = text.split(separator: "\n").map(String.init)
            for row in rows {
                guard let line = lines.first(where: { $0.hasPrefix("  \(row.categoryName)") }) else { return XCTFail("no line for \(row.categoryID)") }
                let immediate = immediatePairs.contains("\(row.categoryID)/\(bucket.rawValue)")
                if immediate { seen += 1 }
                XCTAssertEqual(line.contains("acts immediately"), immediate, "\(row.categoryID)/\(bucket)")
                if previews.contains(where: row.command.hasPrefix) { XCTAssertFalse(line.contains("acts immediately"), row.command) }
            }
        }
        XCTAssertEqual(seen, 4, "all four pairs exist in the fixture")
    }
}
