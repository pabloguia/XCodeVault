import Foundation

public enum ByteCount {
    public static func format(_ bytes: UInt64) -> String { format(Int64(clamping: bytes)) }
    public static func format(_ bytes: Int64) -> String { format(bytes, locale: L10n.locale) }

    /// Decimal units (GB), matching Finder and diskutil, in `locale`'s number format — never the machine's region
    /// (spec §5.1). Zero is written as a number.
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
