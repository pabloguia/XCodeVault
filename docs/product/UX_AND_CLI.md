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

> **Not implemented. This section is a specification, not a description of the shipped tool.**
> A `--profile safe|transparent|expert` option existed on the CLI until 2026-09-18 and was read by
> nothing: it appeared in every subcommand's `--help` and changed no behaviour. On a tool that
> deletes files, `--profile safe` reads as a constraint on the invocation, so it was removed rather
> than left as a flag that had already shipped doing nothing. If profiles return, they return as
> something that acts.

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
  `journal`, `vault status`, `migration status`, `permissions`, `bench <dir>`.
- Changing (each journaled except `vault forget`, which only edits the registry; dry-run/plan by
  default where meaningful):
  `clean [--category …] [--apply] [--trash] [--force]`,
  `runtime delete <id> [--keep-asset] [--dry-run] --yes`,
  `runtime export <platform> --to <dir> [--build-version] [--arch]`,
  `runtime import <dmg>`, `runtime offload <id> --library <dir> --yes`,
  `locations set-derived-data|set-archives|set-compilation-cache <path>` and `reset-*`,
  `vault init <mount>`, `vault forget <uuid>`,
  `externalize --category archives --vault <ref> [--apply] [--remove-source-after-verify
  --i-confirm-deleting-non-regenerable-data]`, `restore --category … --vault … --name … [--to …] --apply`,
  `migration abort <id>`, `migration resume <id>`,
  `migration forget <id> --i-verified-both-copies-myself`.
- Labels (rule 10): every command whose strategy is experimental — read-only ones included, such as
  `runtime library`, `vault status` and `migration status` — says so in its `abstract`, the first line
  of its own `--help` and the only line the parent's command list shows; a `discussion:` shows in the
  command's own help only. `runtime delete` and `locations reset-*` carry no label.
  `CLIExperimentalLabelTests` pins the labels, and the absence on `runtime delete`, against the catalog.
- Not implemented (from the original candidate list): `plan` (folded into each command's
  dry run), `verify` (folded into externalize/restore; a standalone re-verify is a follow-up),
  `mount status` (no canonical-mount strategy in v1, ADR-0004), `runtime install`
  (= `runtime import`).

## Permissions — asked at the moment of need (spec 2026-09-27, ADR-0007)

> Status: specification. Each item says which deliverable of
> `docs/superpowers/plans/2026-09-27-user-first-permissions.md` ships it; until then it is planned.

The rule: the first run asks for nothing, and a permission is asked for only when an action needs
it. Wherever macOS allows it, asking means one system prompt; the GUI never hands the user a Terminal
command as the primary route. The client never runs a root shell (`osascript … with administrator
privileges`, `AuthorizationExecuteWithPrivileges`, spawned `sudo`): the helper's allowlisted verbs
are the only privileged path.

- **`xcodevaultctl permissions [--json]`** (read-only; shipped 2026-09-28): the Full Disk Access state
  (`granted | notGranted | unknown`) and the helper state (`unavailableInThisBuild | notInstalled |
  awaitingApproval | enabled`), each with one sentence of why and one next step. `--json` shape:
  `{"fullDiskAccess": {"state", "why", "nextStep"}, "helper": {"state", "why", "nextStep"}}`.
  `clean`'s tag for a root row points to it.
- **GUI Permissions section** (deliverable 3; buttons for the helper in deliverable 4): two rows —
  Full Disk Access and the helper — each with a status, one sentence of why, and one button:
  **Open Settings** for Full Disk Access; **Install…** or **Uninstall…** for the helper. When the app
  becomes active after the user returns from System Settings, it re-checks and rescans.
- **Full Disk Access at need** (deliverable 3): the Overview says "Some folders could not be read"
  with **Open Settings** only when a scan reports folders refused with `EPERM`, and only while the
  grant is not known to be present.
- **The helper at need** (deliverable 4): choosing a root action opens a sheet with one sentence of
  why and **Allow**; then `register()`, `SMAppService.openSystemSettingsLoginItems()`, poll the
  status, and run the action when it reaches `enabled`. **Uninstall…** calls `unregister()`.
- **A button that cannot work is never shown.** A build with no usable team ID, or without the daemon
  in its bundle, says "Not available in this build" in the same place and shows the manual route
  (the text remediation) instead.
- Whether the launchd daemon needs Full Disk Access for `Caches/dyld` is **unmeasured** until the
  helper's first live run (#30).

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
