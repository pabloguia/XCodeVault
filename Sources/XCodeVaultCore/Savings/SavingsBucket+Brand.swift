import Foundation

extension SavingsBucket {
    /// The bucket's one color, `#RRGGBB` (S5 identity). Never the only signal: S4 pairs it with `symbolName` and a label.
    public var colorHex: String {
        switch self {
        case .deleteAndRegenerate: "#C27C12"
        case .parkExternally: "#3B82F6"
        case .runFromExternal: "#22A06B"
        case .keepLocal: "#8A8FA3"
        }
    }

    /// The bucket's one SF Symbol.
    public var symbolName: String {
        switch self {
        case .deleteAndRegenerate: "arrow.counterclockwise.circle"
        case .parkExternally: "shippingbox"
        case .runFromExternal: "externaldrive.badge.checkmark"
        case .keepLocal: "internaldrive"
        }
    }
}
