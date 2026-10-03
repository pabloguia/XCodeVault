import XCTest

@testable import XCodeVaultCore

/// The savings block of the CLI (spec 2026-10-03 §5): both headlines, every option, the next step; aligned
/// for wide scripts; never a raw key.
final class SavingsTextTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func summary(lowerBound: Bool = false) -> SavingsSummary {
        var s = SavingsSummary()
        s.deleteAndRegenerate.optionBytes = 30_100_000_000
        s.parkExternally.optionBytes = 12_200_000_000
        s.runFromExternal.optionBytes = 8_000_000_000
        s.temporaryBytes = 42_300_000_000
        s.permanentBytes = 8_000_000_000
        s.reclaimableBytes = 50_300_000_000
        s.keepLocal.primaryBytes = 3_100_000_000
        s.verifiedTemporaryBytes = 12_100_000_000
        s.isLowerBound = lowerBound
        return s
    }

    func testTheBlockShowsBothHeadlinesEveryBucketAndTheNextStep() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary())
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

    func testALowerBoundSaysAtLeastEverywhere() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let out = TextRenderer.savings(summary(lowerBound: true))
        XCTAssertFalse(out.contains("up to"), out)
        XCTAssertTrue(out.contains("at least"), out)
    }

    func testEveryLanguageRendersWithoutLeakingKeys() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let out = TextRenderer.savings(summary())
            XCTAssertFalse(out.contains("savings."), "\(locale):\n\(out)")
            XCTAssertFalse(out.contains("cli."), "\(locale):\n\(out)")
            XCTAssertFalse(out.contains("%@"), "\(locale):\n\(out)")
            XCTAssertTrue(out.contains("xcodevaultctl plan delete | park | external"), locale)
        }
    }

    func testAmountsAreAlignedInJapanese() {
        L10n.configure(override: "ja", environment: [:], preferred: [])
        let lines = TextRenderer.savings(summary()).split(separator: "\n").map(String.init)
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
