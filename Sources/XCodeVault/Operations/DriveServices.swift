import AppKit
import Foundation
import XCodeVaultCore

/// What the Drives screen and the preparation sheet reach outside the process (R6, ADR-0012): reading the disks, and
/// hearing that a volume was mounted or unmounted. `.live` calls Core and `NSWorkspace`; a test supplies a snapshot and
/// fires the events itself. `.inert`, the default, reads nothing and hears nothing — a test that sets nothing can never
/// run `diskutil`.
struct DriveServices: Sendable {
    /// Reads the disks and the mounted volumes (`DriveSnapshot.read`: `diskutil list`, `apfs list`, `info` — read-only
    /// verbs). Called off the main actor. Nil when they cannot be read.
    var snapshot: @Sendable () -> DriveSnapshot?
    /// Starts observing mounts and unmounts; `changed` is called on the main actor for each. The returned value keeps the
    /// observation alive and ends it when released.
    var observe: @MainActor @Sendable (_ changed: @escaping @MainActor @Sendable () -> Void) -> AnyObject?
    /// Events closer together than this make one refresh.
    var debounce: Duration = .milliseconds(750)

    static let inert = DriveServices(snapshot: { nil }, observe: { _ in nil })

    static let live = DriveServices(
        snapshot: { try? DriveSnapshot.read() },
        observe: { changed in MountObserver(changed: changed) })
}

/// `NSWorkspace`'s mount and unmount notifications, for as long as the object lives. A disk that appears without a
/// mountable volume (a blank or unformatted disk) posts nothing here; **Check Again** and every scan read the disks too.
@MainActor
final class MountObserver {
    // Written once in `init`, read once in `deinit`: never concurrently.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init(changed: @escaping @MainActor @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { changed() } })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for t in tokens { center.removeObserver(t) }
    }
}
