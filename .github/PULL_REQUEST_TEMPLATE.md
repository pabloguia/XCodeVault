## What this changes, and why

<!-- The why matters more than the what; the diff already shows the what. If this reverses an
earlier decision, say so and add an ADR under docs/adr/ rather than silently overwriting the
reasoning. -->

## The gate

- [ ] `swift build` exits 0 — **checked directly, not grepped from the output**
- [ ] `swift test` exits 0
- [ ] `bash scripts/experiments/test-common.sh` passes, if `common.sh` changed
- [ ] `swift-format lint` is clean, or the remaining warnings are explained below

Measured on: macOS `<version (build)>`, Xcode `<version>`, `<arch>`.

## Safety

- [ ] Nothing here disables SIP, requires it disabled, or modifies `/System`
- [ ] No symlink is introduced for `~/Library/Developer`, its `CoreSimulator`, or its
      `DeveloperDiskImages`
- [ ] No source data is deleted before a verified, reversible migration
- [ ] No non-regenerable artifact (Archives above all) is deleted without explicit user intent
- [ ] Disconnect/reconnect of an external volume cannot leave shadow or duplicate data

## Review required before merge

Tick what applies. Both reviews must be done by someone who did not write the change.

- [ ] Touches the privileged helper, its protocol, XPC client code, the launchd plist, or signing →
      **helper security review**
- [ ] Copies, moves, deletes, mounts or restores user data → **migration safety review**
- [ ] Neither applies

## Claims and evidence

- [ ] No compatibility claim is strengthened here, **or**
- [ ] `docs/architecture/COMPATIBILITY_MATRIX.md` and `docs/architecture/HYPOTHESES.md` are updated,
      with an evidence file under `docs/research/evidence/`, and the strategy still carries its
      `experimental` label everywhere until it meets the Definition of Done in
      `docs/process/EXECUTION_PHASES.md`

<!-- A strategy is not "supported" because a copy succeeded. A finding measured on one machine is
`probable`, not `verified`, however convincing it looked. -->

## Published surface

- [ ] No evidence file added here contains a home directory, account name, volume label, volume
      UUID, private folder name, or the name of a paired physical device
