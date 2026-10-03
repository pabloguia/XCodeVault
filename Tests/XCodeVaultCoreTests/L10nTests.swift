import XCTest

@testable import XCodeVaultCore

/// The localization runtime (spec 2026-10-03 §4). Uses an inline catalog so it does not depend on the
/// generated table; the shipped strings are checked by `scripts/l10n.sh check` and `CoreStringsTests`.
final class L10nTests: XCTestCase {
    private let catalog = L10nCatalog(
        strings: [
            "greet": ["en": "Hello %@", "pt-BR": "Olá %@", "ja": "%@ さん、こんにちは"],
            "onlyEnglish": ["en": "English only"],
            "percent": ["en": "100% sure"],
        ],
        plurals: [
            "files": [
                "en": ["one": "%lld file", "other": "%lld files"],
                "pt-BR": ["one": "%lld arquivo", "other": "%lld arquivos"],
                "ja": ["other": "%lld 個のファイル"],
            ]
        ])

    func testTheLocaleListIsTheFiveShippedLanguagesBaseFirst() {
        XCTAssertEqual(L10n.supportedLocales, ["en", "pt-BR", "es", "ja", "zh-Hans"])
        XCTAssertEqual(L10n.baseLocale, "en")
    }

    func testMatchingMapsRegionalAndScriptVariants() {
        XCTAssertEqual(L10n.match("pt-BR"), "pt-BR")
        XCTAssertEqual(L10n.match("pt_PT"), "pt-BR")
        XCTAssertEqual(L10n.match("es-MX"), "es")
        XCTAssertEqual(L10n.match("ja-JP"), "ja")
        XCTAssertEqual(L10n.match("zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(L10n.match("zh-CN"), "zh-Hans")
        XCTAssertEqual(L10n.match("ZH-HANS"), "zh-Hans")
        // Traditional Chinese is not shipped; falling to Simplified would be wrong, so it does not match.
        XCTAssertNil(L10n.match("zh-Hant-TW"))
        XCTAssertNil(L10n.match("zh-TW"))
        XCTAssertNil(L10n.match("zh-HK"))
        XCTAssertNil(L10n.match("zh-Hant-HK"))
        // An explicit Simplified script wins over a Traditional-script region (spec §4.2).
        XCTAssertEqual(L10n.match("zh-Hans-HK"), "zh-Hans")
        XCTAssertEqual(L10n.match("zh-Hans-TW"), "zh-Hans")
        XCTAssertEqual(L10n.match("zh-Hans-MO"), "zh-Hans")
        XCTAssertNil(L10n.match("fr-FR"))
        XCTAssertNil(L10n.match(""))
    }

    func testResolutionOrderIsOverrideThenPreferencesThenEnglish() {
        XCTAssertEqual(L10n.resolve(override: "ja", preferred: ["pt-BR"]), "ja")
        XCTAssertEqual(L10n.resolve(override: "fr", preferred: ["fr-FR", "es-ES"]), "es", "an unsupported override falls through")
        XCTAssertEqual(L10n.resolve(override: nil, preferred: ["zh-Hant-TW", "pt-BR"]), "pt-BR")
        XCTAssertEqual(L10n.resolve(override: nil, preferred: ["fr"]), "en")
        XCTAssertEqual(L10n.resolve(override: nil, preferred: []), "en")
    }

    func testLookupFallsBackToEnglishThenToTheKey() {
        XCTAssertEqual(L10n.string("greet", in: catalog, locale: "pt-BR", arguments: ["Ana"]), "Olá Ana")
        XCTAssertEqual(L10n.string("greet", in: catalog, locale: "ja", arguments: ["Ana"]), "Ana さん、こんにちは")
        XCTAssertEqual(L10n.string("onlyEnglish", in: catalog, locale: "es", arguments: []), "English only")
        XCTAssertEqual(L10n.string("missing.key", in: catalog, locale: "en", arguments: []), "missing.key")
    }

    func testATemplateWithoutArgumentsIsNotFormatted() {
        // `String(format:)` on "100% sure" with no arguments would read "% s" as a specifier.
        XCTAssertEqual(L10n.string("percent", in: catalog, locale: "en", arguments: []), "100% sure")
    }

    func testPluralCategoriesFollowCLDRForEachShippedLanguage() {
        XCTAssertEqual(L10n.pluralCategory(locale: "en", count: 1), "one")
        XCTAssertEqual(L10n.pluralCategory(locale: "en", count: 0), "other")
        XCTAssertEqual(L10n.pluralCategory(locale: "es", count: 1), "one")
        XCTAssertEqual(L10n.pluralCategory(locale: "es", count: 2), "other")
        // CLDR: Portuguese `one` covers 0 and 1.
        XCTAssertEqual(L10n.pluralCategory(locale: "pt-BR", count: 0), "one")
        XCTAssertEqual(L10n.pluralCategory(locale: "pt-BR", count: 1), "one")
        XCTAssertEqual(L10n.pluralCategory(locale: "pt-BR", count: 2), "other")
        for locale in ["ja", "zh-Hans"] {
            for n in [0, 1, 2] { XCTAssertEqual(L10n.pluralCategory(locale: locale, count: n), "other", "\(locale) \(n)") }
        }
    }

    func testPluralsFormatTheCountAndFallBack() {
        XCTAssertEqual(L10n.plural("files", count: 1, in: catalog, locale: "en", arguments: []), "1 file")
        XCTAssertEqual(L10n.plural("files", count: 3, in: catalog, locale: "en", arguments: []), "3 files")
        XCTAssertEqual(L10n.plural("files", count: 0, in: catalog, locale: "pt-BR", arguments: []), "0 arquivo")
        XCTAssertEqual(L10n.plural("files", count: 1, in: catalog, locale: "ja", arguments: []), "1 個のファイル")
        XCTAssertEqual(L10n.plural("files", count: 2, in: catalog, locale: "es", arguments: []), "2 files", "no Spanish: English")
        XCTAssertEqual(L10n.plural("nope", count: 2, in: catalog, locale: "en", arguments: []), "nope")
    }

    func testTheLanguageOverrideIsRemovedFromTheArguments() {
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["scan", "--lang", "ja", "--json"]).language, "ja")
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["scan", "--lang", "ja", "--json"]).remaining, ["scan", "--json"])
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["--lang=pt-BR", "status"]).language, "pt-BR")
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["--lang=pt-BR", "status"]).remaining, ["status"])
        // After `--` every argument is the command's, even one spelled like the flag.
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["x", "--", "--lang", "ja"]).language, nil)
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["x", "--", "--lang", "ja"]).remaining, ["x", "--", "--lang", "ja"])
        // A trailing `--lang` with no value is left for the parser to reject, not silently dropped.
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["scan", "--lang"]).remaining, ["scan", "--lang"])
        // A flag where the value should be is not a value: both stay, so ArgumentParser rejects `--lang`.
        XCTAssertNil(L10n.extractLanguageOverride(from: ["permissions", "--lang", "--json"]).language)
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["permissions", "--lang", "--json"]).remaining, ["permissions", "--lang", "--json"])
        XCTAssertNil(L10n.extractLanguageOverride(from: ["--lang", "-h"]).language)
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["--lang", "-h"]).remaining, ["--lang", "-h"])
        // An empty `--lang=` is not a language either.
        XCTAssertNil(L10n.extractLanguageOverride(from: ["--lang="]).language)
        XCTAssertEqual(L10n.extractLanguageOverride(from: ["--lang="]).remaining, ["--lang="])
    }

    func testConfigureSetsTheProcessLocale() {
        let before = L10n.locale
        defer { L10n.configure(override: before, environment: [:], preferred: []) }
        L10n.configure(override: "zh-CN", environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "zh-Hans")
        L10n.configure(override: nil, environment: [:], preferred: ["es-AR"])
        XCTAssertEqual(L10n.locale, "es")
    }

    func testTheEnvironmentComesAfterTheOverrideAndBeforePreferences() {
        let before = L10n.locale
        defer { L10n.configure(override: before, environment: [:], preferred: []) }
        let env = ["XCODEVAULT_LANG": "es"]
        L10n.configure(override: "ja", environment: env, preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "ja")
        L10n.configure(override: nil, environment: env, preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "es")
        L10n.configure(override: "fr", environment: env, preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "es")
    }

    func testATemplateWithTooFewArgumentsFallsBackInsteadOfCrashing() {
        let c = L10nCatalog(
            strings: ["x": ["en": "A %@", "pt-BR": "B %@ %@"], "y": ["en": "%@ %@"], "z": ["en": "100%% %@"]],
            plurals: [:])
        XCTAssertEqual(L10n.string("x", in: c, locale: "pt-BR", arguments: ["1"]), "A 1")
        XCTAssertEqual(L10n.string("y", in: c, locale: "en", arguments: ["1"]), "%@ %@")
        XCTAssertEqual(L10n.string("z", in: c, locale: "en", arguments: ["1"]), "100% 1")
    }

    /// The runtime counts specifiers with the checker's pattern (scripts/l10n/l10n.swift), so a width or precision
    /// is a specifier too; and a template with a `%` it cannot account for is never handed to `String(format:)`.
    func testAnUnsupportedOrUndercountedTemplateIsNeverFormatted() {
        let c = L10nCatalog(
            strings: [
                "precision": ["en": "%@ of all", "pt-BR": "%.1f de %@"],
                "precisionOnly": ["en": "%.1f of %@"],
                "substitution": ["en": "%@ files", "ja": "%#@files@"],
                "substitutionOnly": ["en": "%#@files@"],
                "stray": ["en": "%@ done", "es": "%@ al 50%z"],
                "literal": ["en": "100%% %@"],
            ],
            plurals: [:])
        XCTAssertEqual(L10n.string("precision", in: c, locale: "pt-BR", arguments: ["1"]), "1 of all")
        XCTAssertEqual(L10n.string("precisionOnly", in: c, locale: "en", arguments: ["1"]), "%.1f of %@")
        XCTAssertEqual(L10n.string("substitution", in: c, locale: "ja", arguments: ["3"]), "3 files")
        XCTAssertEqual(L10n.string("substitutionOnly", in: c, locale: "en", arguments: ["3"]), "%#@files@")
        XCTAssertEqual(L10n.string("stray", in: c, locale: "es", arguments: ["x"]), "x done")
        XCTAssertEqual(L10n.string("literal", in: c, locale: "en", arguments: ["1"]), "100% 1")
    }
}
