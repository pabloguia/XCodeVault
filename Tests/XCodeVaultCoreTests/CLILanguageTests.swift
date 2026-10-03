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
        // `--json` is an API (spec §4.3): the same report encodes byte-identically whatever the locale.
        let report = Fixtures.minimalReport()
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try JSONOutput.encode(report)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(try JSONOutput.encode(report), english, locale)
        }
    }
}
