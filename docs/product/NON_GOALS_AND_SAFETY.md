# Non-Negotiable Safety Principles

These override any convenience, performance, or "more GB reclaimed" argument. They
also live in the top-level `CLAUDE.md` so they can't be missed; this file is the
detailed version — expand on rationale here, keep CLAUDE.md as the terse checklist.

## Never

- Disable SIP, or tell a user to. Never make disabling SIP a prerequisite for any
  normal, documented product flow.
- Modify `/System`.
- Delete a protected Apple registry because a forum thread said to.
- Expose arbitrary root shell/command execution from the privileged helper.
- Accept arbitrary client-supplied filesystem paths in the privileged helper's API.
- Delete Archives (or other non-regenerable developer artifacts) without explicit,
  specific user intent for that action.
- Delete source data before a migration has reached a provably safe, verified state.
- Treat a disconnected external volume as harmless. It is a first-class failure mode
  (see `architecture/MIGRATION_ENGINE.md` §Split-brain safety).
- Claim universal compatibility without test evidence in `COMPATIBILITY_MATRIX.md`.
- Hide a known-unsupported configuration from the user instead of reporting it.
- Make a destructive action automatic purely to reclaim more space, or present a
  destructive action as if it were harmless cleanup in the UI.
- Symlink the entirety of `~/Library/Developer` (known to break Xcode 15+ physical
  device DDI discovery even where it worked pre-15). Treat every storage category as
  an independent unit with its own strategy.
- Mount or redirect `/Library/Developer` wholesale — only specific, empirically
  justified subpaths (see `architecture/HYPOTHESES.md`).

## Definition of "supported" for any storage strategy

Not supported merely because copying succeeded. Supported only once, for the relevant
macOS/Xcode combination:

1. Filesystem behavior is understood and documented.
2. Migration is reversible.
3. Disconnect/reconnect behavior is understood.
4. Crash behavior (app, helper, full reboot) is understood.
5. Functional Xcode build tests pass.
6. Functional Simulator tests pass (where applicable).
7. Functional physical-device tests pass (where applicable, or explicitly marked
   pending-hardware).
8. Multi-Xcode-install behavior is evaluated.
9. Data-loss risks are documented.
10. Compatibility evidence is recorded in `COMPATIBILITY_MATRIX.md`.

Anything short of all ten stays labeled **experimental** in code, CLI help, UI copy,
and docs — not just internally.

## Precedence

When safety and "more space reclaimed" conflict, safety wins. When "works on my
machine" and "verified across the matrix" conflict, treat it as unverified until the
matrix says otherwise.
