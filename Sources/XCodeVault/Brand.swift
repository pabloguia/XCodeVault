import SwiftUI
import XCodeVaultCore

enum Brand {
    static let indigoHex = "#2B2D6E"
    static let tealHex = "#1FB5A8"
    /// The dark-appearance background the icon sits on.
    static let darkBackgroundHex = "#1C1E52"

    static let indigo = Color(hex: indigoHex)
    static let teal = Color(hex: tealHex)
    static let darkBackground = Color(hex: darkBackgroundHex)
}

extension Color {
    /// `#RRGGBB` or `RRGGBB`, sRGB. Anything else is a programming error in a token table: it traps in debug builds and
    /// renders clear in release rather than guessing.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            assertionFailure("malformed brand hex: \(hex)")
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
