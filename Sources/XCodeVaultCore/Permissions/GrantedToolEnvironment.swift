import Foundation

/// The environment XCodeVault.app hands to every tool it runs (helper-security review of deliverable 3, F3).
///
/// A grant reaches the commands a granted process runs: from a terminal with Full Disk Access, root's `mkdir`,
/// `rm` and `mount_apfs` succeeded where they had been refused without it (H15). So once the user grants the
/// app Full Disk Access, the tools it starts work inside that grant, and the hardened runtime, which guards the
/// app's own process, does not cover them. Which binary `/usr/bin/xcrun` runs must then not be something
/// another process of the same user can set:
/// - `DEVELOPER_DIR`, `TOOLCHAINS` and `SDKROOT` choose the developer directory, toolchain and SDK a tool is
///   looked up in (`man xcrun`);
/// - `PATH`: `xcrun` runs a tool it does not find as a developer tool from `PATH` (measured 2026-09-28).
///
/// Tools then resolve through the system's `xcode-select` choice — the trust every developer tool already
/// gives the selected Xcode. That trust includes `xcrun`'s cache, `xcrun_db` in the user's temporary folder,
/// which is not covered here: an entry answered for a tool under a `PATH` that no longer contained it, so what
/// the file holds decides what `xcrun` runs, and the file belongs to the user. Switching the cache off
/// (`xcrun_nocache`) made each lookup take 9 to 18 s instead of 0.05 s, and `TMPDIR` does not move it (all
/// measured 2026-09-28, on one loaded machine). The CLI keeps its caller's
/// environment: a user who sets `DEVELOPER_DIR` for it means it, and a terminal's grant is the terminal's.
public enum GrantedToolEnvironment {
    /// Removed: each one steers where `xcrun` looks a tool up.
    public static let removed = ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"]
    /// Fixed: the system's search path, so a tool `xcrun` does not find is not taken from wherever `PATH` said.
    public static let fixed = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// Makes this process's environment the one above, so every child inherits it — started with no
    /// environment or with `ProcessInfo`'s merged with extra variables, which `ProcessCommandRunner` does
    /// both; each reads the process environment when it spawns (measured 2026-09-28). Call it before the first
    /// tool runs.
    public static func applyToThisProcess() {
        for name in removed { unsetenv(name) }
        for (name, value) in fixed { setenv(name, value, 1) }
    }
}
