import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R5, commit 3 of the HIG review (§5): the Mac-native structure — the window's subtitle, the filter's summary, the
/// Simulators table's words, the sidebar's symbols — over the made-up fixtures. No window.
@MainActor
final class R5StructureTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheSubtitleIsTheScanOrTheMac() async throws {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: detailSampleSurvey())
        XCTAssertEqual(model.windowSubtitle, "", "nothing to say before the first scan")
        await model.refresh()
        let host = try XCTUnwrap(model.report?.host)
        XCTAssertTrue(model.windowSubtitle.contains(host.macOSVersion), model.windowSubtitle)
        XCTAssertTrue(model.windowSubtitle.contains(ByteCount.format(host.dataVolumeFreeBytes)), model.windowSubtitle)
    }

    func testTheFilterSummaryNamesTheBucketsAndTheSearch() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(AppText.storageFilterSummary([.deleteAndRegenerate, .parkExternally], query: ""), "Filtering: Delete and Park")
        XCTAssertEqual(AppText.storageFilterSummary([], query: " derived "), "Filtering: “derived”")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for bucket in SavingsBucket.allCases {
                XCTAssertFalse(AppText.bucketShortName(bucket).hasPrefix("app."), "\(locale) \(bucket)")
            }
            XCTAssertFalse(AppText.storageFilterSummary(SavingsBucket.allCases, query: "x").contains("%"), locale)
        }
    }

    func testASimulatorRowsStateSaysMountedAndNeverAQuestionMark() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let mounted = SimulatorListRow(kind: .runtime, rowID: "R", name: "iOS 26.0", detail: "26.0", state: "Ready", isMounted: true, path: nil, bytes: nil)
        XCTAssertEqual(AppText.simulatorState(mounted), "Ready · Mounted")
        let unknown = SimulatorListRow(kind: .device, rowID: "D", name: "iPhone", detail: "iOS 26.0", state: nil, isMounted: nil, path: nil, bytes: nil)
        XCTAssertEqual(AppText.simulatorState(unknown), "—")
    }

    func testTheSidebarsDeleteIsTrashAndTheBucketKeepsItsSymbol() {
        XCTAssertEqual(SidebarSection.delete.symbol, "trash")
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.symbolName, "arrow.counterclockwise.circle", "the bucket's symbol is unchanged (BRAND.md)")
        XCTAssertEqual(SidebarSection.park.symbol, SavingsBucket.parkExternally.symbolName)
        XCTAssertNotNil(NSImage(systemSymbolName: SidebarSection.delete.symbol, accessibilityDescription: nil))
    }

    func testCopySummaryCopiesTheSelectedOperations() async {
        let t = TempDir()
        let copied = CopiedStrings()
        var survey = detailSampleSurvey()
        survey.4 = [
            JournalEntry(
                id: "op1", sequence: 1, timestamp: Date(timeIntervalSince1970: 1_000), kind: .clean, state: .completed, summary: "cleaned", paths: [],
                bytes: nil, detail: [:], toolVersion: "t")
        ]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey, copied: copied)
        await model.refresh()
        model.copyHistorySummaries(["op1", "missing"])
        XCTAssertEqual(copied.strings.count, 1)
        XCTAssertTrue(copied.strings.first?.hasPrefix("cleaned") ?? false)
        model.copyHistorySummaries([])
        XCTAssertEqual(copied.strings.count, 1, "nothing selected, nothing copied")
    }
}
