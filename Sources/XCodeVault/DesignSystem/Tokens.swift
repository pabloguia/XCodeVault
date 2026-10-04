import AppKit
import SwiftUI

// The design system's tokens (docs/design/DESIGN_SYSTEM.md §2, R7-B). Views name these instead of literals; the bucket and
// History kind colors stay in Brand.swift (docs/brand/BRAND.md). No new hex values.

/// Spacing on a 4-pt grid (§2.2).
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

/// Corner radii (§2.3). Never set on a `Button`: its style owns the shape. Only `FilterChipStyle` uses a capsule.
enum Radius {
    /// Overview cards, plan rows, health cards.
    static let card: CGFloat = 8
    /// The log and code backgrounds.
    static let code: CGFloat = 4
    /// The disk bar.
    static let bar: CGFloat = 5
    /// A legend swatch, a card's color stripe.
    static let swatch: CGFloat = 2
    /// A chart bar.
    static let chartBar: CGFloat = 3
}

/// The semantic colors (§2.1). Status tints are for symbols only: text stays `.primary` or `.secondary`.
enum Tokens {
    static let surfaceCard = Color(nsColor: .controlBackgroundColor)
    static let surfaceCode = Color(nsColor: .textBackgroundColor)
    static let strokeHairline = Color(nsColor: .separatorColor)
    /// The FilterChip outline: the only boundary that identifies it, so it must clear 3:1 (WCAG 1.4.11).
    static let chipStroke = Color(nsColor: chipStrokeNS)
    static let chipStrokeNS = NSColor.secondaryLabelColor
    /// A selected FilterChip: a light accent fill under an accent stroke — never a solid accent fill, which is the
    /// prominent button's.
    static let chipSelectedFill = Color.accentColor.opacity(0.18)
    static let chipSelectedStroke = Color.accentColor
    /// The hover wash on an unselected chip.
    static let chipHoverFill = Color.primary.opacity(0.06)
    /// A log line the command wrote to standard error. Never color alone (A+B review M6): the line also starts with "! "
    /// (`LogLine.rendered`), asserted by `DesignSystemTests`.
    static let logStderr = Color.red
    /// The neutral "other data" segment of a disk bar.
    static let otherDataFill = Color(nsColor: .systemGray).opacity(0.55)
    static let freeFill = Color(nsColor: .tertiarySystemFill)
    /// The Simulators chart's kinds (BRAND.md: the brand teal is not for light surfaces).
    static let simRuntime = Color.indigo
    static let simDevice = Color.teal
    /// The smallest hit area of an icon-only button (WCAG 2.5.8).
    static let minimumTarget: CGFloat = 24
}
