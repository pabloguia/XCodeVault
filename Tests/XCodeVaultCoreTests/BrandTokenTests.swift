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
}
