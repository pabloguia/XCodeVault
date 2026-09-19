import Foundation

/// Journal forensics: the part of the migration engine that reads history rather than moving data.
///
/// Split out of `MigrationEngine.swift` under issue #12. The seam is a two-reasons-to-change
/// boundary — everything here is near-pure over `[JournalEntry]` and decides *what happened*, while
/// the rest of the engine copies, verifies and removes. `abortDisposition` was already written that
/// way, which is most of why the split is cheap.
///
/// **The boundary is not the line range the issue named, and the difference is worth stating.** The
/// issue described 660-839 in an 839-line file: a contiguous tail. The file is 1,094 lines now, and
/// `abort` — which calls `removeItem` — sits *between* `abortDisposition` and the two read-only
/// queries at the end. Moving the contiguous range would have carried a deletion path into a file
/// named for forensics, which is the opposite of the property the split exists to create. So the set
/// moved here is the one the issue's *description* names — reads only `[JournalEntry]`, migrates
/// nothing — and `abort` stays with the code that acts.
///
/// **How this was proved to preserve behaviour**: the test-name list was captured before and after
/// and diffed to empty, and the suite re-run. The functions are byte-identical to their previous
/// text. That method is the reason this split waited — this is the file whose behaviour is hardest
/// to re-establish, and the abort/forget termination bound it governs took five passes to get right
/// (see `docs/process/MUTATION-TESTING-NOTES.md`).
extension MigrationEngine {
    /// Whether `abort` can clean up after a pre-verification failure, and if not, why.
    ///
    /// Factored because the rule it encodes — **`forget` declines anything `abort` can still clean
    /// up** — has to hold across two functions, and stating it in a comment while deriving it twice
    /// is how the pair ended up refusing the same operation. `forget` consumes this rather than
    /// re-deciding: any case that is not `.cleanable` is one it may close out, and the reason string
    /// travels with it into the journal.
    enum AbortDisposition {
        /// `abort` will remove the partial copy described by this PLAN entry. Carried rather than
        /// re-looked-up, so no caller has to establish for itself that a PLAN line exists.
        case cleanable(planned: JournalEntry)
        /// We cannot see whether a copy is there — the volume holding it is not present. Nothing may
        /// be recorded about it, because "no partial copy present" would be a claim about a disk
        /// that is not here. The string is the *reason* only: the remedy belongs to whoever throws,
        /// because `forget` writes this into a permanent record and an embedded "run `migration
        /// forget`" would tell the reader to do the thing that produced the record.
        case unreachable(String)
        /// We can see, and this is not where this migration's copy belongs. Refusing is the answer;
        /// the path is left exactly as it is.
        case declined(String)
    }

    func abortDisposition(entries: [JournalEntry], operationID: String) -> AbortDisposition {
        // Decided here, not by each caller. This case used to be a `guard` in both `abort` and
        // `forget` — the same duplication the enum exists to remove, one level up, and it left a
        // migration with a torn PLAN line refused by both verbs and owned by neither.
        guard let planned = entries.first(where: { $0.state == .planned }), planned.paths.count == 2 else {
            return .declined(
                "Migration \(operationID) has no readable PLAN line, so its paths, direction and category cannot be established; "
                    + "refusing to act on the strength of the remaining lines.")
        }
        let source = planned.paths[0], destination = planned.paths[1]
        let direction = planned.detail["direction"].flatMap { MigrationPlan.Direction(rawValue: $0) }
        let category = planned.detail["category"].flatMap { StorageCatalog.category($0) }
        // The gate `planExternalize`, `planRestore`, `removeSource` and `resume` all apply, missing
        // only here — and `abort` deletes directly, so nothing else covers it. A journal entry
        // naming a category that was never eligible to leave cannot describe a migration of ours,
        // which is exactly the entry not to act on.
        if let c = category, !c.allowedStrategies.contains(.coldStorage) {
            return .declined(
                "Migration \(operationID) names \(c.name), which has no coldStorage strategy, so no migration of it can be legitimate. Nothing is removed.")
        }
        let vaultDir = planned.detail["vault"].flatMap { $0.isEmpty ? nil : $0 }.flatMap { try? verifier.resolveUsable($0).1 }
        let onVault = vaultDir.map { PathSafety.isContained(destination, in: $0) } ?? false
        // Same correction as `preflightSource`, and it matters more here: this decides whether a
        // destination counts as "back at its own home", and for a per-device category the old
        // prefix test said yes for anything anywhere in the device set.
        let atOwnHome = category.map { $0.containsPath(destination, home: home) } ?? false
        func sourcePresent() -> Bool { var st = stat(); return lstat(source, &st) == 0 }

        // Also here rather than at the deletion site, for the same reason: a refusal `abort` makes
        // that the disposition does not know about is a row where the two verbs disagree again.
        //
        // This guard is load-bearing, and the comment it replaces said the opposite.
        //
        // That comment read: UNPINNED knowingly — here for consistency, one place decides, not
        // because a test proves it must be; fixtures cannot make a temp directory into a mount
        // point, "and every path that could be one fails the containment checks first". The
        // last clause was wrong twice over. The containment checks run *after* this guard, in
        // the `switch` below — and they do not exclude mount points anyway:
        //
        //   `.externalize` only asks `PathSafety.isContained(destination, in: vaultDir)`, and a
        //   disk image mounted under `/Volumes/VAULT/XCodeVault/…` is contained. This project
        //   attaches images itself.
        //
        //   `.restore` only asks `atOwnHome`, and a volume mounted at the category's canonical
        //   path is at its own home. That is the canonical-mount strategy ADR-0004 demoted but
        //   did not delete.
        //
        // Containment and mount-ness are orthogonal — `/System/Volumes/Data` is both a mount
        // point and contained in `/System/Volumes`. So nothing else refuses first, and `abort`
        // reaching `.cleanable` calls `removeItem`, which recurses across a mount boundary.
        // This guard is the only thing between a mount point and a recursive delete of a
        // mounted volume's contents.
        //
        // A reviewer caught the first repair of this comment asserting "it still holds" while
        // correcting the ordering that was its only support — the wrong claim promoted from an
        // excuse for having no test to a standing assertion. What is kept from the original is
        // "one place decides": the rule lives here rather than at each caller.
        //
        // Pinned as of 2026-09-18 (issue #13): `/` is a real mount point, exists, and is not a
        // symlink, so this is reachable with the real `MountStatus`. A first attempt injected
        // the answer instead, which merely moved the untested mutation to the line feeding the
        // guard, where it reads as plumbing.
        //
        // Three-valued as of issue #25. This is the site the reviewer used to establish the
        // disposition in the deadlock scenario it found: an `EACCES` on the destination's parent
        // makes `getattrlist` fail, the `Bool` form reads that as "not a mount point", and the
        // destination sails past this guard and is classified `.cleanable`.
        //
        // **`.undetermined` deliberately does NOT decline here, and that is not an oversight.**
        // A first attempt made it `.declined` and re-broke the abort/forget termination bound —
        // the same wedge, through a fourth door. `abortDisposition` runs *before* any journal
        // line: declining here means `ABORT_FAILED` is never written, `abortFailures` never
        // advances, `forget`'s `.cleanable` case has no non-throwing exit, and both verbs refuse
        // forever. Two tests caught it —
        // `testAbortRefusesRatherThanClaimingAbsenceItCouldNotVerify` and
        // `testForgettingWithTheVaultUnpluggedStillLeavesTheCopyNamed`. That bound took five
        // passes to get right and this is the lesson each pass relearned: a refusal that happens
        // before the record of the attempt is a refusal the product cannot recover from.
        //
        // So the classification stays permissive and the *refusal moved to the deletion*, in
        // `abort`, inside the `do` block whose `catch` writes `ABORT_FAILED`. The entry still
        // closes; the mount point is still never removed. Issue #25 says as much in its own
        // words: reaching `.cleanable` here "is survivable rather than a wedge".
        switch MountStatus.mountAnswer(destination) {
        case .isMountPoint:
            return .declined("\(destination) is a mount point; refusing.")
        case .undetermined, .isNotMountPoint: break
        }

        switch direction {
        case .externalize:
            // The source is the live tree. If it is gone the vault copy may be the only one left,
            // and nothing may delete it. (Direction-scoped on purpose: for a restore the "source" is
            // the vault copy, and its absence says nothing about the local partial copy.)
            guard sourcePresent() else {
                return .declined("Source \(source) is gone; not removing \(destination) — it may be the only copy.")
            }
            guard let vaultDir else {
                return .unreachable(
                    "the vault volume for migration \(operationID) is not present, so whether a partial copy remains on it cannot be determined")
            }
            guard PathSafety.isContained(destination, in: vaultDir) else {
                return .declined(
                    "\(destination) is not inside the vault directory \(vaultDir); it is not the partial copy this externalization made. Nothing is removed.")
            }
            return .cleanable(planned: planned)
        case .restore:
            // The partial copy is at the canonical path — the containment `planRestore` applied when
            // it accepted the destination. The vault is not needed to see it, which is what makes an
            // unplugged drive an ordinary case here rather than a dead end.
            guard atOwnHome else {
                return .declined(
                    "\(destination) is not inside \(category?.name ?? "the category")'s own location; it is not the partial copy this restore made. Nothing is removed."
                )
            }
            return .cleanable(planned: planned)
        case .none:
            // A PLAN line from before the `direction` key. Accept whichever containment holds; both
            // targets are structurally constrained, so this cannot aim a deletion anywhere a
            // legitimate plan could not have.
            if atOwnHome { return .cleanable(planned: planned) }
            if onVault {
                guard sourcePresent() else {
                    return .declined("Source \(source) is gone; not removing \(destination) — it may be the only copy.")
                }
                return .cleanable(planned: planned)
            }
            guard vaultDir != nil else {
                return .unreachable(
                    "migration \(operationID) predates the journal's `direction` field and its vault volume is not present, so \(destination) cannot be confirmed to be a copy this tool made"
                )
            }
            return .declined("\(destination) is not where this migration would have put its copy. Nothing is removed.")
        }
    }

    /// Copies that `forget` closed the entry on while the copy itself was still on disk.
    ///
    /// `forget --i-verified-both-copies-myself` is a deliberate escape hatch for a copy the
    /// machine cannot remove, and closing the entry is the point of it. The trade was that the
    /// copy then vanished from `leftoverPartialCopies` — the thing `doctor` and `migration
    /// status` actually read — leaving the user as the only record of it. This returns them so
    /// the reminder survives the escape hatch. They are informational, not a fault: nothing here
    /// is broken and nothing needs to be run.
    public func knownLeftoversAfterForget() throws -> [JournalEntry] {
        var out: [String: JournalEntry] = [:]
        for e in try journal.entries() where e.kind == .migration && e.detail["leftover"] == "1" {
            out[e.id] = e  // the last such line per operation
        }
        return out.values.sorted { $0.sequence < $1.sequence }
    }

    /// Failed or interrupted pre-verification migrations whose destination still exists on disk —
    /// partial copies that block a retry (`doctor` surfaces them; `abort` removes them).
    public func leftoverPartialCopies() throws -> [JournalEntry] {
        var last: [String: JournalEntry] = [:]
        var planned: [String: JournalEntry] = [:]
        var unsafe: Set<String> = []
        for e in try journal.entries() where e.kind == .migration {
            // The PLAN line, for the same reason `resume` and `abort` insist on it: these paths are
            // what `doctor` reports and what `abort` will delete.
            if planned[e.id] == nil, e.state == .planned, e.paths.count == 2 { planned[e.id] = e }
            last[e.id] = e
            if let ph = e.detail["phase"], MigrationEngine.phasesWhereAbortIsUnsafe.contains(ph) { unsafe.insert(e.id) }
        }
        return last.values.filter { e in
            guard !unsafe.contains(e.id), e.state == .failed || e.state == .started, let p = planned[e.id] else { return false }
            // `mayBePresent`, not `== .present`: a copy this cannot stat is exactly the one most
            // worth surfacing, and dropping it is how `doctor` reports a clean machine that is not.
            return MigrationEngine.presence(of: p.paths[1]).mayBePresent
        }.map { planned[$0.id]! }.sorted { $0.sequence < $1.sequence }
    }
}
