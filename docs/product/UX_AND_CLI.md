# UX and CLI Spec

## Core question the product answers

"What is consuming my internal SSD, and what can I safely do about it?"

## Summary groupings to show

Internal developer storage · externally relocatable · safely cleanable · cold-storage
eligible · Apple-managed (informational only) · must remain local (with reason) ·
estimated internal SSD savings.

Per category, show: size, current location, what generated it, deletable?, movable?,
regenerable?, expected performance impact, recommended action, risk level. Never
present a destructive action as harmless cleanup — the UI copy and confirmation flow
must make the risk level visible before the action, at every profile level.

## Operational profiles

Safe / Transparent / Expert — see `MISSION.md`. GUI and CLI both respect the active
profile; the CLI should be able to run `--profile safe|transparent|expert` explicitly
per invocation without changing the persisted GUI setting.

## CLI: `xcodevaultctl`

Design the CLI as a first-class citizen — the GUI calls the same shared domain layer,
it does not reimplement CLI logic. Provide `--json` output for automation on every
read command.

Command surface as implemented (2026-09-06; mirrors `xcodevaultctl --help`, keep in sync):

- Read-only (all `--json`): `scan`, `status`, `report`, `doctor`, `xcode list`,
  `runtime list`, `runtime library --dir`, `volumes`, `compatibility`, `locations show`,
  `journal`, `vault status`, `migration status`, `bench <dir>`.
- Changing (each journaled; dry-run/plan by default where meaningful):
  `clean [--category …] [--apply] [--trash] [--force]`,
  `runtime delete <id> [--keep-asset] [--dry-run] --yes`,
  `runtime export <platform> --to <dir> [--build-version] [--arch]`,
  `runtime import <dmg>`, `runtime offload <id> --library <dir> --yes`,
  `locations set-derived-data|set-archives|set-compilation-cache <path>` and `reset-*`,
  `vault init <mount>`, `vault forget <uuid>`,
  `externalize --category archives --vault <ref> [--apply] [--remove-source-after-verify
  --i-confirm-deleting-non-regenerable-data]`, `restore --category … --vault … --name … [--to …] --apply`,
  `migration abort <id>`.
- Not implemented (from the original candidate list): `plan` (folded into each command's
  dry run), `verify` (folded into externalize/restore; a standalone re-verify is a follow-up),
  `mount status` (no canonical-mount strategy in v1, ADR-0004), `runtime install`
  (= `runtime import`).

## Doctor subsystem

Both GUI and CLI must detect (at minimum): broken symlinks, an unexpected
whole-`~/Library/Developer` symlink, missing external volume, incorrect/stale mount,
duplicate/shadow storage, stale `/etc/fstab` entries, CoreSimulator registry
inconsistency (image present but not registered, or vice versa), Xcode version
conflicts, storage-permission issues, unavailable simulator devices, missing
components, low free disk space, and artifacts left behind by prior migration tools
(e.g. mac-ssd-rescue). Doctor proposes repair plans; it never auto-executes a
destructive fix, and never blindly runs a fix copied from a forum post.

## Diagnostic bundle

On request, produce a GitHub-issue-ready diagnostic bundle: app version, macOS
version/build, Xcode versions/builds, filesystem topology, mount state, relevant
command exit codes, migration transaction IDs, compatibility-rule version — with
private/sensitive data excluded automatically. No telemetry by default; local-first,
privacy-preserving.

---

## Additions from the 2026-09-05 research pass

- **Drive qualification must measure 4K random IOPS at QD1–4 and metadata latency, not
  sequential MB/s.** Xcode startup reads ~207 MB dominated by 4 KB–64 KB operations;
  these workloads are IOPS-bound. A cheap USB 3.1 enclosure measured ~210 MB/s
  sequential will be far worse than that ratio suggests on a DerivedData workload. No
  published Xcode-build-across-storage-tiers benchmark exists — producing one (E10) is
  a cheap, real differentiator and the honest basis for the per-category "expected
  performance impact" figure.
- **Surface `-architectureVariant arm64`** as a recommended action on Apple Silicon:
  smaller runtime downloads with no relocation and no risk at all.
- **Surface the staging trap**: installing a 9–12 GB runtime reportedly needs ~40 GB
  free on the internal volume. A user at 5 GB free cannot install a runtime *even if*
  the destination is external. The product must explain this rather than let the
  install fail cryptically.
- **Be explicit about the three honest outcomes per category**: relocatable,
  delete-only, or neither (sealed runtimes). "Neither" is a legitimate answer and
  saying so plainly is a feature — every competing tool silently omits it.
- **Known caveat to disclose up front**, not in a footnote: Apple's own supported
  DerivedData relocation is reported to break framework tests when the target is on an
  external volume (`xctest` cannot load the bundle). Until E2 resolves whether this is
  device- or path-based, the UI must warn before pointing DerivedData at external
  storage.
- **Doctor additions**: detect stranded `Cryptex/Images/Inbox/<UUID>.dmg` downloads,
  orphaned `NeverCollected` MobileAssets under
  `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/`, runtimes
  present as mounted volumes but absent from the registry (and the reverse), and any
  pre-existing `~/Library/Developer/CoreSimulator` symlink (a known-broken
  configuration, H5) including ones this tool did not create.
