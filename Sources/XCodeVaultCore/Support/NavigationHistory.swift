import Foundation

/// The app's **Back** (R1): every place left behind, newest last, like a browser's history. Moving to a new place
/// pushes the one left; `back()` pops it without pushing anything, so Back then Back walks further back. Moving to the
/// place already shown records nothing, and the history keeps at most `limit` places, dropping the oldest.
public struct NavigationHistory<Place: Equatable & Sendable>: Sendable, Equatable {
    public private(set) var places: [Place] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !places.isEmpty }

    /// Records leaving `from` for `to`. Nothing when they are the same place.
    public mutating func moved(from: Place, to: Place) {
        guard from != to else { return }
        places.append(from)
        if places.count > limit { places.removeFirst(places.count - limit) }
    }

    /// The place to go back to, removed from the history; nil when there is none.
    public mutating func back() -> Place? {
        places.popLast()
    }
}
