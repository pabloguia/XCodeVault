import XCTest

@testable import XCodeVaultCore

/// The savings block of the CLI (spec 2026-10-03 §5): both headlines, every option, the next step; aligned
/// for wide scripts; never a raw key.
final class SavingsTextTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    /// The headlines are unions, so temporary + permanent is not the total: DerivedData is in both. Every amount is
    /// distinct, so a line that printed the wrong one could not pass by coincidence.
    private func summary(lowerBound: Bool = false, losesUserData: UInt64 = 0) -> SavingsSummary {
        var s = SavingsSummary()
        s.deleteAndRegenerate.optionBytes = 30_100_000_000
        s.parkExternally.optionBytes = 12_200_000_000
        s.runFromExternal.optionBytes = 8_000_000_000
        s.temporaryBytes = 42_300_000_000
        s.permanentBytes = 8_000_000_000
        s.reclaimableBytes = 45_700_000_000
        s.keepLocal.primaryBytes = 3_100_000_000
        s.verifiedTemporaryBytes = 12_100_000_000
        s.verifiedPermanentBytes = 2_400_000_000
        s.deleteLosesUserDataBytes = losesUserData
        s.isLowerBound = lowerBound
        return s
    }

    private func line(_ out: String, containing needle: String) -> String? {
        out.split(separator: "\n").map(String.init).first { $0.contains(needle) }
    }

    func testTheBlockShowsBothHeadlinesEveryBucketAndTheNextStep() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(), runtimeImageBytes: 0)
        var from = out.startIndex
        for needle in [
            "What you can reclaim on this Mac", "Temporary", "Delete — comes back on demand", "Park on an external drive", "Permanent",
            "Run from an external drive", "Total reclaimable", "Stays on this Mac", "xcodevaultctl plan delete | park | external",
        ] {
            guard let r = out.range(of: needle, range: from..<out.endIndex) else { return XCTFail("\(needle) missing or out of order in:\n\(out)") }
            from = r.upperBound
        }
        XCTAssertTrue(out.contains("up to"))
        XCTAssertFalse(out.contains("at least"))
    }

    func testEachHeadlineShowsItsOwnAmountAndVerifiedShare() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(), runtimeImageBytes: 0)
        let temporary = line(out, containing: "Temporary")
        XCTAssertTrue(temporary?.contains(ByteCount.format(UInt64(42_300_000_000))) == true, out)
        XCTAssertTrue(temporary?.contains(ByteCount.format(UInt64(12_100_000_000))) == true, out)
        let permanent = line(out, containing: "Permanent")
        XCTAssertTrue(permanent?.contains(ByteCount.format(UInt64(8_000_000_000))) == true, out)
        XCTAssertTrue(permanent?.contains(ByteCount.format(UInt64(2_400_000_000))) == true, out)
        XCTAssertTrue(line(out, containing: "Total reclaimable")?.contains(ByteCount.format(UInt64(45_700_000_000))) == true, out)
    }

    func testALowerBoundSaysAtLeastEverywhere() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(lowerBound: true), runtimeImageBytes: 0)
        XCTAssertFalse(out.contains("up to"), out)
        XCTAssertTrue(out.contains("at least"), out)
        for needle in ["Delete — comes back on demand", "Park on an external drive", "Run from an external drive", "Stays on this Mac"] {
            XCTAssertTrue(line(out, containing: needle)?.contains("at least") == true, "\(needle):\n\(out)")
        }
    }

    /// Simulator devices are in the delete total but do not come back (final S3 review, Important 1).
    func testTheDeleteRowSaysWhatPartLosesUserData() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(losesUserData: 14_000_000_000), runtimeImageBytes: 0)
        let lines = out.split(separator: "\n").map(String.init)
        guard let delete = lines.firstIndex(where: { $0.contains("Delete — comes back on demand") }) else { return XCTFail(out) }
        let next = lines[delete + 1]
        XCTAssertTrue(next.contains("of which \(ByteCount.format(UInt64(14_000_000_000))) deletes apps' data and does not come back"), out)
        XCTAssertTrue(next.hasPrefix("      "), "indented under the delete row: \(next)")
        XCTAssertFalse(TextRenderer.savings(summary(), runtimeImageBytes: 0).contains("deletes apps' data"))
    }

    /// Runtimes stored as disk images are measured by simctl, not by the catalog (final S3 review, Important 3).
    func testRuntimeImagesAreNamedSeparatelyWhenThereAreAny() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(), runtimeImageBytes: 15_840_000_000)
        guard let note = line(out, containing: "Simulator runtimes measured by simctl") else { return XCTFail(out) }
        XCTAssertTrue(note.contains(ByteCount.format(UInt64(15_840_000_000))), note)
        XCTAssertTrue(note.contains("xcodevaultctl runtime list"), note)
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.firstIndex(of: note), (lines.firstIndex { $0.contains("Stays on this Mac") } ?? -2) + 1, out)
        XCTAssertFalse(TextRenderer.savings(summary(), runtimeImageBytes: 0).contains("measured by simctl"))
    }

    func testEveryLanguageRendersWithoutLeakingKeys() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let out = TextRenderer.savings(summary(losesUserData: 1_000_000_000), runtimeImageBytes: 2_000_000_000)
            XCTAssertFalse(out.contains("savings."), "\(locale):\n\(out)")
            XCTAssertFalse(out.contains("cli."), "\(locale):\n\(out)")
            XCTAssertFalse(out.contains("%@"), "\(locale):\n\(out)")
            XCTAssertTrue(out.contains("xcodevaultctl plan delete | park | external"), locale)
        }
    }

    func testAmountsAreAlignedInJapanese() {
        L10n.configure(override: "ja", environment: [:], preferred: [])
        let lines = TextRenderer.savings(summary(), runtimeImageBytes: 0).split(separator: "\n").map(String.init)
        // Heading, Temporary, delete, park, Permanent, run, Total, note, Stays, Next.
        let rows = [lines[2], lines[3], lines[5]]
        let widths = rows.map { row -> Int in
            let amounts = [30_100_000_000, 12_200_000_000, 8_000_000_000].map { ByteCount.format(UInt64($0)) }
            guard let a = amounts.first(where: { row.contains($0) }), let r = row.range(of: a) else { return -1 }
            return TextRenderer.displayWidth(String(row[..<r.upperBound]))
        }
        XCTAssertFalse(widths.contains(-1), rows.joined(separator: "\n"))
        XCTAssertEqual(Set(widths).count, 1, "\(widths)\n\(rows.joined(separator: "\n"))")
    }

    func testDisplayWidthCountsWideCharactersTwice() {
        XCTAssertEqual(TextRenderer.displayWidth("abc"), 3)
        XCTAssertEqual(TextRenderer.displayWidth("外部"), 4)
        XCTAssertEqual(TextRenderer.displayWidth("—"), 1)
    }
}
