# Runbook — E8 import half: install a runtime from an exported installer and prove it works

_Status: **pending — to be executed in a fresh session**. Written 2026-09-07 after session 2.
Everything below is self-contained; read `STATUS.md` first, then this file, then act._

## Goal

Close the last open half of experiment E8 (research backlog H4, `docs/architecture/EXPERIMENTS.md`):
prove that a runtime installer exported to external storage with `xcodebuild -downloadPlatform
… -exportPath` can be **re-installed** with `xcodebuild -importPlatform`, that the installed
runtime **works** (device create → boot → shutdown → delete), and measure the internal staging
space the import consumes (E11). Then return the Mac to its prior state.

Why it matters: this is the Runtime Library workflow the product sells (`xcodevaultctl runtime
export/offload/import`). Export and offload are verified; import is not (the only attempt was
refused by CoreSimulator for lack of space — see `docs/architecture/COMPATIBILITY_MATRIX.md`
"E8 import half").

## What is already known (do not re-derive)

- Machine: macOS 26.6.2 (25G83), Intel x86_64, Xcode 26.5 (17F42), `sudo` needs a password
  (never ask for it; never receive it in chat).
- `-downloadPlatform tvOS -exportPath <dir>` downloads 5.03 GB, **installs the runtime
  internally** (4.9 GB under `/System/Library/AssetsV2/com_apple_MobileAsset_appleTVOSSimulatorRuntime`),
  then writes `<dir>/appletvsimulator_26.5_23L470.exportedBundle/Restore/AppleTVOSSimulatorRuntime_Cryptex.dmg`.
  Peak internal use during export: 6.96 GB. It also leaves a **5 GB `.dmg` in
  `/Library/Developer/CoreSimulator/Cryptex/Images/Inbox`** that nobody can delete (even root:
  `Operation not permitted`) — only a **reboot** reaps it. Budget for that.
- `-importPlatform <dmg>` first **copies the dmg into internal staging** (5.8 GB consumed in
  20 s for a 4.9 GB image) and CoreSimulator refuses with `SimDiskImageError Code=14 "Cannot copy
  the image because the disk is almost full"` if headroom is short. `xcodevaultctl runtime import`
  preflight requires **free ≥ 2× image + 3 GB**; for tvOS that is ≈ 12.8 GB.
- Installing a runtime auto-creates default devices for it; deleting the runtime afterwards
  leaves them `unavailable`. **Do not "clean" them with `xcrun simctl delete unavailable`.** That
  command is permanent and sweeps the whole default set, including the user's real devices, which
  go `unavailable` for exactly this reason whenever a runtime is offloaded — and which return to
  `Shutdown` on their own once the same-version runtime is reimported, because CoreSimulator
  rebinds by OS version. `doctor` is tested to refuse to recommend it in this state. An earlier
  version of this line, and of `e8c-import-roundtrip.sh`, said the opposite.
- The external volume: USB SSD, Case-sensitive APFS, UUID `<vault-uuid>`,
  currently named `<vault>` (was `<vault>`; identify by UUID, never by name). Its root is
  root-owned; the only user-writable place macOS guarantees is
  `/Volumes/<name>/.TemporaryItems/folders.$(id -u)/TemporaryItems/` (purged by macOS
  eventually — fine for an experiment). The user's own folders on it (`backup-ios`,
  `mac-ssd-rescue`, `parallels`) are off limits.
- The harness scripts exist and work: `scripts/experiments/e11-staging-monitor.sh`
  (export or import mode, samples internal free space every 5 s, kills xcodebuild below a floor)
  and `scripts/experiments/e8c-import-roundtrip.sh <bundle-or-dmg> --i-understand` (import →
  check a NEW runtime appeared → verify → create a device of a type simctl says that runtime
  supports → boot → **poll `list devices` for `Booted`**, never `bootstatus -b` → delete the probe
  device by UDID → `runtime delete` the image UUID it imported → report which devices went
  unavailable, deleting none). Rewritten 2026-09-16; it refuses outright if the installer is for a
  runtime already installed, because then "restore prior state" would take something away.
  Evidence lands in `docs/research/evidence/`.
- Tooling gotcha from session 2: **never patch Swift sources with string replacement scripts**
  after `swift-format` has run — patterns silently miss. Use `read_for_edit` + `Edit` and verify
  with `grep` before building. Always check `swift test` exit status before committing (a
  `| grep | tail` pipeline hides failures).

## Notes for the executing agent (read before running anything)

- **Scope is exactly this runbook.** Do not start M4/M5 work, do not refactor, do not re-run
  other experiments, do not touch `~/Library/Developer` beyond what the steps below state. If
  something outside this scope looks wrong, write it down in `STATUS.md` under "Follow-ups" and
  continue.
- **Reading order:** `CLAUDE.md` (auto-loaded) → `STATUS.md` → this file. Skim
  `docs/architecture/COMPATIBILITY_MATRIX.md` "E8" entries and `.claude/skills/run-experiment/SKILL.md`.
  Nothing else is needed; do not re-read the research corpus.
- **Long steps exceed the Bash tool's 10-minute limit.** Run steps 1 and 3 with
  `run_in_background: true` (or `nohup … > /tmp/xcv-step.log 2>&1 &`) and poll with
  `until ! pgrep -f e11-staging-monitor >/dev/null; do sleep 15; done` (resp. `e8c-import-roundtrip`)
  in a second background call. The scripts print their summary at the end and write the evidence
  file themselves; read the evidence file, not the live process output.
- **Repository hooks refuse some commands:** unbounded `git log` (use `git log -n 20`),
  `sed -n`/`cat` on Swift files (use the token-pilot `read_range`/`read_symbol` tools or
  `Read` with offset/limit), and filesystem-wide `find` without `-maxdepth`. Evidence `.txt`
  and Markdown files may be read normally.
- **Editing Swift:** use `read_for_edit`/`Read` then `Edit` with the exact text. Never patch
  sources with `sed`/Python string replacement — `swift-format` reflows lines and the patch
  silently misses (this bit the previous session three times).
- **Committing:** run `swift build && swift test`, check the *exit code* (or grep for
  `Test Suite 'All tests' passed`), then commit. Never `git push`, never create a remote.
- **Never** ask for or accept the user's password; never run `sudo`; never disable SIP; never
  modify anything under `/System` or `/Library/Developer/CoreSimulator` directly (only through
  `xcodebuild`/`simctl`, which the scripts already do).
- The user reads Portuguese; reply to the user in Portuguese, keep repository files and commit
  messages in English.

## Prerequisites (check, do not assume)

```bash
git status --short && swift build 2>&1 | tail -1
df -k /System/Volumes/Data | awk 'NR==2{printf "internal free: %d MB\n",$4/1024}'   # need ≥ 20000 MB for export+import of tvOS
xcrun simctl runtime list                                                              # expect only iOS 26.5 + watchOS 26.5
ls /Library/Developer/CoreSimulator/Cryptex/Images/Inbox                              # expect empty; if not, reboot first
.build/debug/xcodevaultctl volumes | grep -A1 <vault-uuid>                                 # the USB volume must be mounted
pgrep -x Xcode && echo "quit Xcode first"
```

**Space budget for tvOS (5 GB image):** export peaks at ~7 GB and leaves +4.9 GB installed
+5 GB stranded in the Inbox; offload returns the 4.9 GB; import then needs ≥ 12.8 GB free.
Starting from 13 GB free (state at the end of session 2) the import preflight will refuse after
the export. Two valid paths: (a) get to ≥ 20 GB free before step 1 — `clean --apply --category
derivedData` is fine without asking (regenerable), Device Support (≈ 15 GB, re-copied from the
devices later) only with the user's explicit OK, never Archives or simulator devices; or (b) run
steps 1–2, ask the user to reboot (reaps the Inbox, +5 GB), then run steps 3–6. Say which path
you took in the evidence notes.

## Procedure

Set variables once (adjust the volume name if it changed; the UUID is what matters):

```bash
cd "$(git rev-parse --show-toplevel)"
MP=$(diskutil info <vault-uuid> | awk -F': *' '/Mount Point/{print $2}')
LIB="$MP/.TemporaryItems/folders.$(id -u)/TemporaryItems/XCodeVault-RuntimeLibrary"; mkdir -p "$LIB"
```

1. **Export tvOS again** (≈ 15 min, downloads 5 GB, installs it, monitored — run in the
   background and poll; the script writes `docs/research/evidence/e11-tvOS-*.txt`):
   ```bash
   scripts/experiments/e11-staging-monitor.sh tvOS "$LIB" 1.5
   ```
   Expect: `export exit=0`, `Exported 'com.apple.CoreSimulator.SimRuntime.tvOS-26-5' …exportedBundle`,
   `simctl runtime list` now shows tvOS 26.5 Ready, internal free dropped ≈ 5 GB, and a new 5 GB
   file in `Cryptex/Images/Inbox`. Record the peak line.

2. **Offload** (this is the product workflow; frees the installed copy, keeps the installer):
   ```bash
   .build/debug/xcodevaultctl runtime library --dir "$LIB"                 # tvOS must show "installer in library ✓"
   RID=$(xcrun simctl runtime list -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(k for k,v in d.items() if "tvOS" in (v.get("runtimeIdentifier") or "")))')
   .build/debug/xcodevaultctl runtime offload "$RID" --library "$LIB" --yes
   xcrun simctl runtime list                                                # tvOS gone
   xcrun simctl list devices                                                # some now `unavailable` — LEAVE THEM
   ```
   Expect: "Installer verified"; journal gets `runtimeOffload` started/completed. Internal free
   rises ≈ 4.9 GB (the Inbox 5 GB stays until reboot). Devices bound to the offloaded runtime go
   `unavailable` and **stay** — they come back by themselves on reimport. The `simctl delete
   unavailable` that used to be on this line deleted them permanently instead.

3. **Import round trip with functional probe** (the actual pending experiment; ≈ 10 min, run in
   the background and poll; writes `docs/research/evidence/e8c-import-*.txt` and `e11-import-*.txt`):
   ```bash
   df -k /System/Volumes/Data | awk 'NR==2{printf "%d MB\n",$4/1024}'       # need ≥ 12800 MB or the preflight refuses
   scripts/experiments/e8c-import-roundtrip.sh "$LIB"/appletvsimulator_26.5_23L470.exportedBundle --i-understand
   ```
   The `--i-understand` is required: the probe boots a device in your DEFAULT device set. Check
   `pgrep -fl xcodebuild` and `xcrun simctl list devices` first.
   Expect, in order: preflight OK (maybe a "tight" warning); `t=…` lines with internal free
   dropping then partially recovering; `import exit=0`; `simctl runtime list -j` showing tvOS
   Ready with `signatureState: Verified`; `simctl runtime verify` exit 0; device created with its
   UDID echoed by `simctl create`; `boot` exit 0; then **`Booted after N s of polling`** — not
   `bootstatus`, which E11 measured hanging on `Data Migration` for minutes after the device was
   already up; shutdown/delete exit 0; `runtime delete` exit 0 on the image UUID; a list of devices
   left unavailable with nothing deleted; asset store back to ~0 KB. Script exit 0.
   A script exit of **3** means it refused and touched nothing (most likely: that runtime is already
   installed). **4** means it could not finish and the evidence file says what is left behind.
   If the preflight refuses for space: the Inbox file from step 1 is the cause — reboot, re-check,
   re-run step 3 only (the installer is already in `$LIB`).
   If `-importPlatform` fails for any other reason: capture the full error from
   `~/Library/Application Support/XCodeVault/journal.jsonl` (`grep -o 'Error Domain.\{0,400\}'`),
   then try `xcodebuild -importPlatform "$LIB"/appletvsimulator_26.5_23L470.exportedBundle`
   (the bundle directory instead of the inner dmg) and `xcrun simctl runtime add <dmg>`; record
   which form CoreSimulator accepts.

4. **Validate the machine is back to its prior state:**
   ```bash
   xcrun simctl runtime list                     # only iOS 26.5 and watchOS 26.5
   xcrun simctl list devices | grep -c unavailable   # 0
   .build/debug/xcodevaultctl doctor             # expect no runtime/device findings; a "Stranded runtime download" is expected until reboot
   ```

5. **Clean up everything the run created on the USB volume:**
   ```bash
   rm -rf "$LIB"; ls "$MP/.TemporaryItems/folders.$(id -u)/TemporaryItems/" | grep -i xcode || echo clean
   ```
   Do not `vault forget`/`init` anything — no vault is registered for this experiment.

6. **Tell the user to reboot** to reclaim the 5 GB Inbox copy, and verify afterwards with
   `ls /Library/Developer/CoreSimulator/Cryptex/Images/Inbox` (empty) and `doctor`.

## Recording the result (mandatory, see `.claude/skills/run-experiment`)

- Evidence files: `docs/research/evidence/e11-tvOS-*.txt` (new export), `e8c-import-*.txt`,
  `e11-import-*.txt`. Confirm the user's home is redacted (`grep -c "$USER"` must be 0).
- `docs/architecture/COMPATIBILITY_MATRIX.md`: replace the "E8 import half — fail
  (environmental)" entry with the new result (pass/fail, peak internal MB during import,
  which argument form `-importPlatform` accepted, boot probe result). Update the "Pending —
  manual" table row for E8.
- `docs/architecture/HYPOTHESES.md` H4: move from "import half pending" to verified/falsified
  with one line of reasoning and the evidence path.
- `docs/research/FINDINGS-2026-09-05.md`: append a dated paragraph under the 2026-09-06
  corrections section with the observed numbers.
- `Sources/XCodeVaultCore/Runtime/RuntimeOperations.swift`: if the measured import peak differs
  materially from 2× + 3 GB, adjust `preflightImport` and the test bounds in
  `Tests/XCodeVaultCoreTests/M2Tests.swift` (`testImportPreflightEnforcesStagingSpace`).
- `STATUS.md`: mark this runbook done; list any new follow-ups.
- Commit with a message that states the result plainly; verify `swift test` passed (check its
  exit code, not a grep) before committing. End the commit message with
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` per project convention.

## Abort conditions

- Internal free space below 1.5 GB at any point: the monitor kills xcodebuild; stop, run
  `doctor`, report, do not retry until space is freed.
- Any error mentioning `SimDiskImageError` other than Code 14: stop, capture it, record it as a
  finding, do not attempt manual cleanup under `/Library/Developer/CoreSimulator` or `/System`.
- The USB volume disappears mid-run: stop; `vault status`/`doctor` behaviour is already
  covered by E6; just record what CoreSimulator did.
