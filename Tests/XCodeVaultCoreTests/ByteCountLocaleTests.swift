import XCTest

@testable import XCodeVaultCore

/// Spec §5.1: a run in English prints `10.37 GB` on any machine, whatever its region settings.
final class ByteCountLocaleTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheSeparatorFollowsTheChosenLanguageNotTheMachine() {
        XCTAssertTrue(ByteCount.format(10_370_000_000, locale: "en").contains("10.37"), ByteCount.format(10_370_000_000, locale: "en"))
        XCTAssertTrue(ByteCount.format(10_370_000_000, locale: "pt-BR").contains("10,37"), ByteCount.format(10_370_000_000, locale: "pt-BR"))
        XCTAssertTrue(ByteCount.format(10_370_000_000, locale: "es").contains("10,37"), ByteCount.format(10_370_000_000, locale: "es"))
    }

    func testTheUnsignedOverloadUsesTheProcessLocale() {
        L10n.configure(override: "pt-BR", environment: [:], preferred: [])
        XCTAssertEqual(ByteCount.format(UInt64(10_370_000_000)), ByteCount.format(10_370_000_000, locale: "pt-BR"))
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(ByteCount.format(UInt64(10_370_000_000)), ByteCount.format(10_370_000_000, locale: "en"))
    }

    func testZeroIsANumberNotAWord() {
        // The old formatter had `allowsNonnumericFormatting = false`: "Zero KB" must not appear in any language.
        for locale in L10n.supportedLocales {
            XCTAssertTrue(ByteCount.format(0, locale: locale).contains("0"), locale)
            XCTAssertFalse(ByteCount.format(0, locale: locale).lowercased().contains("zero"), locale)
        }
        XCTAssertTrue(ByteCount.format(1_000, locale: "en").contains("1"))
    }

    func testUnitsAreDecimalLikeFinder() {
        XCTAssertTrue(ByteCount.format(1_000_000_000, locale: "en").hasPrefix("1"), "1 GB, not 0.93 GiB")
    }

    func testTheJournalSummaryStaysEnglishWhateverTheLanguage() {
        L10n.configure(override: "pt-BR", environment: [:], preferred: [])
        XCTAssertEqual(MigrationEngine.verifiedSummary(files: 3, bytes: 10_370_000_000), "copied and verified 3 files, 10.37 GB; source intact")
    }
}
