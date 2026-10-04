import AppKit
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

/// `#RRGGBB` or `RRGGBB` as sRGB components in 0...1. Anything else is a programming error in a token table: it traps in
/// debug builds and gives nil in release, which the callers render clear rather than guessing.
private func srgbComponents(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
        assertionFailure("malformed brand hex: \(hex)")
        return nil
    }
    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
}

extension Color {
    init(hex: String) {
        guard let c = srgbComponents(hex) else {
            self = .clear
            return
        }
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = srgbComponents(hex)
        self.init(srgbRed: c?.red ?? 0, green: c?.green ?? 0, blue: c?.blue ?? 0, alpha: c == nil ? 0 : 1)
    }
}

/// The bucket tokens as the app draws them (S4 Task 3, BRAND.md "Using the tokens in the app"): appearance-aware, so each
/// clears 3:1 against the window and control backgrounds in light and dark (`BrandTokenTests`). Fills, bars and symbol
/// tints only — never text color; titles and amounts use `.primary`/`.secondary`, and a color always comes with the
/// bucket's symbol and localized title.
extension SavingsBucket {
    /// The light-appearance variant: the S5 token's hue, darker, so it clears 3:1 on white and on the `#ECECEC` window
    /// background earlier macOS versions use.
    var lightColorHex: String {
        switch self {
        case .deleteAndRegenerate: "#AB6D10"
        case .parkExternally: "#2776F5"
        case .runFromExternal: "#1E8B5D"
        case .keepLocal: "#737991"
        }
    }

    /// The dark-appearance variant: the S5 token itself, which already clears 3:1 on the dark backgrounds.
    var darkColorHex: String { colorHex }

    /// Resolves per appearance; the high-contrast appearances follow their light or dark base.
    var nsColor: NSColor {
        let light = lightColorHex, dark = darkColorHex
        return NSColor(name: NSColor.Name("XCodeVault.bucket." + rawValue)) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// History's kind badges (R4), drawn like the bucket tokens: appearance-aware, from `JournalTimeline.Kind`'s light and
/// dark hexes, each clearing 3:1 on the window and control backgrounds (`HistoryKindPaletteTests`). A symbol tint and a
/// fill only — the kind's name is `.primary` text, and the symbol and the name always come with the color.
extension JournalTimeline.Kind {
    var nsColor: NSColor {
        let light = lightColorHex, dark = darkColorHex
        return NSColor(name: NSColor.Name("XCodeVault.historyKind." + rawValue)) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}
