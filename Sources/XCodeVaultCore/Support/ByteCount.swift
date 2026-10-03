import Foundation

public enum ByteCount {
    public static func format(_ bytes: UInt64) -> String { format(Int64(clamping: bytes)) }
    public static func format(_ bytes: Int64) -> String { format(bytes, locale: L10n.locale) }

    /// For prose that is English in every language — findings, vault checks, scan and volume warnings, plan notes, errors: the same bytes read
    /// the same whatever the process locale (spec §4.3).
    static func english(_ bytes: UInt64) -> String { english(Int64(clamping: bytes)) }
    static func english(_ bytes: Int64) -> String { format(bytes, locale: L10n.baseLocale) }

    /// Decimal units (GB), matching Finder and diskutil, in `locale`'s number format — never the machine's region
    /// (spec §5.1). Zero is written as a number. Records (the journal, JSON output) pass `"en"`: they are never localized (spec §4.3).
    public static func format(_ bytes: Int64, locale: String) -> String {
        bytes.formatted(
            .byteCount(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false)
                .locale(Locale(identifier: locale)))
    }
}

public extension String {
    /// Expands a leading `~` to the given home directory (defaults to the current user's).
    func expandingTilde(home: String = NSHomeDirectory()) -> String {
        if self == "~" { return home }
        if hasPrefix("~/") { return home + dropFirst() }
        return self
    }
}
