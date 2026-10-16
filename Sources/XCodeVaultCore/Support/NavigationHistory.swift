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

    /// The places **Back** left, newest last, for **Forward** (R5, HIG review N1). A new move clears them, as a browser does.
    public private(set) var forwardPlaces: [Place] = []

    public var canGoBack: Bool { !places.isEmpty }
    public var canGoForward: Bool { !forwardPlaces.isEmpty }

    /// Records leaving `from` for `to`. Nothing when they are the same place. A new move forgets what Forward offered.
    public mutating func moved(from: Place, to: Place) {
        guard from != to else { return }
        places.append(from)
        if places.count > limit { places.removeFirst(places.count - limit) }
        forwardPlaces = []
    }

    /// The place to go back to, removed from the history; nil when there is none.
    public mutating func back() -> Place? {
        places.popLast()
    }

    /// **Back** from `current`: the place to go back to, with `current` kept for **Forward**; nil when there is none.
    public mutating func back(from current: Place) -> Place? {
        guard let previous = places.popLast() else { return nil }
        forwardPlaces.append(current)
        return previous
    }

    /// **Forward** from `current`: the place Back left, with `current` back in the history; nil when there is none.
    public mutating func forward(from current: Place) -> Place? {
        guard let next = forwardPlaces.popLast() else { return nil }
        places.append(current)
        if places.count > limit { places.removeFirst(places.count - limit) }
        return next
    }
}
