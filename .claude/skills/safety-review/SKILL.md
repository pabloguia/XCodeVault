---
name: safety-review
description: Dispatch the mandatory independent reviews before merging a change to the privileged helper (helper-security-reviewer) or to anything that copies/moves/deletes/mounts data (migration-safety-reviewer). Use before committing such changes.
---

# Mandatory independent safety review

Standing rule (docs/process/AGENTIC_ENGINEERING_SETUP.md): the privileged-helper security review
and the migration-safety review are performed by a **different agent** than the one that wrote the
change.

1. Identify the change set: `git diff --stat` (or the commit range).
2. If it touches `Sources/XCodeVaultHelper*`, XPC client code, launchd plists, or signing scripts
   → launch the `helper-security-reviewer` subagent with the exact diff range.
3. If it touches migration, journal, cleanup, doctor repair plans, catalog strategies, or any
   copy/move/delete/mount code → launch the `migration-safety-reviewer` subagent with the diff range.
4. Both may apply. Run them in parallel.
5. Address every REQUEST CHANGES item, re-run the review, and only then commit. Record in the
   commit message: `Reviewed-by: helper-security-reviewer` / `migration-safety-reviewer`.
6. Never self-approve. If the review cannot run (tooling down), say so in the commit and
   open a follow-up rather than merging silently.
