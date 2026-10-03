import XCTest

@testable import XCodeVaultCore

/// The shipped strings, as the binary sees them. `scripts/l10n.sh check` guards completeness and
/// placeholders at the catalog level; this guards that the compiled table is the one in use.
final class CoreStringsTests: XCTestCase {
    func testEveryBucketHasADistinctNonEmptyTextInEveryLanguage() {
        for locale in L10n.supportedLocales {
            var titles = Set<String>()
            for bucket in SavingsBucket.allCases {
                let title = L10n.string("savings.bucket.\(bucket.rawValue).title", in: .core, locale: locale, arguments: [])
                XCTAssertFalse(title.hasPrefix("savings."), "\(locale) \(bucket): key leaked, string missing")
                titles.insert(title)
                for part in ["promise", "undoCost"] {
                    let text = L10n.string("savings.bucket.\(bucket.rawValue).\(part)", in: .core, locale: locale, arguments: [])
                    XCTAssertFalse(text.hasPrefix("savings."), "\(locale) \(bucket) \(part)")
                }
            }
            XCTAssertEqual(titles.count, SavingsBucket.allCases.count, "\(locale): two buckets share a title")
        }
    }

    func testNonEnglishLanguagesAreActuallyTranslated() {
        let english = L10n.string("savings.bucket.parkExternally.title", in: .core, locale: "en", arguments: [])
        for locale in L10n.supportedLocales where locale != "en" {
            XCTAssertNotEqual(L10n.string("savings.bucket.parkExternally.title", in: .core, locale: locale, arguments: []), english, locale)
        }
    }

    func testTheUpToHeadlineFormatsInEveryLanguage() {
        for locale in L10n.supportedLocales {
            let s = L10n.string("savings.upTo", in: .core, locale: locale, arguments: ["12 GB"])
            XCTAssertTrue(s.contains("12 GB"), "\(locale): \(s)")
        }
    }

    func testTheCategoryCountPluralises() {
        XCTAssertEqual(L10n.plural("savings.categoryCount", count: 1, in: .core, locale: "en", arguments: []), "1 category")
        XCTAssertEqual(L10n.plural("savings.categoryCount", count: 3, in: .core, locale: "en", arguments: []), "3 categories")
        XCTAssertEqual(L10n.plural("savings.categoryCount", count: 3, in: .core, locale: "pt-BR", arguments: []), "3 categorias")
    }

    func testTheConvenienceAccessorsUseTheProcessLocale() {
        let before = L10n.locale
        defer { L10n.configure(override: before, environment: [:], preferred: []) }
        L10n.configure(override: "pt-BR", environment: [:], preferred: [])
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.localizedTitle, "Apagar — volta quando precisar")
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.localizedTitle, "Delete — comes back on demand")
        XCTAssertEqual(L10n.tr("savings.atLeast", "5 GB"), "at least 5 GB")
    }
}
