# Runbook — E6b: after a volume mounted at a CoreSimulator cache path goes away, what is left?

## Goal

Answer one question with evidence: **when a filesystem mounted at
`/Library/Developer/CoreSimulator/Caches/dyld` disappears, does anything reappear at that path, and
if so with what owner, mode and mount status?**

This is issue #29. It exists because issue #24 added a guard to the privileged cleanup verb on the
strength of a sequence whose middle step has never been observed.

## What is already known (do not re-derive)

- The ordinary-state ownership and mode of the path, on one configuration:
  `755 root:admin /Library/Developer/CoreSimulator/Caches/dyld` (`COMPATIBILITY_MATRIX.md`). This is
  **not** the thing in question — it is the state before any of this, and it is what makes the
  helper's guarded walk pass.
- E9 recorded CoreSimulator recreating a `Devices/` skeleton after a **service restart**. Adjacent,
  and a different scenario: different path, different trigger. Do not treat it as the answer.
- `e6-software-unmount.sh` already covers a vault volume vanishing during and between migrations,
  and records whether a plain `/Volumes/<name>` directory appears. Also adjacent: that is the
  mount-point directory under `/Volumes`, not a cache path inside `/Library/Developer`.
- The guard added for #24 is correct regardless of the answer here. If nothing reappears, the path
  is absent, the verb returns "nothing to do" before it reads its record, and the composition #24
  describes was never reachable by this route. **This experiment sizes the bug, not the fix.**

## Why it cannot be run unattended

Two reasons, and only the second is about hardware:

1. It needs `sudo` to mount and unmount. This machine has no passwordless sudo.
2. The case the issue actually describes is a **surprise** removal — a drive yanked, a cable
   pulled, a bus reset — and a clean `umount` is not obviously the same event. macOS may well
   behave differently. Both variants must be recorded before either is treated as the answer.

## Prerequisites (check, do not assume — there is a script for it)

```
scripts/experiments/e6b-check.sh
```

Read-only, no `sudo`, safe to run any time. It answers which prerequisite is missing instead of
leaving "blocked on hardware" to be rediscovered by sitting down with a drive. It checks the target
path's contents, whether anything is using the simulators, whether a donor volume is mounted,
whether `sudo` will prompt, and whether the CLI is built.

Two of its answers are worth knowing before you start:

- **It does not call any volume a suitable donor.** It lists what is mounted and stops there,
  because it cannot tell a scratch disk from your personal USB drive and the experiment physically
  disconnects the one you name while a filesystem is mounted over a system cache path.
- **There are two allowlisted targets, and you probably do not need to clear either.** The scripts
  take a target NAME — `dyld` or `cryptex`, mirroring `HelperCleanupTarget` — and `e6b-check.sh`
  reports the state of both and names the one to use. On 2026-09-20 on this machine, `dyld` held
  7.1 GB while `cryptex` (`/Library/Developer/CoreSimulator/Cryptex/Caches`) was **empty**, so the
  experiment could run with nothing cleared at all. This issue read as "blocked on hardware" for two
  weeks when what blocked it was a prerequisite on one of two candidates.

  **A `cryptex` run is not a `dyld` run.** Whether macOS recreates a directory can depend on which
  daemon owns the path, so the evidence filename carries the target and the record must not blur
  them. Issue #24's guard covers both targets, so either is evidence for the guard; only a `dyld` run
  is evidence about the canonical-mount strategy's own target.

- **If you do need to clear `dyld`, it is yours to do and `xcodevaultctl` cannot help.** The catalog
  marks `coreSimulatorSystemCaches` as `privilege: .root`, so `clean` lists it and stops — the helper
  that would do it has a client as of issue #30 but no signed build to run under. Look first, then:

  ```
  ls -la /Library/Developer/CoreSimulator/Caches/dyld
  sudo rm -rf /Library/Developer/CoreSimulator/Caches/dyld/*
  ```

  It is regenerable — 7.4 GB on 2026-09-06 and 9.4 GiB on 2026-09-08, the **same** Intel machine
  on macOS 26.6.2 / Xcode 26.5 two days apart, the growth being F10 (a removed runtime leaves
  its dyld shared cache behind). An earlier version of this line called them "two measurements
  on two machines"; they are one machine, and inventing a provenance in the runbook for the
  issue about invented provenances is the joke writing itself. So the cost is a
  slow first boot per runtime, not lost data. If you are not willing to pay it, run this on a
  machine where the path is already empty rather than talking yourself past the script's refusal.

## Procedure

### Variant A — software unmount (run this first)

```
sudo scripts/experiments/e6b-mount-stub-reappearance.sh /Volumes/<your-donor-volume> <dyld|cryptex>
```

It mounts the donor at the cache path, probes, unmounts, and probes again — immediately, after ten
seconds, and after `simctl` has touched CoreSimulator.

**It needs `sudo` and its first action is to unmount your donor**, because a volume cannot be
mounted twice and `mount_apfs` needs its device node. Both variants share `mount-staging.sh`, so
both refuse a donor outside `/Volumes` or on the same physical disk as `/`, both verify the mount
actually took before probing anything, both note in the evidence when they had to create the target
directory — that makes a later "directory present, not a mount point" reading ambiguous — and both
give the donor back on the way out, saying so loudly if they cannot.

That sharing is the point rather than tidiness: this script carried four defects for months and
every one was found while reviewing its twin, including a `mount_apfs` call that could never have
succeeded — which would have made every probe read `absent`, the headline finding, manufactured.

### Variant B — physical yank (this is the case the issue describes)

```
sudo scripts/experiments/e6b-physical-disconnect.sh /Volumes/<your-donor-volume> <dyld|cryptex>
```

It shares its staging with variant A, so the same guards apply: donor unmounted first, refusal of
anything outside `/Volumes` or on `/`'s disk, mount verified before anything is recorded, and the
donor given back on the way out. An earlier version accepted `/System/Volumes/Data`, which would
have unmounted the internal data volume and asked you to pull the internal disk.

Both variants **abort rather than record anything** when the state is not what the evidence would
claim: neither writes a file if the mount did not take, and variant A also aborts if its `umount`
did not take. What is specific to this one is the disconnect check — it polls for the donor's UUID
and device node to disappear and aborts if they do not, rather than taking the operator's word that
the cable was pulled. A Ctrl-C at either prompt ends the run instead of falling through to a success
message, which it used to do.

**This used to be seven steps to run by hand and paste into the evidence file.** It is now a script
that stops and waits for the one thing only a person can do: it stages the mount, records the
mounted state, prints `PHYSICALLY DISCONNECT <volume> NOW` and waits, then records the result
immediately, after ten seconds, after a minute, after `simctl` touches CoreSimulator, and again
after you reconnect. The prompts go to the terminal, not into the evidence file.

The transcription step is what was removed, and that is the point rather than convenience: this
issue exists because a premise was written down without being observed, and a hand-copied
observation is one more place for the same failure.

Read probes 2 through 5. **The only outcome that makes issue #24's bug reachable is a directory
present that is not a mount point.**

## Recording the result (mandatory, see `.claude/skills/run-experiment`)

- Evidence: `e6b-mount-stub-<target>-<env>.txt` (variant A) and `e6b-physical-<target>-<env>.txt` (variant B), both
  under `docs/research/evidence/`, both written entirely by the scripts — there is no manual section
  to paste any more, which is the point of this change. Each script verifies its own redaction
  against `$SUDO_USER`; if it finds the account name it **deletes the file and exits non-zero**, so
  no evidence file survives a failed check — nor a failed redaction or an empty one, which left
  a zero-byte file behind until a reviewer measured all three branches rather than the one. Precisely: the file is written, checked, and removed on
  failure — it exists for the duration of the check and never afterwards. The earlier wording here
  said "exits non-zero without writing" while the code wrote the file, printed `wrote <path>`, and
  then left it on disk on a leak, with the previous good evidence already renamed `-superseded-`. `$USER` is root under `sudo`, so the old advice to
  `grep -c "$USER"` would have passed on a file full of the operator's name.
- `docs/architecture/HYPOTHESES.md`: record the answer against the #24 premise — whether a stub
  reappears, with what owner and mode, and whether the mount query calls it a mount point.
- `docs/architecture/COMPATIBILITY_MATRIX.md`: an E6b entry in the same format as E7/E8, and update
  the E6 row in the "Pending — manual" table.
- `STATUS.md`: update the E6 bullet under "Blocked / pending".
- **The comments that currently say "inferred, not observed"** — in
  `Sources/XCodeVaultHelperCore/HelperMountHistory.swift` and
  `Tests/XCodeVaultCoreTests/CleanupSplitBrainTests.swift` — must then be corrected to cite the
  evidence, **or** corrected to say the premise was wrong. Leaving them as "inferred" after the
  measurement exists is the failure mode this project cares most about.
- Close issue #29 with the result stated plainly, including the case where nothing reappeared.

## Abort conditions

- The target path is not empty: stop. The script refuses; do not talk yourself past it by hand.
- Anything other than the donor volume is mounted at the cache path: stop and unmount nothing.
- A simulator or `xcodebuild` starts while this is running: stop with Ctrl-C and start over when the
  machine is idle. Ctrl-C now ends the run and unmounts the *target*; the donor was already unmounted
  during staging and is remounted by the same cleanup. Earlier advice here said to "unmount the
  donor", which described neither what is mounted nor what the scripts do.
- The donor volume contains anything you would miss: stop. This yanks a drive mid-mount.
