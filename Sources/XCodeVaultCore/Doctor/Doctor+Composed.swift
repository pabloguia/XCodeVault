import Foundation

/// The one entry point a client should call.
///
/// Before this existed, every client wrote `diagnose(report:) + diagnoseVault(report:)` out by
/// hand — identically, at three call sites. Adding a third rule family meant editing three files,
/// and missing one dropped its findings silently: no compile error, no failing test, just a
/// `doctor` run that no longer reported what the new family was written to report. The cost was
/// entirely in the *next* family, which is why nothing was visibly wrong while there were two.
///
/// `diagnoseAll` is that family list, in one place. `DoctorFamilyCompositionTests` fails if a
/// family exists in this directory and is not reachable from here, so the next family cannot be
/// added without also being composed.
extension Doctor {
    /// Runs every rule family and returns their findings in one severity-sorted list.
    ///
    /// - Parameters:
    ///   - registry: the vault registry the disconnect-safety family reads. Injectable for tests.
    ///   - journal: defaults to **this Doctor's** journal, not to `Journal()`. `Journal()` reads
    ///     `NSHomeDirectory()` directly, so a test that injected `home` would still have been
    ///     handed this machine's real journal — the injection would look complete and would not
    ///     be. In production the two resolve to the same file, so this changes no behaviour there.
    public func diagnoseAll(report: ScanReport, registry: VaultRegistry = VaultRegistry(), journal: Journal? = nil) -> [Finding] {
        var f: [Finding] = []
        f += diagnose(report: report)
        f += diagnoseVault(report: report, registry: registry, journal: journal ?? self.journal)
        // Sorted here rather than concatenated in call-site order: `diagnose` sorts its own output
        // and `diagnoseVault` does not, so appending one to the other produced a list that was
        // sorted in its first half and chronological in its second. The three call sites all
        // presented that list to a user as "what is wrong, worst first".
        return f.sorted { ($0.severity > $1.severity) || ($0.severity == $1.severity && $0.id < $1.id) }
    }
}
