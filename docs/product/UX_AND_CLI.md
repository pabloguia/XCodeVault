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

Candidate command surface (adjust as the domain model solidifies; keep this list in
sync with actual `--help` output):

`scan`, `status`, `plan`, `externalize`, `restore`, `clean`, `doctor`, `verify`,
`mount status`, `runtime list`, `runtime download`, `runtime install`,
`runtime offload`, `xcode list`, `compatibility`, `report`.

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
