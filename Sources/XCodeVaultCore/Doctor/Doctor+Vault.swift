import Foundation

/// Disconnect-safety diagnostics (M3): registered vault volumes, shadow data, interrupted
/// migrations, and Xcode Locations pointing at absent volumes.
extension Doctor {
    public func diagnoseVault(report: ScanReport, registry: VaultRegistry = VaultRegistry(), journal: Journal = Journal()) -> [Finding] {
        var f: [Finding] = []
        f += checkVaultVolumes(registry: registry, volumes: report.volumes)
        f += checkShadowVolumesDirectories(volumes: report.volumes)
        f += checkInterruptedMigrations(journal: journal)
        f += checkLocationsPointAtPresentVolumes(volumes: report.volumes)
        return f
    }

    func checkVaultVolumes(registry: VaultRegistry, volumes: [Volume]) -> [Finding] {
        let verifier = VaultVerifier(registry: registry, mountedVolumes: { volumes })
        guard let checks = try? verifier.checkAll() else { return [] }
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
        guard let interrupted = try? journal.interrupted() else { return [] }
        return interrupted.map { e in
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
