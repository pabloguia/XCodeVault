# Manual test protocol — experiments that need root or physical hardware

These cannot run in the automated session (no passwordless `sudo`; physical drive handling).
Each has a harness or exact commands, an expected result, and where to record it. Run them on
a Mac whose developer data is backed up. Record every outcome in
`../architecture/COMPATIBILITY_MATRIX.md` with the standard header from
`scripts/experiments/common.sh` (`xcv_header`).

## E1 (mount half) — can root mount a volume over a path under /Library/Developer?

Read-only half done (`docs/research/evidence/e1-*.txt`): no SIP protection. Mount half:

```bash
hdiutil create -size 2g -fs APFS -type SPARSE -volname XCVPROBE /tmp/xcv-probe.sparseimage
dev=$(hdiutil attach -nomount -plist /tmp/xcv-probe.sparseimage | plutil -extract system-entities json -o - - | python3 -c 'import json,sys; print([e["dev-entry"] for e in json.load(sys.stdin) if e.get("content")=="41504653-0000-11AA-AA11-00306543ECAC"][0])')
sudo mkdir /Library/Developer/xcv-probe
sudo diskutil mount -mountPoint /Library/Developer/xcv-probe "$dev"
mount | grep xcv-probe            # expect: apfs mounted at /Library/Developer/xcv-probe
sudo touch /Library/Developer/xcv-probe/hello && ls -l /Library/Developer/xcv-probe
sudo diskutil unmount /Library/Developer/xcv-probe
sudo rmdir /Library/Developer/xcv-probe
hdiutil detach "$dev"; rm /tmp/xcv-probe.sparseimage
```
Expected: mount succeeds. **Never** mount over the real `CoreSimulator` path. Per ADR-0004 this
only closes H8; it does not revive H1.

## E6 — surprise removal of a vault volume during an operation

1. `xcodevaultctl vault init /Volumes/<ext>` on an APFS SSD.
2. Start `xcodevaultctl externalize --category archives --vault <uuid> --apply` on a ≥ 2 GB
   Archives directory (or a copy of one placed at the standard path on a scratch account).
3. Physically unplug the drive during COPY.
4. Expected: the command fails; `xcodevaultctl migration status` lists the operation as
   INTERRUPTED; the source is intact (`ls ~/Library/Developer/Xcode/Archives`); no
   `/Volumes/<ext>` plain directory appears (if it does, `doctor` must report shadow data).
5. Reconnect. Expected: `vault status` shows VERIFIED (or MOVEDMOUNTPOINT if macOS renamed it,
   in which case `doctor` must explain why). `migration abort <id>` removes the partial copy.
6. Repeat with a clean eject at the same point.
Record: whether the volume came back at the same path, and whether any process wrote into
`/Volumes/<ext>` while absent.

## E7 — shadow-data defense on an unmounted mount point

Only relevant if a canonical-mount strategy is ever revived (ADR-0004). Procedure kept for the
record: create `/Library/Developer/xcv-probe`, `sudo chown root:wheel`, `sudo chmod 0500`,
`sudo chflags uchg`; point an Xcode setting at a path inside it; observe whether Xcode fails
loudly (good) or crashes (bad) — `log stream --process Xcode`.

## E9 — does symlinking ~/Library/Developer/CoreSimulator break the Simulator? (H5)

Do this on a scratch macOS user account, not your main account.
1. Quit Xcode and Simulator. `mv ~/Library/Developer/CoreSimulator ~/CoreSimulator-real &&
   ln -s ~/CoreSimulator-real ~/Library/Developer/CoreSimulator`.
2. Boot an iOS simulator, open Files, try: create a folder, save a file from Safari, share a
   photo. Run a build/run/test cycle from Xcode.
3. Expected per the Aug 2025 report: Files operations fail. Record exactly which.
4. Restore: `rm ~/Library/Developer/CoreSimulator && mv ~/CoreSimulator-real ~/Library/Developer/CoreSimulator`.
Also verify FB12363725: with `~/Library/Developer` itself symlinked, a connected physical
device shows "Preparing" indefinitely / DDI errors in Xcode 15+.

## E8 (behavioural half) — Runtime Library round trip

Needs ≥ 40 GB free internally and an external APFS volume:
```bash
xcodevaultctl runtime export iOS --to /Volumes/<ext>/RuntimeLibrary
xcodevaultctl runtime library --dir /Volumes/<ext>/RuntimeLibrary
xcodevaultctl runtime offload <uuid> --library /Volumes/<ext>/RuntimeLibrary --yes
xcodevaultctl runtime import "/Volumes/<ext>/RuntimeLibrary/iOS <ver> Simulator Runtime.dmg"
xcrun simctl runtime list; xcrun simctl create "probe" "iPhone 17" <runtime>; xcrun simctl boot probe
```
Record: export size, whether download staged internally (watch `df` during export), import
time, and the functional probes (device create/boot/app install).

## E11 — staging space for a runtime install

During `runtime import`, sample `df -k /System/Volumes/Data` every 5 s and record the peak
internal usage vs. the image size. This turns the "~40 GB" community figure into evidence.
