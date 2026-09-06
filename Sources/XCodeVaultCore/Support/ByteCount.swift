import Foundation

public enum ByteCount {
    private static func makeFormatter() -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file   // decimal (GB), matching Finder and diskutil
        f.allowsNonnumericFormatting = false
        return f
    }
    public static func format(_ bytes: UInt64) -> String {
        makeFormatter().string(fromByteCount: Int64(clamping: bytes))
    }
    public static func format(_ bytes: Int64) -> String { makeFormatter().string(fromByteCount: bytes) }
}

public extension String {
    /// Expands a leading `~` to the given home directory (defaults to the current user's).
    func expandingTilde(home: String = NSHomeDirectory()) -> String {
        if self == "~" { return home }
        if hasPrefix("~/") { return home + dropFirst() }
        return self
    }
}
