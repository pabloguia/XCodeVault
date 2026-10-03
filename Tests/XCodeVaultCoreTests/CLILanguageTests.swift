import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

final class CLILanguageTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheFlagWinsOverTheEnvironmentAndIsRemoved() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["status", "--lang", "ja"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["pt-BR"])
        XCTAssertEqual(r.remaining, ["status"])
        XCTAssertNil(r.warning)
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testJSONForcesEnglishWhateverTheFlag() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["doctor", "--json", "--lang", "pt-BR"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["ja"])
        XCTAssertEqual(L10n.locale, "en")
        XCTAssertEqual(r.remaining, ["doctor", "--json"])
    }

    func testAFlagNamedJSONAfterTheSeparatorIsNotTheFlag() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "ja", "x", "--", "--json"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testTheLanguageFlagStillWorksWithoutJSON() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "ja", "status"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testTheEnvironmentWinsOverPreferences() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["status"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "es")
    }

    func testAnUnsupportedFlagWarnsAndFallsThrough() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "fr"], environment: [:], preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "pt-BR")
        XCTAssertEqual(r.warning, "xcodevaultctl: language 'fr' is not available; using pt-BR. Available: en, pt-BR, es, ja, zh-Hans")
    }

    func testJSONIsTheSameInEveryLanguage() throws {
        // `--json` is an API (spec §4.3): the same report encodes byte-identically whatever the locale. Non-zero
        // savings, so the localized vocabulary has something to leak into if it ever reached the encoder.
        var report = Fixtures.minimalReport()
        report.savings.deleteAndRegenerate.optionBytes = 42
        report.savings.temporaryBytes = 42
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try JSONOutput.encode(report)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(try JSONOutput.encode(report), english, locale)
        }
        XCTAssertTrue(english.contains("42"), "the savings were encoded")
    }

    func testPermissionsJSONIsTheSameInEveryLanguage() throws {
        // `permissions --json` encodes the `PermissionsReport` that `PermissionsCommand.report` builds; its texts are
        // taken when it is built, so it is built under each locale for every state it can report.
        func encodedReports() throws -> [String] {
            try FullDiskAccessState.allCases.flatMap { access in
                try HelperState.allCases.map { try JSONOutput.encode(PermissionsReport(fullDiskAccess: access, helper: $0)) }
            }
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try encodedReports()
        XCTAssertEqual(english.count, FullDiskAccessState.allCases.count * HelperState.allCases.count)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(try encodedReports(), english, locale)
        }
    }

    func testTheHelpNamesTheLanguagesFromTheOneList() throws {
        let discussion = XCodeVaultCTL.configuration.discussion
        XCTAssertTrue(discussion.contains("--lang <code> (\(L10n.supportedLocales.joined(separator: ", ")))"), discussion)
    }
}
