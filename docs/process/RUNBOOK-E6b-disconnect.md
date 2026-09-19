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

## Prerequisites (check, do not assume)

- [ ] An external volume you can afford to yank, mounted, with nothing of yours on it.
- [ ] `/Library/Developer/CoreSimulator/Caches/dyld` **empty or absent.** The script refuses
      otherwise, deliberately: mounting over a populated cache and then measuring what is underneath
      confuses "macOS recreated a stub" with "the old contents were always there" — a mount hides
      what is beneath it and gives it back on unmount, which is ordinary Unix behaviour and looks
      exactly like the thing being measured.

      **`xcodevaultctl` cannot clear it for you.** The catalog marks
      `coreSimulatorSystemCaches` as `privilege: .root`, so `clean` lists it and stops there — the
      helper that would do it has no client (issue #30). Clearing it is therefore a manual step you
      perform yourself, with `sudo`, on a path you have read and understood:

      ```
      ls -la /Library/Developer/CoreSimulator/Caches/dyld     # look first
      sudo rm -rf /Library/Developer/CoreSimulator/Caches/dyld/*
      ```

      It is regenerable — this is the 7.4-9.4 GB the canonical-mount strategy targets, rebuilt when
      simulators next boot — so the cost is a slow first boot per runtime, not lost data. If you are
      not willing to pay that, run this experiment on a machine where the path is already empty
      instead of talking yourself past the script's refusal.
- [ ] No Xcode, no Simulator, and no `xcodebuild` running. **Check this rather than assume it**:
      `pgrep -l xcodebuild Xcode Simulator`. The shared simulators on this machine are used by test
      rigs; do not disturb one.
- [ ] `swift build` has been run, so `.build/debug/xcodevaultctl` exists.

## Procedure

### Variant A — software unmount (scriptable, run this first)

```
scripts/experiments/e6b-mount-stub-reappearance.sh /Volumes/<your-donor-volume>
```

It mounts the donor volume at the cache path, probes, unmounts, and probes again — immediately,
after ten seconds, and after `simctl` has touched CoreSimulator. It prints where it wrote the
evidence and whether redaction held.

Read probes 2 through 4. The only outcome that makes issue #24's bug reachable is **a directory
present that is not a mount point.**

### Variant B — physical yank (manual, this is the case the issue describes)

1. Mount the donor volume at the cache path exactly as variant A does:
   `sudo mount_apfs -o nobrowse /Volumes/<donor> /Library/Developer/CoreSimulator/Caches/dyld`
2. Confirm it is mounted: `mount | grep Caches/dyld`
3. Record the "while mounted" state:
   `stat -f 'type=%HT mode=%Sp owner=%Su:%Sg links=%l device=%d' /Library/Developer/CoreSimulator/Caches/dyld`
4. **Physically disconnect the drive.** Do not eject it first — the point is the surprise.
5. Immediately, and then again after ten seconds and after a minute, record:
   - `stat -f '...' /Library/Developer/CoreSimulator/Caches/dyld` (or that it is absent)
   - `mount | grep -c Caches/dyld`
   - `ls -A /Library/Developer/CoreSimulator/Caches/dyld | wc -l`
6. Run `xcrun simctl list runtimes`, wait five seconds, and record the same three again.
7. Reconnect the drive. Record whether it returns at the same path, at `/Volumes/<name>`, or as
   `/Volumes/<name> 1` — the last is the shape ADR-0004 and issue #26 both care about.

Paste steps 3-7 into the evidence file variant A produced, as a manually written section, following
the convention `RUNBOOK-E9-symlink-coresimulator.md` sets for its interactive steps.

## Recording the result (mandatory, see `.claude/skills/run-experiment`)

- Evidence: `docs/research/evidence/e6b-mount-stub-<env>.txt`, written by the script plus the
  manual section. Confirm redaction before committing: `grep -c "$USER" <file>` must be 0.
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
- A simulator or `xcodebuild` starts while this is running: stop, unmount the donor, and start over
  when the machine is idle.
- The donor volume contains anything you would miss: stop. This yanks a drive mid-mount.
