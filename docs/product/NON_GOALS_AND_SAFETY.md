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
  device DDI discovery even where it worked pre-15 — FB12363725). Treat every storage
  category as an independent unit with its own strategy.
- Symlink `~/Library/Developer/DeveloperDiskImages` — it must remain a real directory.
- Symlink `~/Library/Developer/CoreSimulator` at **any** risk level, including with the
  target on the same internal disk. **This prohibition is unconditional** (CLAUDE.md rule 7):
  CoreSimulator has **no** symlink-based strategy at all. The prior art does exactly this —
  do not inherit it.
  E9 has now run (2026-09-08) and this is deliberately *not* a lapsed condition. It could
  **not** reproduce the Aug 2025 report of the Files app being unable to share, save, or
  create folders (H5 / research finding F3) on macOS 26.6.2 / Xcode 26.5 — so do not repeat
  that breakage as established fact. What E9 did show is that the layout leaves **shadow
  device sets** behind: CoreSimulator caches the resolved target, so a restarted
  `CoreSimulatorService` recreated the directory at the old path — **empty in that run**, and
  observed after the symlink had already been removed (rule 6). The
  prohibition therefore stands on "unverified, and known to strand a directory" — a weaker
  claim about the symptom, not a weaker rule.
- Ship pre-macOS-14 compatibility code paths, and in particular never add a second,
  SMJobBless-based privileged-helper implementation (ADR-0001). An untestable
  privileged code path is worse than an unsupported OS.
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

## Disclose, don't bury

Two known limitations must be surfaced to the user *before* they act, not in a
footnote or a release note:

- Apple's own supported DerivedData relocation is reported to break framework tests
  when the target is on an external volume (`xctest` cannot load the bundle). Until E2
  resolves whether the restriction follows the device or the path, warn before
  pointing DerivedData at external storage.
- Installing a 9–12 GB simulator runtime reportedly needs ~40 GB free on the internal
  volume for staging. A user at 5 GB free cannot install one even if the destination is
  external. Say so rather than letting the install fail cryptically.

## Precedence

When safety and "more space reclaimed" conflict, safety wins. When "works on my
machine" and "verified across the matrix" conflict, treat it as unverified until the
matrix says otherwise.
