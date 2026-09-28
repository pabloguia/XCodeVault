/// "Never two scans; one more after the running one when asked meanwhile" (carried note 7 of the 2026-09-27
/// permissions plan). The app used to start a second, overlapping scan when the user came back from System
/// Settings while the first one ran, and to show whichever ended last. Every path in the app that starts a
/// scan asks this first. It is a value the app keeps on the main actor, so its two calls never race.
public struct ScanGate: Sendable, Equatable {
    public private(set) var isScanning = false
    private var oneMore = false

    public init() {}

    /// Whether to start a scan now. While one runs, it remembers that one more is wanted and answers `false`:
    /// the running scan started before whatever prompted this request, so its result may not reflect it.
    public mutating func requestScan() -> Bool {
        if isScanning {
            oneMore = true
            return false
        }
        isScanning = true
        return true
    }

    /// Called when a scan ends: whether to start the one requested meanwhile. It stays scanning if so, so no
    /// other path can slip a scan in between.
    public mutating func scanEnded() -> Bool {
        if oneMore {
            oneMore = false
            return true
        }
        isScanning = false
        return false
    }
}
