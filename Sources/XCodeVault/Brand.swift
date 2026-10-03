import SwiftUI
import XCodeVaultCore

enum Brand {
    static let indigo = Color(hex: "#2B2D6E")
    static let teal = Color(hex: "#1FB5A8")
    /// The dark-appearance background the icon sits on.
    static let darkBackground = Color(hex: "#1C1E52")
}

extension Color {
    /// `#RRGGBB` or `RRGGBB`, sRGB. Anything else is a programming error in a token table, so it renders clear rather than guessing.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .clear
            return
        }
        self.init(
            .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255,
            opacity: 1)
    }
}

extension SavingsBucket {
    var color: Color { Color(hex: colorHex) }
}
