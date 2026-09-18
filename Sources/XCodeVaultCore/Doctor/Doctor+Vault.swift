import Foundation

/// Disconnect-safety diagnostics (M3): registered vault volumes, shadow data, interrupted
/// migrations, and Xcode Locations pointing at absent volumes.
extension Doctor {
    public func diagnoseVault(report: ScanReport, registry: VaultRegistry = VaultRegistry(), journal: Journal = Journal()) -> [Finding] {
        var f: [Finding] = []
        f += checkVaultVolumes(registry: registry, volumes: report.volumes)
        f += checkShadowVolumesDirectories(volumes: report.volumes)
        f += checkInterruptedMigrations(journal: journal)
        f += checkLeftoverPartialCopies(journal: journal)
        f += checkLocationsPointAtPresentVolumes(volumes: report.volumes)
        return f
    }

    func checkVaultVolumes(registry: VaultRegistry, volumes: [Volume]) -> [Finding] {
        let verifier = VaultVerifier(registry: registry, mountedVolumes: { volumes })
        // "I could not check" is a finding, not the absence of one. `try? … else { return [] }`
        // here reported a clean bill of health for every vault volume whenever the registry could
        // not be read — and `doctor` exits 0 unless an `.error` finding exists, so the command
        // whose whole job is to say what is wrong said nothing at all.
        let checks: [VaultVolumeCheck]
        do {
            checks = try verifier.checkAll()
        } catch {
            return [
                Finding(
                    id: "vault-registry-unreadable", severity: .error, title: "Vault registry could not be read",
                    detail: "\(error). No vault volume could be checked, so this run says nothing about them either way.",
                    path: nil,
                    remediation: "Check permissions on the vault registry, then re-run doctor. Do not treat this run as a clean result.",
                    evidence: "Journal.ReadResult: silence from a store that could not be read is not a fact")
            ]
        }
        return checks.compactMap { c in
            switch c.state {
            case .verified: return nil
            case .absent:
                return Finding(
                    id: "vault-absent:\(c.volume.volumeUUID)", severity: .info, title: "Vault volume \(c.volume.volumeName) is not connected",
                    detail: c.detail, path: c.volume.lastMountPoint,
                    remediation: "Connect the volume before running externalize/restore. Data on it is unaffected.",
                    evidence: "MIGRATION_ENGINE.md §Split-brain safety")
            case .movedMountPoint:
                return Finding(
                    id: "vault-moved:\(c.volume.volumeUUID)", severity: .warning, title: "Vault volume \(c.volume.volumeName) mounted at a different path",
                    detail: c.detail, path: c.currentMountPoint,
                    remediation:
                        "Usually a stale '\(c.volume.lastMountPoint)' directory kept macOS from reusing the name. Check for shadow data there, then eject and reconnect.",
                    evidence: "MIGRATION_ENGINE.md (never identify by /Volumes/<name>)")
            case .foreign:
                return Finding(
                    id: "vault-foreign:\(c.volume.volumeUUID)", severity: .error,
                    title: "Something else is mounted where vault volume \(c.volume.volumeName) used to be",
                    detail: c.detail, path: c.volume.lastMountPoint,
                    remediation: "Do not write to it as if it were the vault. Eject the foreign volume, connect the real one, re-run doctor.", evidence: nil)
            case .ambiguous:
                return Finding(
                    id: "vault-shadow:\(c.volume.volumeUUID)", severity: .critical,
                    title: "Shadow data at \(c.volume.lastMountPoint) (\(ByteCount.format(c.shadowBytes ?? 0)))",
                    detail: c.detail, path: c.volume.lastMountPoint,
                    remediation:
                        "Reconciliation needed before the volume is mounted here again (mounting over it hides the data and it keeps consuming the internal disk). Inspect the directory; if it only contains regenerable data, delete it; otherwise merge it manually. XCodeVault never auto-resolves this.",
                    evidence: "H3 / research F6")
            case .sentinelMissing:
                return Finding(
                    id: "vault-sentinel:\(c.volume.volumeUUID)", severity: .error, title: "Vault sentinel missing on \(c.volume.volumeName)",
                    detail: c.detail, path: c.currentMountPoint,
                    remediation:
                        "The volume may have been reformatted or restored from a backup. Verify its contents before trusting it; `vault forget` + `vault init` re-registers it.",
                    evidence: nil)
            }
        }
    }

    /// Any directory under /Volumes that is not a mount point but contains files is data written
    /// while a volume was absent — the classic macOS shadow-data trap (backup tools, rsync, Xcode).
    func checkShadowVolumesDirectories(volumes: [Volume]) -> [Finding] {
        var out: [Finding] = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else { return out }
        for n in names where !n.hasPrefix(".") {
            let p = "/Volumes/" + n
            var st = stat(); guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if MountStatus.isMountPoint(p) { continue }
            guard let u = DiskUsage.measure(p), u.fileCount > 0 else { continue }
            out.append(
                Finding(
                    id: "shadow-volumes-dir:\(n)", severity: .warning,
                    title: "/Volumes/\(n) is a plain directory with \(u.fileCount) file(s), \(ByteCount.format(u.allocatedBytes)) — no volume mounted there",
                    detail:
                        "Something wrote here while the volume named '\(n)' was absent. macOS will mount that volume as '\(n) 1' next time, and every absolute path into /Volumes/\(n) will silently point at this local copy.",
                    path: p, remediation: "Inspect and reconcile before reconnecting the drive. Delete only if the content is regenerable.",
                    evidence: "H3 / research F6"))
        }
        return out
    }

    func checkInterruptedMigrations(journal: Journal) -> [Finding] {
        // Same rule as checkVaultVolumes: an unreadable journal cannot mean "no interrupted
        // migrations". Journal.ReadResult exists to make that distinction and says so in its own
        // doc comment; this call site used to erase it.
        let interrupted: [JournalEntry]
        var unreadableLines = 0
        do {
            let r = try journal.interruptedWithCompleteness()
            interrupted = r.entries
            unreadableLines = r.read.undecodableLines
        } catch {
            return [
                Finding(
                    id: "journal-unreadable:interrupted", severity: .error, title: "Journal could not be read",
                    detail: "\(error). Interrupted migrations cannot be listed, so an operation may be open and unreported.",
                    path: nil,
                    remediation: "Check permissions on the journal, then re-run doctor. Do not treat this run as a clean result.",
                    evidence: "Journal.ReadResult")
            ]
        }
        // A journal that opened but whose lines did not decode is not an empty history. `entries()`
        // discards that count; `interruptedWithCompleteness()` carries it here so it can be said out
        // loud rather than silently folded into "nothing interrupted".
        var f: [Finding] = []
        if unreadableLines > 0 {
            f.append(
                Finding(
                    id: "journal-partially-corrupt", severity: .warning,
                    title: "\(unreadableLines) journal line(s) could not be decoded",
                    detail: "Those operations are invisible to every check that reads the journal, including this one.",
                    path: nil,
                    remediation: "Keep the journal file; it is the only record of what was migrated. Attach it to an issue.",
                    evidence: "Journal.ReadResult.undecodableLines")
            )
        }
        return f
            + interrupted.map { e in
                Finding(
                    id: "interrupted:\(e.id)", severity: e.kind == .migration ? .error : .warning,
                    title: "Interrupted \(e.kind.rawValue) operation (\(e.summary))",
                    detail:
                        "Journal shows this operation started at \(ISO8601DateFormatter().string(from: e.timestamp)) and never completed (crash, kill, or volume removal). Paths: \(e.paths.joined(separator: ", ")).",
                    path: e.paths.first,
                    remediation: e.kind != .migration
                        ? "Check the paths listed; re-run the command if needed."
                        : (["CLEANUP", "VERIFIED", "DONE"].contains(e.detail["phase"] ?? "")
                            ? "The vault copy was verified before the interruption. Run `xcodevaultctl migration resume \(e.id)` to re-verify and finish removing the original (nothing is deleted unless it matches the vault copy)."
                            : "Run `xcodevaultctl migration abort \(e.id)` — removes only the partial vault copy; the source is never touched."),
                    evidence: "docs/architecture/MIGRATION_ENGINE.md")
            }
    }

    func checkLeftoverPartialCopies(journal: Journal) -> [Finding] {
        let leftovers: [JournalEntry]
        do {
            leftovers = try MigrationEngine(journal: journal).leftoverPartialCopies()
        } catch {
            return [
                Finding(
                    id: "journal-unreadable:leftovers", severity: .error, title: "Leftover partial copies could not be checked",
                    detail: "\(error). A partial copy may be occupying space on a vault volume without being named here.",
                    path: nil,
                    remediation: "Check permissions on the journal, then re-run doctor. Do not treat this run as a clean result.",
                    evidence: "Journal.ReadResult")
            ]
        }
        return leftovers.map { e in
            let bytes = DiskUsage.measure(e.paths[1])?.allocatedBytes ?? 0
            return Finding(
                id: "partial-copy:\(e.id)", severity: .warning, title: "Partial vault copy left by failed migration (\(ByteCount.format(bytes)))",
                detail:
                    "\(e.paths[1]) was being written when the migration failed (typically the volume disappeared mid-copy) and could not be cleaned up then. It blocks retrying the migration and wastes vault space. The source \(e.paths[0]) was never touched.",
                path: e.paths[1], remediation: "`xcodevaultctl migration abort \(e.id)` removes only this partial copy.",
                evidence: "E6 software run 2 (2026-09-06)")
        }
    }

    func checkLocationsPointAtPresentVolumes(volumes: [Volume]) -> [Finding] {
        let l = XcodeLocations.read(runner: runner)
        var out: [Finding] = []
        for (label, path) in [("DerivedData", l.derivedData), ("Archives", l.archives), ("Compilation cache", l.compilationCache)] {
            guard let path, !path.isEmpty else { continue }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            if !exists {
                out.append(
                    Finding(
                        id: "location-missing:\(label)", severity: label == "Archives" ? .error : .warning,
                        title: "Xcode's \(label) location does not exist: \(path)",
                        detail:
                            "Xcode will recreate it locally (DerivedData) or fail to archive (Archives). If this is on a disconnected volume, reconnect it before using Xcode.",
                        path: path, remediation: "Reconnect the volume, or `xcodevaultctl locations reset-…` to go back to the default.", evidence: "H3"))
            } else if path.hasPrefix("/Volumes/"), let name = path.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first {
                let top = "/Volumes/" + name
                if !MountStatus.isMountPoint(top) {
                    out.append(
                        Finding(
                            id: "location-shadow:\(label)", severity: .critical,
                            title: "Xcode's \(label) location \(path) is on a plain directory, not a mounted volume",
                            detail:
                                "\(top) is not a mount point. Xcode is writing into the internal disk under a /Volumes path — shadow data forming right now.",
                            path: path, remediation: "Stop Xcode, reconcile \(top), reconnect the volume. See doctor's shadow-data finding.",
                            evidence: "H3 / F6"))
                }
            }
        }
        return out
    }
}
