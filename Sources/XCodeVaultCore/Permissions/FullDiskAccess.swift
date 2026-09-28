import Darwin
import Foundation

/// Whether macOS privacy protection (TCC) lets this process read what Full Disk Access guards.
///
/// Three-valued on purpose. `unknown` is not a polite `notGranted`: it is what the probe says when the
/// indicator failed to open for a reason that is not TCC's refusal, and asking at the moment of need
/// (ADR-0007) must not turn "could not tell" into a prompt for a permission nobody showed missing.
public enum FullDiskAccessState: String, Sendable, Codable, CaseIterable {
    case granted, notGranted, unknown
}

/// The one place the product checks Full Disk Access: can this process open H15's indicator file.
///
/// **An indicator, not a query of TCC.** It is `xcv_stage_tcc_indicator` in
/// `scripts/experiments/mount-staging.sh`: a process Full Disk Access reaches can open `TCC.db`; one it
/// does not reach gets `EPERM`. No API reports the grant, and none requests it.
///
/// **It never reads the file.** `open(2)` then `close(2)`, nothing in between: the database is the
/// user's privacy record.
///
/// **Whose access this measures:** the process that runs it. For `XCodeVault.app` that is the app; for
/// `xcodevaultctl`, macOS decides by the app it runs in — usually the terminal — which is the
/// asymmetry H15 recorded.
public struct FullDiskAccessProbe: Sendable {
    /// H15's indicator. `FullDiskAccessProbeTests` holds it equal to the path the harness opens.
    public static let indicatorPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// The System Settings pane where the user switches Full Disk Access on. Opening it is the most any
    /// app can do: the switch cannot be flipped by code or by password.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    let path: String
    /// Opens `path` read-only and closes it at once: `0` on success, otherwise the open's `errno`.
    let openReadOnly: @Sendable (String) -> Int32

    public init() {
        self.init(path: FullDiskAccessProbe.indicatorPath, openReadOnly: FullDiskAccessProbe.openAndClose)
    }

    /// Internal: tests inject a readable path, or an opener that answers `EPERM`.
    init(path: String, openReadOnly: @escaping @Sendable (String) -> Int32 = FullDiskAccessProbe.openAndClose) {
        self.path = path
        self.openReadOnly = openReadOnly
    }

    public func state() -> FullDiskAccessState { FullDiskAccessProbe.classify(openErrno: openReadOnly(path)) }

    /// `EPERM`, and only `EPERM`, means "not granted": it is TCC's refusal (H15). `EACCES` is permission
    /// bits and `ENOENT` a missing file; neither says anything about Full Disk Access.
    static func classify(openErrno: Int32) -> FullDiskAccessState {
        switch openErrno {
        case 0: return .granted
        case EPERM: return .notGranted
        default: return .unknown
        }
    }

    static func openAndClose(_ path: String) -> Int32 {
        // O_NONBLOCK so an injected path naming a FIFO cannot hang the caller; on a regular file it
        // changes nothing.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        close(fd)
        return 0
    }
}
