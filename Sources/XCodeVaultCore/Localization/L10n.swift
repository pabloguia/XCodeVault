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
