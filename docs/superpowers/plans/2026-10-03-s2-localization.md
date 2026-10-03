# S2 — Localization Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship English, Brazilian Portuguese, Spanish, Japanese and Simplified Chinese through a String Catalog compiled into the binaries, with a CI gate and a documented path for adding languages; localize the savings vocabulary from S1 as the first strings.

**Architecture:** `Sources/XCodeVaultCore/Localization/Localizable.xcstrings` is the source of truth (Xcode-editable). `scripts/l10n.sh` drives a Swift script that compiles it into `CoreStrings.generated.swift` — a static dictionary, so there is **no runtime resource bundle** and the stand-alone/Homebrew `xcodevaultctl` cannot crash on a missing `Bundle.module`. `L10n` in Core resolves the locale (`--lang` → `XCODEVAULT_LANG` → system preferences → `en`) and formats strings and plurals. `--json` output is never localized.

**Tech Stack:** Swift 6, SwiftPM, XCTest, bash; the script runs with `swift <file>` (no new dependency).

**Spec:** `docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md` §4. Depends on S1 (`SavingsBucket`) for Task 4 only.

## Global Constraints

- Supported locales, exactly and in this order: `en`, `pt-BR`, `es`, `ja`, `zh-Hans`. Base/fallback: `en`.
- The single list of supported locales is `L10n.supportedLocales` in `L10n.swift`; the script reads it from there. Never a second list.
- Keys are stable identifiers (`savings.bucket.<case>.title`), never English sentences.
- Every non-English string ships with `"state" : "needs_review"` until a native speaker reviews it (spec §4.4, operator decision 2).
- Never localized: `--json` output, journal entries, category ids, command names, flags, paths, evidence files, the typed `--i-confirm-…` flags.
- Every `L10n.tr` / `L10n.plural` call uses a **string literal** key, so the checker can verify it exists. Dynamic keys are a review failure.
- Swift 6, macOS 14+, 4-space indent, 160 columns; `swift-format lint --strict` must pass. The generated file starts with `// swift-format-ignore-file`.
- Slow machine: `swift test --filter <Class>`, and confirm "Executed N tests" with N > 0.
- `scripts/preflight.sh` gate list and `.github/workflows/ci.yml` must change together (preflight checks the step count).

---

### Task 1: `L10n` runtime (resolution, lookup, plurals, `--lang` extraction)

**Files:**
- Create: `Sources/XCodeVaultCore/Localization/L10n.swift`
- Test: `Tests/XCodeVaultCoreTests/L10nTests.swift`

**Interfaces:**
- Produces:
  - `public struct L10nCatalog: Sendable { public let strings: [String: [String: String]]; public let plurals: [String: [String: [String: String]]]; public init(strings:plurals:) }` — `strings[key][locale]`, `plurals[key][locale][category]`.
  - `public enum L10n` with:
    - `public static let supportedLocales: [String]`, `public static let baseLocale: String`
    - `public static var locale: String { get }`
    - `public static func configure(override: String?, preferred: [String] = Locale.preferredLanguages)`
    - `public static func resolve(override: String?, preferred: [String]) -> String`
    - `public static func match(_ tag: String) -> String?`
    - `public static func string(_ key: String, in catalog: L10nCatalog, locale: String, arguments: [CVarArg]) -> String`
    - `public static func plural(_ key: String, count: Int, in catalog: L10nCatalog, locale: String, arguments: [CVarArg]) -> String`
    - `public static func pluralCategory(locale: String, count: Int) -> String`
    - `public static func extractLanguageOverride(from arguments: [String]) -> (language: String?, remaining: [String])`

- [ ] **Step 1: Write the failing tests**

```swift
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
    }

    func testConfigureSetsTheProcessLocale() {
        let before = L10n.locale
        defer { L10n.configure(override: before, preferred: []) }
        L10n.configure(override: "zh-CN", preferred: [])
        XCTAssertEqual(L10n.locale, "zh-Hans")
        L10n.configure(override: nil, preferred: ["es-AR"])
        XCTAssertEqual(L10n.locale, "es")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter L10nTests 2>&1 | tail -20`
Expected: build failure, "cannot find 'L10nCatalog' in scope".

- [ ] **Step 3: Implement `L10n.swift`**

```swift
import Foundation

/// A compiled String Catalog: `strings[key][locale]` and `plurals[key][locale][CLDR category]`. Built by
/// `scripts/l10n.sh gen` from an `.xcstrings` file; never edited by hand.
public struct L10nCatalog: Sendable {
    public let strings: [String: [String: String]]
    public let plurals: [String: [String: [String: String]]]
    public init(strings: [String: [String: String]], plurals: [String: [String: [String: String]]]) {
        self.strings = strings
        self.plurals = plurals
    }
}

/// Localization (spec 2026-10-03 §4). Compiled tables instead of `Bundle.module`, so a binary copied on its
/// own — the Homebrew CLI — has every language and cannot trap on a missing resource bundle.
public enum L10n {
    /// The one list. `scripts/l10n.sh` reads this line; adding a language starts here (docs/process/LOCALIZATION.md).
    public static let supportedLocales = ["en", "pt-BR", "es", "ja", "zh-Hans"]
    public static let baseLocale = "en"

    private static let state = LocaleState(
        resolve(override: ProcessInfo.processInfo.environment["XCODEVAULT_LANG"], preferred: Locale.preferredLanguages))

    /// The locale every `tr`/`plural` without an explicit locale uses.
    public static var locale: String { state.value }

    /// Called once by the CLI before parsing (with `--lang`) and available to tests. The app does not call
    /// it: the initial value already follows the user's language preferences.
    public static func configure(override: String?, preferred: [String] = Locale.preferredLanguages) {
        state.value = resolve(override: override, preferred: preferred)
    }

    /// First supported match among the override and then the preferences; `en` when none matches. An
    /// unsupported override falls through rather than failing: the caller decides whether to warn.
    public static func resolve(override: String?, preferred: [String]) -> String {
        for tag in [override].compactMap({ $0 }) + preferred {
            if let match = match(tag) { return match }
        }
        return baseLocale
    }

    /// Maps a BCP 47 / Apple language tag to a shipped locale. Portuguese of any region reads pt-BR; Chinese
    /// matches only when Simplified (`Hans`, or a mainland/Singapore region, or no qualifier).
    public static func match(_ tag: String) -> String? {
        let normalized = tag.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supportedLocales.first(where: { $0.lowercased() == normalized }) { return exact }
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return nil }
        switch language {
        case "zh":
            let qualifiers = Set(parts.dropFirst())
            return qualifiers.isDisjoint(with: ["hant", "tw", "hk", "mo"]) ? "zh-Hans" : nil
        case "pt":
            return "pt-BR"
        default:
            return supportedLocales.first { $0.lowercased() == language }
        }
    }

    /// The string for `key` in `locale`, else in English, else the key itself — a visible key is a bug
    /// report, a blank is not. Formatted only when there are arguments, so a literal `%` survives.
    public static func string(_ key: String, in catalog: L10nCatalog, locale: String, arguments: [CVarArg]) -> String {
        let entry = catalog.strings[key]
        guard let template = entry?[locale] ?? entry?[baseLocale] else { return key }
        return format(template, locale: locale, arguments: arguments)
    }

    /// The plural form of `key` for `count`; the count is the first format argument (`%lld`).
    public static func plural(_ key: String, count: Int, in catalog: L10nCatalog, locale: String, arguments: [CVarArg]) -> String {
        guard let forms = catalog.plurals[key] else { return key }
        let chosenLocale = forms[locale] != nil ? locale : baseLocale
        guard let table = forms[chosenLocale] else { return key }
        let category = pluralCategory(locale: chosenLocale, count: count)
        guard let template = table[category] ?? table["other"] else { return key }
        return format(template, locale: chosenLocale, arguments: [count] + arguments)
    }

    /// CLDR cardinal categories for integers in the shipped languages. A new language adds its rule here
    /// (docs/process/LOCALIZATION.md); unknown locales use `other`.
    public static func pluralCategory(locale: String, count: Int) -> String {
        switch locale {
        case "en", "es": return count == 1 ? "one" : "other"
        case "pt-BR": return count == 0 || count == 1 ? "one" : "other"
        default: return "other"
        }
    }

    /// Removes `--lang <code>` / `--lang=<code>` before ArgumentParser sees the arguments: help text is built
    /// before any option is parsed, so the language must be known first. Stops at `--`.
    public static func extractLanguageOverride(from arguments: [String]) -> (language: String?, remaining: [String]) {
        var language: String?
        var remaining: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                remaining.append(contentsOf: arguments[index...])
                break
            }
            if argument.hasPrefix("--lang=") {
                language = String(argument.dropFirst("--lang=".count))
            } else if argument == "--lang", index + 1 < arguments.count {
                language = arguments[index + 1]
                index += 1
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        return (language, remaining)
    }

    private static func format(_ template: String, locale: String, arguments: [CVarArg]) -> String {
        arguments.isEmpty ? template : String(format: template, locale: Locale(identifier: locale), arguments: arguments)
    }
}

/// The process-wide locale behind a lock (macOS 14 has no `Synchronization.Mutex`).
private final class LocaleState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    init(_ initial: String) { current = initial }
    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter L10nTests 2>&1 | tail -20`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/XCodeVaultCore/Localization/L10n.swift Tests/XCodeVaultCoreTests/L10nTests.swift
git commit -m "L10n: locale resolution, lookup with English fallback, CLDR plurals, --lang extraction (S2)"
```

---

### Task 2: The catalog compiler and checker (`scripts/l10n.sh`)

**Files:**
- Create: `scripts/l10n/l10n.swift`
- Create: `scripts/l10n.sh`
- Create: `scripts/test-l10n.sh`

**Interfaces:**
- Produces:
  - `scripts/l10n.sh gen` — regenerate every module's table.
  - `scripts/l10n.sh check` — exit non-zero on: a stale generated file; a key missing a supported locale; an empty value; a plural without `other`; a placeholder multiset that differs from English; a literal `L10n.tr("…")`/`L10n.plural("…")`/`L10n.trCore("…")` key in `Sources/` absent from the catalog. Prints, informationally, how many strings per locale are `needs_review`.
  - `scripts/l10n.sh add <locale>` — seed every key for `<locale>` with an English copy marked `needs_review`.
  - Script CLI (`swift scripts/l10n/l10n.swift`): `gen <catalog> <out> <name> --locales a,b`, `check <catalog> <out> <name> --locales a,b --sources <dir>`, `add <catalog> <locale>`.
  - Generated Swift: `extension L10nCatalog { static let <name> = L10nCatalog(strings: [...], plurals: [...]) }` (internal).

- [ ] **Step 1: Write the failing script test `scripts/test-l10n.sh`**

```bash
#!/usr/bin/env bash
# Tests for scripts/l10n/l10n.swift: every refusal `check` makes is triggered once, and the happy path passes.
# Runs against a scratch catalog; touches nothing in the repository.
set -u
cd "$(dirname "$0")/.."
tool=(swift scripts/l10n/l10n.swift)
work=$(mktemp -d -t xcv-l10n-test)
trap 'rm -rf "$work"' EXIT
fail=0
pass=0

catalog() {  # $1: JSON body of "strings"
    printf '{"sourceLanguage":"en","version":"1.0","strings":{%s}}' "$1" >"$work/c.xcstrings"
}
good='"a.b":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Up to %@"}},"ja":{"stringUnit":{"state":"needs_review","value":"最大 %@"}}}},
"n.c":{"localizations":{"en":{"variations":{"plural":{"one":{"stringUnit":{"state":"translated","value":"%lld file"}},"other":{"stringUnit":{"state":"translated","value":"%lld files"}}}}},"ja":{"variations":{"plural":{"other":{"stringUnit":{"state":"needs_review","value":"%lld 個"}}}}}}}'
mkdir -p "$work/src"
printf 'let x = L10n.tr("a.b", "1 GB")\nlet y = L10n.plural("n.c", count: 2)\n' >"$work/src/Use.swift"

expect() {  # $1 description, $2 expected exit (0 or nonzero), rest: command
    local desc=$1 want=$2; shift 2
    "$@" >"$work/out" 2>&1; local got=$?
    if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" != 0 ] && [ "$got" != 0 ]; }; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: $desc (exit $got)"; sed 's/^/    /' "$work/out"
    fi
}
check() { "${tool[@]}" check "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja --sources "$work/src"; }

catalog "$good"
expect "gen succeeds" 0 "${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja
expect "check passes on a fresh table" 0 check
grep -q 'static let test = L10nCatalog' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: generated name"; }
grep -q '"最大 %@"' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: unicode kept literally"; }
grep -q 'swift-format-ignore-file' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: format ignore header"; }

echo '// edited' >>"$work/T.generated.swift"
expect "check refuses a stale table" 1 check

catalog "${good/,\"ja\":\{\"stringUnit\":\{\"state\":\"needs_review\",\"value\":\"最大 %@\"\}\}/}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses a missing locale" 1 check

catalog "${good/最大 %@/最大}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses a placeholder mismatch" 1 check

catalog "${good/\"value\":\"最大 %@\"/\"value\":\"\"}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses an empty value" 1 check

catalog "$good"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
printf 'let z = L10n.tr("not.in.catalog")\n' >>"$work/src/Use.swift"
expect "check refuses an unknown key in sources" 1 check

printf 'let x = L10n.tr("a.b", "1 GB")\n' >"$work/src/Use.swift"
catalog "$good"
expect "add seeds a new locale" 0 "${tool[@]}" add "$work/c.xcstrings" es
grep -q '"es"' "$work/c.xcstrings" || { fail=$((fail + 1)); echo "FAIL: add wrote es"; }
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja,es >/dev/null 2>&1
expect "a seeded locale passes check" 0 "${tool[@]}" check "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja,es --sources "$work/src"

echo "test-l10n: $pass passed, $fail failed"
[ "$fail" = 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/test-l10n.sh`
Expected: failures — "scripts/l10n/l10n.swift" does not exist.

- [ ] **Step 3: Implement `scripts/l10n/l10n.swift`**

```swift
// Compiles and checks String Catalogs for XCodeVault (docs/process/LOCALIZATION.md).
// Usage:
//   swift scripts/l10n/l10n.swift gen   <catalog.xcstrings> <out.swift> <name> --locales en,pt-BR,...
//   swift scripts/l10n/l10n.swift check <catalog.xcstrings> <out.swift> <name> --locales ... --sources <dir>
//   swift scripts/l10n/l10n.swift add   <catalog.xcstrings> <locale>
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("l10n: " + message + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func loadCatalog(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fail("cannot read \(path)") }
    return json
}

/// key -> locale -> value, and key -> locale -> category -> value.
func flatten(_ catalog: [String: Any]) -> (strings: [String: [String: String]], plurals: [String: [String: [String: String]]], review: [String: Int]) {
    var strings: [String: [String: String]] = [:]
    var plurals: [String: [String: [String: String]]] = [:]
    var review: [String: Int] = [:]
    let entries = catalog["strings"] as? [String: Any] ?? [:]
    for (key, raw) in entries {
        let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        for (locale, rawLocalization) in localizations {
            let localization = rawLocalization as? [String: Any] ?? [:]
            if let unit = localization["stringUnit"] as? [String: Any] {
                strings[key, default: [:]][locale] = unit["value"] as? String ?? ""
                if unit["state"] as? String == "needs_review" { review[locale, default: 0] += 1 }
            }
            let forms = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
            for (category, rawForm) in forms {
                let unit = (rawForm as? [String: Any])?["stringUnit"] as? [String: Any] ?? [:]
                plurals[key, default: [:]][locale, default: [:]][category] = unit["value"] as? String ?? ""
                if unit["state"] as? String == "needs_review" { review[locale, default: 0] += 1 }
            }
        }
    }
    return (strings, plurals, review)
}

func literal(_ s: String) -> String { String(reflecting: s) }

func generate(catalogPath: String, name: String, locales: [String]) -> String {
    let (strings, plurals, _) = flatten(loadCatalog(catalogPath))
    let order = { (a: String, b: String) in (locales.firstIndex(of: a) ?? .max, a) < (locales.firstIndex(of: b) ?? .max, b) }
    var out = "// swift-format-ignore-file\n"
    out += "// Generated by scripts/l10n.sh from \((catalogPath as NSString).lastPathComponent). Do not edit.\n\n"
    out += "extension L10nCatalog {\n    static let \(name) = L10nCatalog(\n        strings: [\n"
    for key in strings.keys.sorted() {
        out += "            \(literal(key)): [\n"
        for locale in strings[key]!.keys.sorted(by: order) { out += "                \(literal(locale)): \(literal(strings[key]![locale]!)),\n" }
        out += "            ],\n"
    }
    if strings.isEmpty { out += "            :\n" }
    out += "        ],\n        plurals: [\n"
    for key in plurals.keys.sorted() {
        out += "            \(literal(key)): [\n"
        for locale in plurals[key]!.keys.sorted(by: order) {
            out += "                \(literal(locale)): [\n"
            for category in plurals[key]![locale]!.keys.sorted() {
                out += "                    \(literal(category)): \(literal(plurals[key]![locale]![category]!)),\n"
            }
            out += "                ],\n"
        }
        out += "            ],\n"
    }
    if plurals.isEmpty { out += "            :\n" }
    out += "        ])\n}\n"
    return out
}

let specifier = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(lld|ld|d|@|f|s)")
func placeholders(_ s: String) -> [String] {
    specifier.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range(at: 1), in: s)!]) }.sorted()
}

let keyUse = try! NSRegularExpression(pattern: "L10n\\.(?:tr|plural|trCore)\\(\\s*\"([^\"]+)\"")
func referencedKeys(under directory: String) -> [String: String] {
    var found: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(atPath: directory)
    while let relative = enumerator?.nextObject() as? String {
        guard relative.hasSuffix(".swift"), !relative.hasSuffix(".generated.swift") else { continue }
        let path = directory + "/" + relative
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for m in keyUse.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            found[String(text[Range(m.range(at: 1), in: text)!])] = relative
        }
    }
    return found
}

func check(catalogPath: String, outPath: String, name: String, locales: [String], sources: String) -> Int32 {
    var problems: [String] = []
    let expected = generate(catalogPath: catalogPath, name: name, locales: locales)
    let actual = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    if actual != expected { problems.append("\(outPath) is stale: run scripts/l10n.sh gen") }
    let (strings, plurals, review) = flatten(loadCatalog(catalogPath))
    for (key, byLocale) in strings {
        let base = placeholders(byLocale["en"] ?? "")
        for locale in locales {
            guard let value = byLocale[locale] else { problems.append("\(key): missing \(locale)"); continue }
            if value.isEmpty { problems.append("\(key): empty \(locale)") }
            if placeholders(value) != base { problems.append("\(key): \(locale) placeholders \(placeholders(value)) ≠ en \(base)") }
        }
    }
    for (key, byLocale) in plurals {
        let base = placeholders(byLocale["en"]?["other"] ?? "")
        for locale in locales {
            guard let forms = byLocale[locale] else { problems.append("\(key): missing plural \(locale)"); continue }
            guard forms["other"] != nil else { problems.append("\(key): \(locale) has no 'other' form"); continue }
            for (category, value) in forms {
                if value.isEmpty { problems.append("\(key): empty \(locale)/\(category)") }
                if placeholders(value) != base { problems.append("\(key): \(locale)/\(category) placeholders ≠ en") }
            }
        }
    }
    let known = Set(strings.keys).union(plurals.keys)
    for (key, file) in referencedKeys(under: sources).sorted(by: { $0.key < $1.key }) where !known.contains(key) {
        problems.append("\(file): key \"\(key)\" is not in \((catalogPath as NSString).lastPathComponent)")
    }
    for locale in locales where (review[locale] ?? 0) > 0 { print("l10n: \(locale): \(review[locale]!) string(s) need native review") }
    for p in problems { FileHandle.standardError.write(Data(("l10n: " + p + "\n").utf8)) }
    return problems.isEmpty ? 0 : 1
}

func add(catalogPath: String, locale: String) {
    var catalog = loadCatalog(catalogPath)
    var entries = catalog["strings"] as? [String: Any] ?? [:]
    func seeded(_ unit: Any?) -> Any {
        var u = unit as? [String: Any] ?? [:]
        u["state"] = "needs_review"
        return u
    }
    for (key, raw) in entries {
        var entry = raw as? [String: Any] ?? [:]
        var localizations = entry["localizations"] as? [String: Any] ?? [:]
        guard localizations[locale] == nil, let english = localizations["en"] as? [String: Any] else { continue }
        var copy = english
        if let unit = english["stringUnit"] { copy["stringUnit"] = seeded(unit) }
        if var variations = english["variations"] as? [String: Any], var plural = variations["plural"] as? [String: Any] {
            for (category, form) in plural {
                var f = form as? [String: Any] ?? [:]
                f["stringUnit"] = seeded(f["stringUnit"])
                plural[category] = f
            }
            variations["plural"] = plural
            copy["variations"] = variations
        }
        localizations[locale] = copy
        entry["localizations"] = localizations
        entries[key] = entry
    }
    catalog["strings"] = entries
    let data = try! JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileManager.default.createFile(atPath: catalogPath, contents: data + Data("\n".utf8))
    print("l10n: seeded \(locale) in \(catalogPath); every string is marked needs_review")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: gen|check|add …") }
switch command {
case "gen":
    guard args.count >= 4, let locales = option("--locales", in: args) else { fail("usage: gen <catalog> <out> <name> --locales a,b") }
    let text = generate(catalogPath: args[1], name: args[3], locales: locales.split(separator: ",").map(String.init))
    FileManager.default.createFile(atPath: args[2], contents: Data(text.utf8))
case "check":
    guard args.count >= 4, let locales = option("--locales", in: args), let sources = option("--sources", in: args) else {
        fail("usage: check <catalog> <out> <name> --locales a,b --sources <dir>")
    }
    exit(check(catalogPath: args[1], outPath: args[2], name: args[3], locales: locales.split(separator: ",").map(String.init), sources: sources))
case "add":
    guard args.count == 3 else { fail("usage: add <catalog> <locale>") }
    add(catalogPath: args[1], locale: args[2])
default:
    fail("unknown command \(command)")
}
```

Note on the empty-table branch: the generator writes `[`, a line holding only `:`, then `]` — the empty dictionary literal `[:]` split across lines, which Swift accepts. `test-l10n.sh` does not cover it; the first catalog with no plurals will, at compile time.

- [ ] **Step 4: Implement the wrapper `scripts/l10n.sh`**

```bash
#!/usr/bin/env bash
# Localization driver (docs/process/LOCALIZATION.md).
#   scripts/l10n.sh gen            regenerate every compiled table
#   scripts/l10n.sh check          CI gate: stale tables, missing/empty/mismatched strings, unknown keys
#   scripts/l10n.sh add <locale>   seed a new locale (then add it to L10n.supportedLocales)
set -euo pipefail
cd "$(dirname "$0")/.."

# The one list of locales lives in L10n.swift; read it, never restate it.
locales=$(grep -E '^\s*public static let supportedLocales = \[' Sources/XCodeVaultCore/Localization/L10n.swift \
    | sed -E 's/.*\[(.*)\].*/\1/; s/[" ]//g')
[ -n "$locales" ] || { echo "l10n: cannot read L10n.supportedLocales" >&2; exit 2; }

# module catalog | generated table | static name
MODULES=(
    "Sources/XCodeVaultCore/Localization/Localizable.xcstrings|Sources/XCodeVaultCore/Localization/CoreStrings.generated.swift|core"
)

tool=(swift scripts/l10n/l10n.swift)
case "${1:-}" in
gen)
    for m in "${MODULES[@]}"; do IFS='|' read -r c o n <<<"$m"; "${tool[@]}" gen "$c" "$o" "$n" --locales "$locales"; done ;;
check)
    rc=0
    for m in "${MODULES[@]}"; do
        IFS='|' read -r c o n <<<"$m"
        "${tool[@]}" check "$c" "$o" "$n" --locales "$locales" --sources Sources || rc=1
    done
    exit $rc ;;
add)
    [ -n "${2:-}" ] || { echo "usage: scripts/l10n.sh add <locale>" >&2; exit 2; }
    for m in "${MODULES[@]}"; do IFS='|' read -r c _ _ <<<"$m"; "${tool[@]}" add "$c" "$2"; done
    echo "l10n: now add \"$2\" to L10n.supportedLocales and a plural rule to L10n.pluralCategory, then run: scripts/l10n.sh gen" ;;
*)
    echo "usage: scripts/l10n.sh gen | check | add <locale>" >&2; exit 2 ;;
esac
```

`chmod +x scripts/l10n.sh scripts/test-l10n.sh`.

- [ ] **Step 5: Run the script test**

Run: `bash scripts/test-l10n.sh`
Expected: last line `test-l10n: 9 passed, 0 failed` (counted by `expect` plus the three `grep` controls, which only count failures). If a case fails, fix the script, not the test.

- [ ] **Step 6: Commit**

```bash
git add scripts/l10n/l10n.swift scripts/l10n.sh scripts/test-l10n.sh
git commit -m "l10n: compile String Catalogs into Swift tables and check them (S2)"
```

---

### Task 3: The Core catalog, generated table and `L10n.tr`

**Files:**
- Create: `Sources/XCodeVaultCore/Localization/Localizable.xcstrings`
- Create (generated): `Sources/XCodeVaultCore/Localization/CoreStrings.generated.swift`
- Modify: `Package.swift:35-38` (exclude the catalog from the target's sources)
- Modify: `Sources/XCodeVaultCore/Localization/L10n.swift` (add `tr`/`plural` convenience over `.core`)
- Create: `Sources/XCodeVaultCore/Savings/SavingsBucket+L10n.swift`
- Test: `Tests/XCodeVaultCoreTests/CoreStringsTests.swift`

**Interfaces:**
- Consumes: `L10nCatalog`, `L10n.string`, `L10n.plural`, `L10n.locale` (Task 1); `SavingsBucket` (S1).
- Produces:
  - `L10nCatalog.core` (internal, generated)
  - `public static func tr(_ key: String, _ arguments: CVarArg...) -> String` on `L10n`
  - `public static func plural(_ key: String, count: Int, _ arguments: CVarArg...) -> String` on `L10n`
  - `SavingsBucket.localizedTitle`, `.localizedPromise`, `.localizedUndoCost: String`
  - Keys (used by S3/S4): `savings.upTo`, `savings.atLeast`, `savings.temporary.title`, `savings.permanent.title`,
    `savings.total.title`, `savings.alternativesNote`, `savings.verifiedShare`, plural `savings.categoryCount`.

- [ ] **Step 1: Exclude the catalog from compilation** — in `Package.swift`:

```swift
        .target(
            name: "XCodeVaultCore",
            // The String Catalog is compiled by scripts/l10n.sh into CoreStrings.generated.swift, not by SwiftPM
            // into a resource bundle: a stand-alone CLI binary must carry every language (spec 2026-10-03 §4.1).
            exclude: ["Localization/Localizable.xcstrings"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

- [ ] **Step 2: Write the failing tests**

```swift
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
        defer { L10n.configure(override: before, preferred: []) }
        L10n.configure(override: "pt-BR", preferred: [])
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.localizedTitle, "Apagar — volta quando precisar")
        L10n.configure(override: "en", preferred: [])
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.localizedTitle, "Delete — comes back on demand")
        XCTAssertEqual(L10n.tr("savings.atLeast", "5 GB"), "at least 5 GB")
    }
}
```

- [ ] **Step 3: Write the catalog** `Sources/XCodeVaultCore/Localization/Localizable.xcstrings`

Every non-English value is `needs_review`. Each key below has the same five locales; write them out in full (no abbreviation in the file):

```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "savings.bucket.runFromExternal.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Run from an external drive" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Rodar de um disco externo" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Ejecutar desde un disco externo" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "外部ドライブから実行" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "从外置磁盘运行" } } } },
    "savings.bucket.runFromExternal.promise" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Freed for good: it lives on the external drive and stops growing on this Mac." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado de vez: fica no disco externo e para de crescer neste Mac." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado de forma permanente: vive en el disco externo y deja de crecer en este Mac." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "恒久的に解放：外部ドライブに置かれ、このMacでは増えなくなります。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "永久释放：数据存放在外置磁盘上，不再在这台 Mac 上增长。" } } } },
    "savings.bucket.runFromExternal.undoCost" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Nothing to download; the drive must be connected while you work." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Nada a baixar; o disco precisa estar conectado enquanto você trabalha." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "No hay nada que descargar; el disco debe estar conectado mientras trabajas." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "ダウンロードは不要ですが、作業中はドライブを接続しておく必要があります。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "无需下载；工作时必须连接该磁盘。" } } } },
    "savings.bucket.parkExternally.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Park on an external drive" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Guardar num disco externo" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Guardar en un disco externo" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "外部ドライブに退避" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "暂存到外置磁盘" } } } },
    "savings.bucket.parkExternally.promise" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Freed until you bring it back: a verified copy waits on your vault drive." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado até você trazer de volta: uma cópia verificada fica no seu disco-cofre." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado hasta que lo recuperes: una copia verificada espera en tu disco bóveda." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "戻すまで解放：検証済みのコピーが保管用ドライブに残ります。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "在取回之前一直释放：经过校验的副本保存在你的保管磁盘上。" } } } },
    "savings.bucket.parkExternally.undoCost" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Copy it back when you need it — no download." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Copie de volta quando precisar — sem baixar de novo." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Cópialo de vuelta cuando lo necesites, sin descargar." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "必要なときにコピーして戻すだけで、ダウンロードは不要です。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "需要时复制回来即可，无需重新下载。" } } } },
    "savings.bucket.deleteAndRegenerate.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete — comes back on demand" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Apagar — volta quando precisar" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Eliminar: vuelve cuando se necesita" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "削除（必要に応じて再生成）" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "删除（需要时自动恢复）" } } } },
    "savings.bucket.deleteAndRegenerate.promise" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Freed now; it grows back as Xcode rebuilds it or downloads it again." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado agora; volta a crescer quando o Xcode reconstrói ou baixa de novo." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Liberado ahora; vuelve a crecer cuando Xcode lo reconstruye o lo descarga de nuevo." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "すぐに解放されますが、Xcodeが再ビルドや再ダウンロードを行うと再び増えます。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "立即释放；Xcode 重新构建或重新下载时会再次增长。" } } } },
    "savings.bucket.deleteAndRegenerate.undoCost" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Rebuild or re-download time." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Tempo de recompilar ou baixar de novo." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Tiempo de recompilar o volver a descargar." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "再ビルドまたは再ダウンロードの時間がかかります。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "需要重新构建或重新下载的时间。" } } } },
    "savings.bucket.keepLocal.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Stays on this Mac" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Fica neste Mac" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Se queda en este Mac" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "このMacに保持" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "保留在这台 Mac 上" } } } },
    "savings.bucket.keepLocal.promise" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Nothing XCodeVault can reclaim safely." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Nada que o XCodeVault possa liberar com segurança." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Nada que XCodeVault pueda liberar de forma segura." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "XCodeVaultが安全に解放できるものはありません。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "XCodeVault 无法安全释放其中的任何内容。" } } } },
    "savings.bucket.keepLocal.undoCost" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Nothing to undo." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Nada a desfazer." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Nada que deshacer." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "元に戻す操作はありません。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "无需撤销。" } } } },
    "savings.upTo" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "up to %@" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "até %@" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "hasta %@" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "最大 %@" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "最多 %@" } } } },
    "savings.atLeast" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "at least %@" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "pelo menos %@" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "al menos %@" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "少なくとも %@" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "至少 %@" } } } },
    "savings.temporary.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Temporary" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Temporária" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Temporal" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "一時的" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "临时" } } } },
    "savings.permanent.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Permanent" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Definitiva" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Permanente" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "恒久的" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "永久" } } } },
    "savings.total.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Total reclaimable" } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "Total recuperável" } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Total recuperable" } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "解放可能な合計" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "可释放总量" } } } },
    "savings.alternativesNote" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "The options are alternatives for the same files; the total counts each file once." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "As opções são alternativas para os mesmos arquivos; o total conta cada arquivo uma vez." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "Las opciones son alternativas para los mismos archivos; el total cuenta cada archivo una sola vez." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "各オプションは同じファイルに対する選択肢です。合計では各ファイルを1回だけ数えます。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "这些选项针对的是同一批文件；总量中每个文件只计算一次。" } } } },
    "savings.verifiedShare" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "%@ verified; the rest is experimental." } },
      "pt-BR" : { "stringUnit" : { "state" : "needs_review", "value" : "%@ verificado; o restante é experimental." } },
      "es" : { "stringUnit" : { "state" : "needs_review", "value" : "%@ verificado; el resto es experimental." } },
      "ja" : { "stringUnit" : { "state" : "needs_review", "value" : "%@ は検証済み、残りは実験的です。" } },
      "zh-Hans" : { "stringUnit" : { "state" : "needs_review", "value" : "其中 %@ 已验证，其余为实验性。" } } } },
    "savings.categoryCount" : { "localizations" : {
      "en" : { "variations" : { "plural" : {
        "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld category" } },
        "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld categories" } } } } },
      "pt-BR" : { "variations" : { "plural" : {
        "one" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld categoria" } },
        "other" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld categorias" } } } } },
      "es" : { "variations" : { "plural" : {
        "one" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld categoría" } },
        "other" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld categorías" } } } } },
      "ja" : { "variations" : { "plural" : {
        "other" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld 個のカテゴリ" } } } } },
      "zh-Hans" : { "variations" : { "plural" : {
        "other" : { "stringUnit" : { "state" : "needs_review", "value" : "%lld 个类别" } } } } } } }
  }
}
```

- [ ] **Step 4: Add the convenience API** — append inside `public enum L10n` in `L10n.swift`:

```swift
    /// The Core table in the process locale. Keys must be string literals (`scripts/l10n.sh check` reads them).
    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, in: .core, locale: locale, arguments: arguments)
    }

    public static func plural(_ key: String, count: Int, _ arguments: CVarArg...) -> String {
        plural(key, count: count, in: .core, locale: locale, arguments: arguments)
    }
```

- [ ] **Step 5: Add `SavingsBucket+L10n.swift`** (literal keys, one switch per text, so the checker sees every key):

```swift
import Foundation

extension SavingsBucket {
    public var localizedTitle: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.title")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.title")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.title")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.title")
        }
    }

    public var localizedPromise: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.promise")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.promise")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.promise")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.promise")
        }
    }

    public var localizedUndoCost: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.undoCost")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.undoCost")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.undoCost")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.undoCost")
        }
    }
}
```

- [ ] **Step 6: Generate and check**

Run: `scripts/l10n.sh gen && scripts/l10n.sh check`
Expected: generation writes `CoreStrings.generated.swift`; `check` exits 0 and prints one "need native review" line for each of pt-BR, es, ja and zh-Hans (the counts are informational and not asserted).

- [ ] **Step 7: Run the tests**

Run: `swift build -Xswiftc -warnings-as-errors && swift test --filter CoreStringsTests 2>&1 | tail -20`
Expected: `Executed 5 tests, with 0 failures`. Also `swift test --filter L10nTests` still passes.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/XCodeVaultCore/Localization Sources/XCodeVaultCore/Savings/SavingsBucket+L10n.swift Tests/XCodeVaultCoreTests/CoreStringsTests.swift
git commit -m "l10n: the savings vocabulary in en, pt-BR, es, ja and zh-Hans (S2)"
```

---

### Task 4: `--lang` in the CLI, languages in the app bundle

**Files:**
- Modify: `Sources/xcodevaultctl/XCodeVaultCTL.swift:5-26` (add `static func main()`; mention `--lang` in the discussion)
- Modify: `Resources/App/Info.plist` (add `CFBundleLocalizations`)
- Test: `Tests/XCodeVaultCoreTests/CLILanguageTests.swift`

**Interfaces:**
- Consumes: `L10n.extractLanguageOverride`, `L10n.configure`, `L10n.match`, `L10n.supportedLocales` (Task 1).
- Produces: `XCodeVaultCTL.prepareLanguage(arguments: [String], environment: [String: String], preferred: [String]) -> (remaining: [String], warning: String?)` (internal static, testable); every invocation accepts `--lang <code>` anywhere before `--`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

final class CLILanguageTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", preferred: []) }

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
        L10n.configure(override: "en", preferred: [])
        let english = try JSONOutput.encode(report)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, preferred: [])
            XCTAssertEqual(try JSONOutput.encode(report), english, locale)
        }
    }
}
```

(`Fixtures.minimalReport()` comes from S1 Task 3. If S1 has not landed, add it to `Support.swift` exactly as in that task.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CLILanguageTests 2>&1 | tail -20`
Expected: build failure, "type 'XCodeVaultCTL' has no member 'prepareLanguage'".

- [ ] **Step 3: Implement** — add inside `struct XCodeVaultCTL`:

```swift
    /// The language must be known before ArgumentParser builds any help text, so `--lang` is taken out of
    /// the arguments here rather than declared as an option (spec 2026-10-03 §4.2).
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let prepared = prepareLanguage(arguments: Array(CommandLine.arguments.dropFirst()), environment: env, preferred: Locale.preferredLanguages)
        if let warning = prepared.warning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        main(prepared.remaining)
    }

    static func prepareLanguage(arguments: [String], environment: [String: String], preferred: [String]) -> (remaining: [String], warning: String?) {
        let (flag, remaining) = L10n.extractLanguageOverride(from: arguments)
        let requested = flag ?? environment["XCODEVAULT_LANG"]
        L10n.configure(override: requested, preferred: preferred)
        var warning: String?
        if let requested, L10n.match(requested) == nil {
            warning =
                "xcodevaultctl: language '\(requested)' is not available; using \(L10n.locale). Available: \(L10n.supportedLocales.joined(separator: ", "))"
        }
        return (remaining, warning)
    }
```

And extend the root `discussion` with a paragraph (English; S3 localizes help text):

```
            Language: --lang <code> (en, pt-BR, es, ja, zh-Hans) or XCODEVAULT_LANG; otherwise your \
            macOS language. --json output is never translated.
```

- [ ] **Step 4: Info.plist** — add next to `CFBundleDevelopmentRegion`:

```xml
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>pt-BR</string>
        <string>es</string>
        <string>ja</string>
        <string>zh-Hans</string>
    </array>
```

- [ ] **Step 5: Run to verify pass, then smoke the binary**

Run: `swift test --filter CLILanguageTests 2>&1 | tail -20` → `Executed 4 tests, with 0 failures`.
Then: `swift build && .build/debug/xcodevaultctl --lang ja status >/dev/null && .build/debug/xcodevaultctl --lang fr permissions --json >/dev/null` — both exit 0; the second prints the warning on stderr.

- [ ] **Step 6: Commit**

```bash
git add Sources/xcodevaultctl/XCodeVaultCTL.swift Resources/App/Info.plist Tests/XCodeVaultCoreTests/CLILanguageTests.swift
git commit -m "CLI: --lang and XCODEVAULT_LANG; the app declares its five languages (S2)"
```

---

### Task 5: The gate, the guide, and the record

**Files:**
- Modify: `scripts/preflight.sh:27-40` (add the gate) and `:57` (`expected_steps` 14 → 15)
- Modify: `.github/workflows/ci.yml` (add one step, before "Build")
- Create: `docs/process/LOCALIZATION.md`
- Modify: `STATUS.md` (In flight: S2 done)
- Modify: `CLAUDE.md` Layout line (mention `scripts/l10n.sh` among the CI controls) — **keep `check-doc-mirror.sh` green**: change only the Layout paragraph, never the non-negotiable list.

- [ ] **Step 1: Add the gate to `preflight.sh`**, after the `"redaction:…"` line:

```bash
    "l10n:bash scripts/l10n.sh check && bash scripts/test-l10n.sh"
```

and set `expected_steps=15`.

- [ ] **Step 2: Add the CI step** in `.github/workflows/ci.yml`, as its own `- name:` immediately before the build step, matching the indentation of its neighbors:

```yaml
      - name: Localization (catalogs compiled, complete, placeholders match)
        # The stand-alone CLI carries its languages compiled in (spec 2026-10-03 §4.1); a catalog edited
        # without regenerating would ship stale text, and a missing locale would silently fall back to English.
        run: bash scripts/l10n.sh check && bash scripts/test-l10n.sh
```

- [ ] **Step 3: Write `docs/process/LOCALIZATION.md`**

```markdown
# Localization

XCodeVault ships in English (base), Brazilian Portuguese, Spanish, Japanese and Simplified Chinese.

## How it works

- Text lives in String Catalogs: `Sources/<Module>/Localization/Localizable.xcstrings` (open in Xcode, or
  edit the JSON). Keys are stable identifiers such as `savings.bucket.parkExternally.title`.
- `scripts/l10n.sh gen` compiles each catalog into `<Module>Strings.generated.swift`, a static table built
  into the binary. There is no runtime resource bundle, so a stand-alone `xcodevaultctl` has every language.
- Code uses `L10n.tr("key", args…)` and `L10n.plural("key", count: n, args…)` with **literal** keys.
- Locale: `--lang <code>` (CLI) → `XCODEVAULT_LANG` → macOS language preferences → English.
- Never translated: `--json` output, journal entries, category ids, commands, flags, paths, and the typed
  `--i-confirm-…` flags.

## Glossary — keep these untranslated

XCodeVault, Xcode, Simulator, DerivedData, Archives, runtime (in commands), Full Disk Access (use Apple's
own localized name for the Settings pane in prose: pt-BR "Acesso Total ao Disco", es "Acceso total al
disco", ja "フルディスクアクセス", zh-Hans "完全磁盘访问权限").

## Tone

Plain, short, second person, no exclamation marks. Say what happens to the user's files and what it costs
to undo. "Experimental" is always translated and always shown where the English shows it (CLAUDE.md rule 10).

## Review state

Every non-English string ships as `needs_review` until a native speaker reviews it in the catalog and
changes its state to `translated`. `scripts/l10n.sh check` prints the remaining count per language.

| Language | Code | Reviewed by | State |
|---|---|---|---|
| English | `en` | — | base |
| Português (Brasil) | `pt-BR` | — | needs review |
| Español | `es` | — | needs review |
| 日本語 | `ja` | — | needs review |
| 简体中文 | `zh-Hans` | — | needs review |

## Adding a language

1. `scripts/l10n.sh add <code>` — seeds every string with an English copy marked `needs_review`.
2. Add `<code>` to `L10n.supportedLocales` in `Sources/XCodeVaultCore/Localization/L10n.swift`, add its CLDR
   integer plural rule to `L10n.pluralCategory`, and add it to `CFBundleLocalizations` in
   `Resources/App/Info.plist`.
3. Translate in the catalog, run `scripts/l10n.sh gen && scripts/l10n.sh check`, add a row to the table
   above, and test with `xcodevaultctl --lang <code> status`.

## Coverage

Localized so far: the savings vocabulary (S2). The CLI help and output (S3) and the app (S4) move their text
into the catalog as they are rewritten. Doctor findings, warnings and error messages are still English-only;
each one moves when its text is next edited.
```

- [ ] **Step 4: Update `STATUS.md`** — in the "Savings visibility, i18n and identity" bullet, mark S2 done
  and note "non-English strings need native review (docs/process/LOCALIZATION.md)".

- [ ] **Step 5: Update `CLAUDE.md` Layout** — after `scripts/preflight.sh (runs every CI gate locally…)`, add:
  `` · `scripts/l10n.sh` (String Catalogs → compiled tables; `check` is a CI gate; see `docs/process/LOCALIZATION.md`) ``.

- [ ] **Step 6: Full preflight**

Run: `scripts/preflight.sh`
Expected: `preflight: ok (13 gates)` — every gate ran, including `l10n`.

- [ ] **Step 7: Commit and push**

```bash
git add scripts/preflight.sh .github/workflows/ci.yml docs/process/LOCALIZATION.md STATUS.md CLAUDE.md
git commit -m "l10n: CI gate and the guide for adding a language (S2)"
git push
```
