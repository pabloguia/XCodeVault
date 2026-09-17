# XCodeVault

Honest accounting and safe relocation of the disk space Apple developer tooling consumes —
simulator runtimes, CoreSimulator data, DerivedData, device support, caches, archives — while
keeping Xcode, Simulator, `xcodebuild`, `simctl` and `devicectl` working.

Every mature tool in this space **deletes**; almost none **relocates**. The one prior tool that
tries symlinks `~/Library/Developer/CoreSimulator` — a configuration this project refuses at any
risk level, because CoreSimulator caches the resolved target and a restarted `CoreSimulatorService`
goes on writing to the old path, leaving a shadow device set behind. XCodeVault treats each storage
category as an independent unit with its own strategy, and refuses to claim a strategy works until
it has been measured.

## What this is not

- **Not a one-click space reclaimer.** Deletion is gated, planned, and shown before it happens.
  Archives and other non-regenerable artifacts are never deleted automatically.
- **Not a SIP workaround.** It never disables SIP, never asks you to, and never modifies `/System`.
  A machine with SIP already off is outside the threat model, not a supported configuration.
- **Not finished.** See the state below before trusting it with anything you cannot re-create.

The full list of things this project will not do, and why, is in
[`docs/product/NON_GOALS_AND_SAFETY.md`](docs/product/NON_GOALS_AND_SAFETY.md).

## State, honestly

| area | state |
|---|---|
| Accounting (`scan`, `status`, `report`, `doctor`, `volumes`, `compatibility`) | Working. Read-only, `--json` on every read command. |
| Cleanup and Apple-supported relocation (`clean`, `locations`, `runtime`) | Working, journaled, gated. **These change your machine.** |
| Vault / external migration (`vault`, `externalize`, `restore`, `migration`) | **Experimental.** Verified copy with explicit, opt-in source removal. |
| GUI | First slice only. Builds, launches, read-only plus the clean flow. |
| Privileged helper | Built and security-reviewed, **not reachable from any client** — it needs a signed bundle first. |
| Releases | None. Nothing is signed or notarised. |
| CI | Configured for `macos-15` and `macos-26`. Has never executed: this repository had no remote until now. |

**The important caveat.** Every compatibility claim in
[`docs/architecture/COMPATIBILITY_MATRIX.md`](docs/architecture/COMPATIBILITY_MATRIX.md) was
measured on a **single** Mac — one architecture, one macOS build, one Xcode, one external volume.
Several findings are therefore marked `probable` rather than `verified`, and no amount of review
upgrades them. Publishing this repository is how that changes: CI on two macOS versions, and
results from machines that are not the author's. See
[`docs/adr/0005-public-open-source-release.md`](docs/adr/0005-public-open-source-release.md).

## Build and run

```bash
swift build

.build/debug/xcodevaultctl status         # quick environment summary
.build/debug/xcodevaultctl scan           # what is consuming the internal SSD, per category
.build/debug/xcodevaultctl doctor         # broken/unsafe configurations, proposed repairs
.build/debug/xcodevaultctl compatibility  # every category, strategy, evidence status
.build/debug/xcodevaultctl volumes        # mounted volumes and whether they qualify
```

`scan`, `status`, `report`, `doctor`, `xcode`, `runtime list`, `volumes` and `compatibility` are
read-only and never change anything. `clean`, `locations set-*`, `runtime delete/import/offload`,
`externalize` and `restore` do change things; each shows a plan first, and every change is recorded
in a journal you can inspect with `journal`.

`report` exists to be pasted into an issue: it redacts your home directory.

Requires macOS 14 or later (ADR-0001) and a recent Xcode.

## How claims are made here

This project is research-first, and the docs are the product as much as the code is:

- [`docs/research/`](docs/research/) — sourced findings, and the raw evidence behind each one.
- [`docs/architecture/HYPOTHESES.md`](docs/architecture/HYPOTHESES.md) — the open questions, H1–H9.
- [`docs/architecture/EXPERIMENTS.md`](docs/architecture/EXPERIMENTS.md) — the gating experiments.
- [`docs/architecture/COMPATIBILITY_MATRIX.md`](docs/architecture/COMPATIBILITY_MATRIX.md) — what
  holds on which macOS/Xcode combination, with evidence.
- [`docs/adr/`](docs/adr/) — decisions, including the ones that reversed earlier decisions.

A strategy is labelled **experimental** in code, CLI help, UI and docs until it meets the Definition
of Done in [`docs/process/EXECUTION_PHASES.md`](docs/process/EXECUTION_PHASES.md). "The copy
succeeded" is not that definition.

## Safety rules

Never disables SIP. Never modifies `/System`. Never symlinks `~/Library/Developer`, its
`CoreSimulator`, or its `DeveloperDiskImages`. Never deletes a source before a migration is verified
and reversible. Never auto-deletes Archives. Treats a disconnected external volume as a first-class
failure mode rather than an accident. The privileged helper exposes an allowlisted API only — no
arbitrary shell, no client-supplied paths.

Full list in [`CLAUDE.md`](CLAUDE.md) and
[`docs/product/NON_GOALS_AND_SAFETY.md`](docs/product/NON_GOALS_AND_SAFETY.md).

## Contributing

The contribution this project is short of is **a run of an experiment on a machine that is not the
author's**. See [`CONTRIBUTING.md`](CONTRIBUTING.md), and
[`SECURITY.md`](SECURITY.md) before reporting anything about the root helper.

## License

[MIT](LICENSE).
