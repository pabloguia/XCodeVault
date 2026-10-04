import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

final class BrandTokenTests: XCTestCase {
    func testEveryBucketHasADistinctColorAndSymbol() {
        let all = SavingsBucket.allCases
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.colorHex)).count, all.count)
        XCTAssertEqual(Set(all.map(\.symbolName)).count, all.count)
    }

    func testEveryHexTokenIsSixUppercaseHexDigits() {
        let hexes = SavingsBucket.allCases.map(\.colorHex) + [Brand.indigoHex, Brand.tealHex, Brand.darkBackgroundHex]
        for hex in hexes {
            XCTAssertNotNil(hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression), hex)
        }
    }

    func testEverySymbolResolves() {
        for bucket in SavingsBucket.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: bucket.symbolName, accessibilityDescription: nil), bucket.symbolName)
        }
    }

    func testHexParsesToSRGBComponents() throws {
        let color = try XCTUnwrap(NSColor(Color(hex: "#2B2D6E")).usingColorSpace(.sRGB))
        let tolerance = 0.5 / 255
        XCTAssertEqual(color.redComponent, 43.0 / 255, accuracy: tolerance)
        XCTAssertEqual(color.greenComponent, 45.0 / 255, accuracy: tolerance)
        XCTAssertEqual(color.blueComponent, 110.0 / 255, accuracy: tolerance)
    }

    // WCAG 2.x relative luminance and contrast ratio.
    private func luminance(_ hex: String) -> Double {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let channels = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map { Double($0) / 255 }
        let lin = channels.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testEveryBucketColorHasAtLeastThreeToOneOnDarkBackground() {
        for bucket in SavingsBucket.allCases {
            XCTAssertGreaterThanOrEqual(contrast(bucket.colorHex, "#1C1E52"), 3, bucket.rawValue)
        }
    }

    func testBucketColorsHaveAtLeastThreeToOneOnWhite() {
        for bucket in SavingsBucket.allCases {
            XCTAssertGreaterThanOrEqual(contrast(bucket.colorHex, "#FFFFFF"), 3, bucket.rawValue)
        }
    }

    // MARK: - Appearance-aware tokens (S4 Task 3, the first GUI use)

    private func luminance(_ color: NSColor) throws -> Double {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func linear(_ component: CGFloat) -> Double {
            let v = Double(component)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r: Double = linear(c.redComponent), g: Double = linear(c.greenComponent), b: Double = linear(c.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
        let (la, lb) = (try luminance(a), try luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The resolved colors of `color` and of the surfaces the app draws buckets on, under `appearance`.
    private func resolved(_ color: NSColor, on appearance: NSAppearance.Name) -> (color: NSColor, surfaces: [String: NSColor]) {
        var out: (NSColor, [String: NSColor]) = (color, [:])
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            // `usingColorSpace` resolves a dynamic color for the current drawing appearance; copy the values out.
            out = (
                color.usingColorSpace(.sRGB)!,
                [
                    "windowBackgroundColor": NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!,
                    "controlBackgroundColor": NSColor.controlBackgroundColor.usingColorSpace(.sRGB)!,
                ]
            )
        }
        return out
    }

    /// Each bucket's fill clears 3:1 against the system's window and control backgrounds as this macOS resolves them, in
    /// the light and the dark appearance — and against the values earlier macOS versions resolve them to (`#ECECEC`
    /// light; `#323232` and `#1E1E1E` dark), so the result does not depend on which macOS runs the test.
    func testEveryBucketClearsThreeToOneOnTheSystemBackgroundsInBothAppearances() throws {
        let earlier: [NSAppearance.Name: [String]] = [.aqua: ["#FFFFFF", "#ECECEC"], .darkAqua: ["#323232", "#1E1E1E"]]
        var checked = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for bucket in SavingsBucket.allCases {
                let (color, surfaces) = resolved(bucket.nsColor, on: appearance)
                var all = surfaces
                for hex in earlier[appearance] ?? [] { all[hex] = NSColor(Color(hex: hex)) }
                for (name, surface) in all {
                    XCTAssertGreaterThanOrEqual(try contrast(color, surface), 3, "\(bucket.rawValue) on \(name), \(appearance.rawValue)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2 * SavingsBucket.allCases.count * 4)
    }

    /// The light variant is darker, the dark variant is the S5 token; both keep its hue.
    func testTheAppearanceVariantsKeepTheHue() throws {
        for bucket in SavingsBucket.allCases {
            XCTAssertEqual(bucket.darkColorHex, bucket.colorHex)
            let light = try XCTUnwrap(NSColor(Color(hex: bucket.lightColorHex)).usingColorSpace(.sRGB))
            let token = try XCTUnwrap(NSColor(Color(hex: bucket.colorHex)).usingColorSpace(.sRGB))
            XCTAssertEqual(light.hueComponent, token.hueComponent, accuracy: 0.01, bucket.rawValue)
            XCTAssertLessThan(try luminance(light), try luminance(token), bucket.rawValue)
            XCTAssertNotNil(bucket.lightColorHex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression), bucket.lightColorHex)
            // The dynamic color resolves to the matching variant.
            let (inLight, _) = resolved(bucket.nsColor, on: .aqua)
            let (inDark, _) = resolved(bucket.nsColor, on: .darkAqua)
            XCTAssertEqual(try luminance(inLight), try luminance(light), accuracy: 0.001, bucket.rawValue)
            XCTAssertEqual(try luminance(inDark), try luminance(token), accuracy: 0.001, bucket.rawValue)
        }
    }

    /// R5 (HIG review X9): Increase Contrast has its own variants — darker in light, lighter in dark — each clearing more than
    /// the base against white and the dark background. Off a window, `NSAppearance(named:)` gives a high-contrast name its
    /// base appearance (the test below), so the mapping is checked here directly; in a real window it needs Increase
    /// Contrast switched on to see.
    func testIncreaseContrastHasItsOwnStrongerVariants() {
        for bucket in SavingsBucket.allCases {
            XCTAssertEqual(bucket.colorHex(for: .aqua), bucket.lightColorHex)
            XCTAssertEqual(bucket.colorHex(for: .darkAqua), bucket.darkColorHex)
            XCTAssertEqual(bucket.colorHex(for: .accessibilityHighContrastAqua), bucket.highContrastLightColorHex)
            XCTAssertEqual(bucket.colorHex(for: .accessibilityHighContrastDarkAqua), bucket.highContrastDarkColorHex)
            XCTAssertGreaterThan(contrast(bucket.highContrastLightColorHex, "#FFFFFF"), contrast(bucket.lightColorHex, "#FFFFFF"), bucket.rawValue)
            XCTAssertGreaterThanOrEqual(contrast(bucket.highContrastLightColorHex, "#FFFFFF"), 4.5, bucket.rawValue)
            XCTAssertGreaterThan(contrast(bucket.highContrastDarkColorHex, "#1E1E1E"), contrast(bucket.darkColorHex, "#1E1E1E"), bucket.rawValue)
            XCTAssertGreaterThanOrEqual(contrast(bucket.highContrastDarkColorHex, "#1E1E1E"), 4.5, bucket.rawValue)
        }
    }

    /// Review M8: Increase Contrast's appearances follow their base — the light variant in high-contrast light, the token in
    /// high-contrast dark — and still clear 3:1 on the surfaces those appearances resolve.
    func testTheHighContrastAppearancesResolveToTheirBaseAndClearThreeToOne() throws {
        let cases: [(NSAppearance.Name, KeyPath<SavingsBucket, String>)] = [
            (.accessibilityHighContrastAqua, \.lightColorHex), (.accessibilityHighContrastDarkAqua, \.darkColorHex),
        ]
        var checked = 0
        for (appearance, variant) in cases {
            XCTAssertNotNil(NSAppearance(named: appearance), appearance.rawValue)
            for bucket in SavingsBucket.allCases {
                let (color, surfaces) = resolved(bucket.nsColor, on: appearance)
                let expected = try XCTUnwrap(NSColor(Color(hex: bucket[keyPath: variant])).usingColorSpace(.sRGB))
                XCTAssertEqual(try luminance(color), try luminance(expected), accuracy: 0.001, "\(bucket.rawValue) \(appearance.rawValue)")
                for (name, surface) in surfaces {
                    XCTAssertGreaterThanOrEqual(try contrast(color, surface), 3, "\(bucket.rawValue) on \(name), \(appearance.rawValue)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2 * SavingsBucket.allCases.count * 2)
    }
}
