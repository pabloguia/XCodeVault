# UX and CLI Spec

## Core question the product answers

"What is consuming my internal SSD, and what can I safely do about it?"

## Summary groupings to show

Internal developer storage · externally relocatable · safely cleanable · cold-storage
eligible · Apple-managed (informational only) · must remain local (with reason) ·
estimated internal SSD savings.

The user-facing grouping is the savings buckets in `STORAGE_CATALOG.md` § Savings
buckets; the groupings above remain in `ScanSummary` and the JSON for existing readers.

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

- Groups (spec 2026-10-03 §5.1; the root `--help` lists commands under task headings): see what uses
  space — `status` (default), `scan`, `plan`, `report`; save space — `clean`, `locations`,
  `externalize`, `restore`, `runtime`; drives — `volumes`, `vault`, `bench`; recover — `migration`,
  `journal`; diagnose — `doctor`, `xcode`, `compatibility`, `permissions`.
- Savings first: `scan` opens with what can be reclaimed — temporarily, and permanently — and the savings
  block ends with the next step, "Next: xcodevaultctl plan delete | park | external"; `scan --details` adds
  the full item table after it. `scan --no-sizes` measures nothing, so it prints no savings, only how to get
  them. `status` measures nothing either and ends with "Measure what you can reclaim: xcodevaultctl scan"
  (and, when Full Disk Access is not granted, how to grant it).
  `plan <delete|park|external>` is read-only: it prints, per category, the command to run to reclaim
  space that one way (`<angle brackets>` are values the user supplies; the commands are never
  translated). Preview forms only; the rows that act immediately are marked.
- Language: `--lang <code>` (`en`, `pt-BR`, `es`, `ja`, `zh-Hans`) on any command, else
  `XCODEVAULT_LANG`, else the macOS language, else English. `--json` and `report` are always English
  (an API and a maintainer record); `report` carries the full item table.
- Read-only (all `--json`): `scan [--details]`, `plan`, `status`, `report`, `doctor`, `xcode list`,
  `runtime list`, `runtime library --dir`, `volumes`, `compatibility`, `locations show`,
  `journal`, `vault status`, `migration status`, `permissions`, `bench <dir>`.
  `doctor --json` findings may carry two optional fields, absent when unset: `bytes` (the finding's size)
  and `parts` (`explanation`, per-item `lines` of `label`/`bytes`, `notOfferedByClean`), set today only on
  `perDeviceRegenerable.*` (R4, 2026-10-04). `detail` still holds the whole text.
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
- Not implemented (from the original candidate list): `verify` (folded into externalize/restore; a standalone re-verify is a follow-up),
  `mount status` (no canonical-mount strategy in v1, ADR-0004), `runtime install`
  (= `runtime import`).

## GUI (S4, spec 2026-10-03 §6)

> Status: shipped on `feat/gui-savings` (2026-10-03), rendered and unit-tested off screen, not yet exercised in a
> signed build. The user-facing description is `docs/USER_GUIDE.md` § The app.

The app is a projection of Core: every number and every decision a screen shows is a Core function with a test, or an
`AppModel` method tested through `AppEnvironment` fakes. Views decide nothing.

- **Sidebar.** *Save space*: Overview, Delete, Park, Run externally. *Details*: Storage, Simulators, Drives (volumes
  and vaults), Health (the doctor), History (the journal), Access.
- **Overview.** The internal-disk bar (`DiskBar`: other data, developer data by primary bucket, free), three cards
  (`OverviewCards`: an "up to" amount, the verified share, the promise, the cost to undo, **Review**), the note that
  the cards are alternatives with the union total, the runtime images `simctl` measured outside the catalog on their
  own line, at most one access row, and the doctor's critical findings. The legacy `ScanSummary` savings numbers
  (`verifiedSavingsBytes`, `estimatedInternalSavingsBytes`) are not shown anywhere in the app; a test greps for them.
- **Delete.** The clean plan grouped by category (`DeleteList`), with a cost-to-undo column and markers; the same
  Trash toggle, exact-count confirmation and journaling as before. The rows another tool deletes (simulator devices,
  runtimes) are listed with **Copy Command** and are never deleted from the app.
- **Park, Run externally.** `SavingsPlanner.rows` with **Copy Command** per row and Park's vault state. The app runs
  none of these commands: a GUI writer for `externalize`, `runtime offload` or `locations set-*` needs its own spec
  and the migration-safety review.
- **Details.** Storage lists every item with a Bucket column (the primary bucket's symbol and title, `StorageTable`);
  Simulators lists the runtimes and the devices with their data size (`SimulatorsTable`; platforms by Apple's names,
  an unmeasured size as "not measured", the runtime total the same `ScanSummary.runtimeImageBytes` the Overview shows; the devices total is the sum of
  simctl's per-device `dataPathSize`, captioned as such, and is a known difference from Delete's "Simulator devices"
  row, which is the catalog's measure of the whole `Devices` folder); the helper's root-only bytes come from one source,
  the Delete list when there is one (`AccessChecklist.rootOnlyBytes`), on the Access screen, the banner and Delete; Drives, Health and History
  are the earlier Volumes, Doctor and Journal views.
- **Never color alone.** A bucket is always its symbol and its title; its color is a fill or a symbol tint, never a
  text color. Every state has a word next to its symbol.
- **Language.** Every string is a catalog key (`docs/process/LOCALIZATION.md`); bytes go through `ByteCount.format`
  in the app's language.

## Permissions — asked at the moment of need (spec 2026-09-27, ADR-0007)

> Status: specification. Each item says which deliverable of
> `docs/superpowers/plans/2026-09-27-user-first-permissions.md` ships it; until then it is planned.

The rule: nothing is asked for up front, and a permission is asked for only when an action needs
it — for Full Disk Access, a scan that was refused, which can be the first. Wherever macOS allows it, asking means one system prompt; the GUI never hands the user a Terminal
command as the primary route. The client never runs a root shell (`osascript … with administrator
privileges`, `AuthorizationExecuteWithPrivileges`, spawned `sudo`): the helper's allowlisted verbs
are the only privileged path.

- **`xcodevaultctl permissions [--json]`** (read-only; shipped 2026-09-28): the Full Disk Access state
  (`granted | notGranted | unknown`) and the helper state (`unavailableInThisBuild | notInstalled |
  awaitingApproval | enabled`), each with one sentence of why and one next step. `--json` shape:
  `{"fullDiskAccess": {"state", "why", "nextStep"}, "helper": {"state", "why", "nextStep"}}`.
  `clean`'s tag for a root row points to it.
- **GUI Access screen** (shipped 2026-09-28 as "Permissions", renamed and rebuilt as a checklist in S4 2026-10-03; not
  yet exercised on screen): two rows — Full Disk Access and the helper — each with its state as a symbol and a word,
  one sentence of why in terms of what it holds back, and one button: **Open Full Disk Access Settings** (or **Check
  again** when the probe could not tell) for Full Disk Access; **Install the Helper…** or **Approve in System
  Settings…** for the helper, and **Uninstall…** (with a confirmation) once it is enabled. When the app becomes active
  after the user returns from System Settings, it re-checks and rescans. The rows are `AccessChecklist` in Core.
- **Full Disk Access at need** (shipped 2026-09-28, not yet exercised on screen): the Overview shows the Full Disk
  Access row only when a scan reports folders refused with `EPERM`, or a size it could not fully read, and only while
  the grant is not known to be present (`AccessChecklist.banner`; at most one row there).
- **The helper at need** (shipped 2026-09-28, gated on a signed build; never run live): choosing a root action opens a sheet with one sentence of
  why and **Allow**; then `register()`, `SMAppService.openSystemSettingsLoginItems()`, poll the
  status, and run the action when it reaches `enabled`. **Uninstall…** calls `unregister()`. The Delete view shows
  the helper's row above its table when a listed row needs root and the helper is not enabled.
- **A button that cannot work is never shown.** A build with no usable team ID, not signed by that
  team, or without the daemon in its bundle, says "Not in this build" and, instead of a button, what to do, as a condition:
  the helper needs a signed build that includes it, none is released yet (#30), and where there is a manual route
  `doctor` or `vault init` prints it. Such a build's helper row is not an Overview banner (nothing there can act on it);
  the Access screen and the Delete view still show it, with the root-only bytes. A screen says it once: where the helper's row is
  shown, the root action's own control below it does not repeat it.
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
