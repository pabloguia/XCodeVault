import Foundation
public enum E2Lib {
    /// Deterministic function the test bundle calls, so a passing test proves the
    /// framework was loaded from wherever DerivedData/build products were placed.
    public static func answer() -> Int { 42 }

    /// Reports where this framework was loaded from at runtime.
    public static func loadedFrom() -> String {
        Bundle(for: Marker.self).bundlePath
    }
}

final class Marker {}
