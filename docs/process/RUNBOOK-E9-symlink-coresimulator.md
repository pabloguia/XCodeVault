# Runbook — E9: does symlinking `~/Library/Developer/CoreSimulator` break the Simulator?

_Status: **pending — to be executed in a fresh session**. Written 2026-09-08 after session 4.
Everything below is self-contained; read `STATUS.md` first, then this file, then act._

## Goal

Close E9 (research backlog H5, `docs/architecture/EXPERIMENTS.md`): reproduce or refute Jeff
Johnson's August 2025 report that symlinking `~/Library/Developer/CoreSimulator` breaks
Simulator subsystems (Files app: cannot share, save, or create folders) **even when the
symlink target stays on the same internal disk** — on this machine's current macOS/Xcode. Also
verify the FB12363725 child-symlink allowlist question, and (secondary, only if a physical
device is connected) confirm the "connected device shows Preparing indefinitely" report when
`~/Library/Developer` itself is symlinked.

Why it matters: H5, if confirmed, removes "per-category symlink" as a safe fallback for
CoreSimulator at *any* risk level — which is exactly the technique `mac-ssd-rescue` (the prior
art) uses and exactly what `CLAUDE.md` rule 7 already forbids offering as a product strategy.
This experiment is about turning that already-assumed-true product rule into a **verified**
line in `HYPOTHESES.md`, with our own reproduction on the current OS/Xcode combination — not
about deciding whether to build the feature (we already decided not to).

## What is already known (do not re-derive)

- Machine: macOS 26.6.2 (25G83), Intel x86_64, Xcode 26.5 (17F42). This experiment needs **no
  `sudo` and no root** — `~/Library/Developer/CoreSimulator` is entirely inside the user's own
  home directory, and a rename + symlink there is an ordinary user-level filesystem operation.
  If anything unexpectedly demands root, stop and tell the user the exact command — do not run
  it.
- **Run on the user's own account, in place.** The user explicitly authorized this (2026-09-08):
  "O coresimulator se refaz se for necessário (é recuperável)... Vou dar permissão para que
  execute tudo que for necessário, e vai ser executado no meu próprio usuário. Se tivermos
  problemas, podemos recuperar, não precisa de um usuário novo." No scratch macOS account is
  required — `docs/process/MANUAL_TEST_PROTOCOL.md`'s "do this on a scratch account" note is
  superseded by this explicit authorization for this run.
- **Real devices exist and are in daily use** (baseline as of 2026-09-08, re-check at execution
  time — do not assume this is still current):
  - iOS 26.5: `iPhone 17 Pro Max` (`15EA64C9-8286-40CC-881A-B19C606C7F88`), `iPhone SE (3rd
    generation)` (`855CCF05-5E74-4372-ADB5-7ADE52900AE8`).
  - watchOS 26.5: `Apple Watch Ultra 3 (49mm)` (`0F29E552-3BA3-413D-96ED-B810CD690DC4`).
  - These belong to the user's own `MySmokeiOS` project (a separate repo, `~/projects/smoke`).
    They are not ours to delete or leave broken. The whole point of "recoverable" is that
    `CoreSimulator`'s content itself never changes — only a rename + symlink + reverse rename —
    so these devices' data is never at risk from the swap itself, only from whatever CoreSimulator
    or the Simulator UI does *while* the symlink is in place (which is the very thing being
    tested).
  - `~/Library/Developer/CoreSimulator` is **9.1 GB**. The swap (`mv` + `ln -s` on the same
    volume) is a rename, not a copy — instantaneous, no extra disk space needed, no data
    duplicated.
- **A physical device is paired and available** (2026-09-08): an iPhone 17 Pro Max
  and an Apple Watch Ultra 2 (`xcrun devicectl list devices`). If
  still paired/available at execution time, use the iPhone for the FB12363725 secondary check
  (§ Procedure step 8); if not connected, note it as not tested rather than skipping silently.
- Repository conventions from session 4 (2026-09-07/08, `RUNBOOK-E8-import-roundtrip.md`,
  `.claude/skills/run-experiment/SKILL.md`): evidence files go in `docs/research/evidence/`,
  redacted (`grep -c "$USER" <file>` must be 0), written via `scripts/experiments/common.sh`'s
  `xcv_header`/`xcv_run`/`xcv_redact` helpers when scripted. Editing Swift: `read_for_edit` +
  `Edit` with exact text, never `sed`/Python string replacement (bit a prior session three
  times). Committing: run `swift build && swift test`, check the *actual exit code* (not a
  `| grep | tail` pipeline), then commit. Long-running steps exceed the Bash tool's timeout —
  run them with `run_in_background: true` and poll (see step 6 below; `bootstatus -b` in
  particular can itself hang after the device has actually finished booting — verify boot state
  via `xcrun simctl list devices` directly rather than trusting `bootstatus`'s own termination,
  per the 2026-09-08 E8-iOS finding in `HYPOTHESES.md` H4).

## Notes for the executing agent (read before running anything)

- **Scope is exactly this runbook.** Do not start other work, do not refactor, do not re-run
  other experiments. If something outside this scope looks wrong, write it down in `STATUS.md`
  under "Blocked / pending" and continue.
- **Reading order:** `CLAUDE.md` (auto-loaded) → `STATUS.md` → this file. Skim
  `docs/architecture/EXPERIMENTS.md` "E9", `docs/architecture/HYPOTHESES.md` "H5", and
  `docs/process/MANUAL_TEST_PROTOCOL.md` "E9". Nothing else is needed; do not re-read the
  research corpus.
- **This experiment is riskier than E7/E8.** Those touched one throwaway device or one runtime
  via official `xcodebuild`/`simctl` verbs. This one redirects the directory that backs **every**
  simulator device on the machine via a raw filesystem symlink — closer to what the product
  explicitly refuses to ever do (`CLAUDE.md` rule 7). Treat every step as reversible-by-design
  (rename, never delete) but verify state before AND after every step rather than assuming.
- **Before touching anything:** confirm no `xcodebuild`/`Simulator.app`/`Xcode.app` process is
  running (the user's `MySmokeiOS` project has been actively built/tested throughout the prior
  sessions on this machine). If something is running, stop and ask the user before quitting it —
  do not silently kill a build that might be theirs in progress. Xcode/Simulator with no unsaved
  documents are safe to quit outright once confirmed idle (there is nothing to lose by quitting
  an IDE with no open unsaved editor).
- **The GUI steps (Files app interaction) need a computer-use-capable tool** — this repo's
  `mcp__Claude_Code_iOS_Simulator__*` tools (if present in this session) or the generic
  computer-use screenshot/click tools. If neither is available, do the `simctl`-scriptable
  sanity pass (step 5) and the build/run/test cycle (step 6), mark the interactive Files-app
  pass (step 7) as not executed, and say so plainly in the recorded result — do not skip it
  silently and do not claim it passed without having actually clicked through it.
- **Restoration is mandatory regardless of outcome.** If any step fails, aborts, or the agent
  gets confused, the LAST thing done before ending the session must still be step 9 (restore).
  Never leave `~/Library/Developer/CoreSimulator` as a symlink at the end under any
  circumstance, pass or fail.
- **Never** ask for or accept the user's password; never run `sudo` (this experiment does not
  need it — if something demands it, that is itself a finding, stop and report it rather than
  supplying credentials); never disable SIP; never modify anything under `/System`; never touch
  the user's `~/projects/smoke` repository or its devices' app data directly (only through the
  official `simctl`/`xcodebuild` surface, and only the throwaway probe device created in this
  runbook).
- The user reads Portuguese; reply to the user in Portuguese, keep repository files and commit
  messages in English.

## Prerequisites (check, do not assume)

```bash
git -C ~/projects/XCodeVault status --short && (cd ~/projects/XCodeVault && swift build 2>&1 | tail -3)
pgrep -x Xcode && echo "Xcode running — ask before quitting" || echo "Xcode not running"
pgrep -x Simulator && echo "Simulator running — ask before quitting" || echo "Simulator not running"
pgrep -fl xcodebuild || echo "no xcodebuild running"
xcrun simctl list devices                                    # record this as the baseline
xcrun simctl runtime list
du -sh ~/Library/Developer/CoreSimulator
df -k /System/Volumes/Data | awk 'NR==2{printf "internal free: %d MB\n",$4/1024}'
xcrun devicectl list devices 2>&1                             # physical device, for step 8
ls -la ~/Library/Developer/CoreSimulator 2>&1 | head -1        # must NOT already be a symlink
```

If `~/Library/Developer/CoreSimulator` is already a symlink, or `~/CoreSimulator-real` already
exists, STOP — a prior run was not cleaned up. Investigate and resolve that before starting
(most likely: restore per step 9's commands using whatever `~/CoreSimulator-real` contains),
do not layer a second swap on top.

## Procedure

1. **Quit Xcode and Simulator** if running (after confirming with the user per the notes above
   if anything looked like it might be mid-build):
   ```bash
   osascript -e 'quit app "Simulator"' 2>/dev/null; osascript -e 'quit app "Xcode"' 2>/dev/null
   sleep 2
   ```

2. **Swap in the symlink** (instantaneous rename, same volume, no extra space needed):
   ```bash
   mv ~/Library/Developer/CoreSimulator ~/CoreSimulator-real
   ln -s ~/CoreSimulator-real ~/Library/Developer/CoreSimulator
   ls -la ~/Library/Developer/CoreSimulator   # expect: symlink -> /Users/<user>/CoreSimulator-real
   readlink ~/Library/Developer/CoreSimulator
   ```

3. **Confirm CoreSimulatorService still sees the same devices through the symlink:**
   ```bash
   xcrun simctl list devices
   ```
   Compare against the baseline from Prerequisites. If devices are missing or the command
   errors, first try restarting the service before concluding anything is broken:
   ```bash
   pkill -9 -f com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null; sleep 2
   xcrun simctl list devices
   ```
   If devices are still missing/wrong after the restart, this is itself a finding ("the symlink
   breaks basic device discovery, before any Files-app interaction is even attempted") — record
   it, then skip directly to step 9 (restore); do not attempt steps 4-8 against a broken
   registry.

4. **`simctl`-level sanity pass** (no GUI yet) on a throwaway device, never the real ones:
   ```bash
   RT=$(xcrun simctl runtime list -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["runtimeIdentifier"] for v in d.values() if "iOS" in v.get("platformIdentifier","") or "iOS" in v.get("runtimeIdentifier","")))')
   UDID=$(xcrun simctl create xcv-e9-probe "iPhone 17 Pro" "$RT")
   xcrun simctl boot "$UDID"
   # do NOT rely on `simctl bootstatus -b` alone (it can hang after the device has actually
   # booted — see the note above); poll `simctl list devices` directly, e.g.:
   for i in $(seq 1 40); do xcrun simctl list devices | grep -q "$UDID.*Booted" && break; sleep 5; done
   xcrun simctl list devices | grep "$UDID"
   echo hello-e9 > /tmp/xcv-e9-test.txt
   xcrun simctl io "$UDID" screenshot /tmp/xcv-e9-screenshot-1.png
   ```
   Record exit codes and whether the screenshot file was actually produced (non-zero size).

5. **Files-app interactive pass (GUI, the actual claim under test).** Open Simulator.app,
   bring the probe device to front, open the Files app inside the guest, and attempt, in order,
   screenshotting each result:
   - Create a new folder (On My iPhone → \[+\] → New Folder).
   - Save a file from Safari ("Save to Files" on any downloadable page, or long-press a Safari
     screenshot/PDF → Share → Save to Files).
   - Share a photo (Photos app → any image, or `xcrun simctl addmedia "$UDID" <path-to-any-png>`
     first to seed one → Share → Save to Files, or vice versa).
   Record the exact error dialog text (if any) for each, or confirm each succeeded. This is the
   step the original report says fails; do not infer pass/fail from steps 4/6 alone — this one
   must actually be attempted via the GUI if a computer-use tool is available in this session
   (see notes above for the fallback if not).

6. **Build/run/test cycle** on a disposable scratch iOS app (do not use `~/projects/smoke`):
   ```bash
   SCRATCH=/private/tmp/xcv-e9-scratch   # or this session's own scratchpad dir if one is given
   mkdir -p "$SCRATCH/Sources/E9Probe"
   cat > "$SCRATCH/project.yml" <<'YAML'
   name: E9Probe
   options:
     bundleIdPrefix: com.xcodevault.e9probe
   targets:
     E9Probe:
       type: application
       platform: iOS
       deploymentTarget: "17.0"
       sources: [Sources/E9Probe]
       info:
         path: Sources/E9Probe/Info.plist
         properties:
           UILaunchScreen: {}
   YAML
   cat > "$SCRATCH/Sources/E9Probe/App.swift" <<'SWIFT'
   import SwiftUI
   @main struct E9ProbeApp: App {
     var body: some Scene { WindowGroup {
       Text("E9 probe").onAppear {
         let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("e9-write-test.txt")
         try? "e9 write ok".write(to: url, atomically: true, encoding: .utf8)
       }
     } }
   }
   SWIFT
   cd "$SCRATCH" && xcodegen generate
   xcodebuild build -project E9Probe.xcodeproj -scheme E9Probe -destination "id=$UDID" -derivedDataPath "$SCRATCH/dd"
   xcrun simctl install "$UDID" "$SCRATCH/dd/Build/Products/Debug-iphonesimulator/E9Probe.app"
   xcrun simctl launch "$UDID" com.xcodevault.e9probe.E9Probe
   sleep 3
   xcrun simctl get_app_container "$UDID" com.xcodevault.e9probe.E9Probe data
   ```
   Confirm the app installed, launched (no crash), and — most importantly — actually wrote
   `e9-write-test.txt` into its own container's Documents directory through the symlinked
   `CoreSimulator` path (`ls` the path from `get_app_container` + `/Documents/`). This is the
   automatable proxy for "normal build/run/test cycle" from `EXPERIMENTS.md`.

7. **Clean up the probe device and scratch project:**
   ```bash
   xcrun simctl shutdown "$UDID" 2>/dev/null
   xcrun simctl delete "$UDID"
   rm -rf "$SCRATCH"
   ```

8. **FB12363725 secondary check — only if a physical device is still paired
   (`xcrun devicectl list devices`).** With `~/Library/Developer/CoreSimulator` still
   symlinked (do this before step 9's restore), connect/observe the physical iPhone in Xcode's
   Devices & Simulators window or via `xcrun devicectl list devices --timeout 10` repeatedly; the
   report claims a connected device shows "Preparing…" indefinitely with DDI errors. This needs
   `~/Library/Developer` itself symlinked, not just `CoreSimulator` — that is a **different,
   larger** swap than steps 2-7 and carries more risk (it moves `DeveloperDiskImages`, which
   `CLAUDE.md` rule 7 says must never be a symlink). **Do not perform that larger swap.** Instead,
   treat this step as opportunistic and read-only: check whether the physical device still shows
   "available" in `devicectl` while only `CoreSimulator` (not all of `~/Library/Developer`) is
   symlinked. If it does, that is useful negative evidence on its own (narrower symlink is fine
   for physical-device support) without needing the riskier full swap — record it as such and do
   not attempt the `~/Library/Developer`-wide symlink in this runbook.

9. **Restore (mandatory, run this even if earlier steps failed or were aborted):**
   ```bash
   osascript -e 'quit app "Simulator"' 2>/dev/null; sleep 1
   rm ~/Library/Developer/CoreSimulator
   mv ~/CoreSimulator-real ~/Library/Developer/CoreSimulator
   readlink ~/Library/Developer/CoreSimulator || echo "confirmed: real directory, not a symlink"
   pkill -9 -f com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null; sleep 2
   xcrun simctl list devices    # must match the Prerequisites baseline exactly: iPhone 17 Pro Max,
                                 # iPhone SE (3rd generation), Apple Watch Ultra 3 (49mm) — no more, no less
   ```

10. **Final validation:**
    ```bash
    xcrun simctl runtime list        # iOS 26.5 + watchOS 26.5, unchanged
    xcrun simctl list devices | grep -c unavailable   # 0
    cd ~/projects/XCodeVault && .build/debug/xcodevaultctl doctor   # no new findings caused by this run
    ```
    If anything differs from the Prerequisites baseline, do not consider the experiment closed —
    report the discrepancy to the user immediately and do not attempt to fix it yourself beyond
    what steps 9-10 already prescribe (this is exactly the "recoverable, but let's know if it
    wasn't" checkpoint the user asked for).

## Recording the result (mandatory, see `.claude/skills/run-experiment`)

- Evidence: write a script under `scripts/experiments/e9-symlink-coresimulator.sh` mirroring the
  `xcv_header`/`xcv_run`/`xcv_redact` pattern from `scripts/experiments/e8c-import-roundtrip.sh`
  for the scriptable parts (steps 2-4, 6-7, 9-10); paste the Files-app interactive results
  (step 5, and step 8 if performed) into the same evidence file as a manually-written section
  (screenshots do not need to be committed — describe what was observed). Confirm redaction
  (`grep -c "$USER" <file>` must be 0) before committing.
- `docs/architecture/HYPOTHESES.md` H5: move from "probable" to verified or falsified, with the
  exact Files-app error text (or confirmation nothing failed) and the write-test result from
  step 6.
- `docs/architecture/COMPATIBILITY_MATRIX.md`: add an "E9" entry in the same format as the E7/E8
  entries; update the "E9 CoreSimulator symlink" row in the "Pending — manual" table.
- `docs/research/FINDINGS-2026-09-05.md`: append a dated paragraph under the corrections section.
- `STATUS.md`: mark this runbook done, remove/update the E9 bullet under "Blocked / pending",
  note any follow-ups.
- Commit with a message stating the result plainly (pass/fail, exact Files-app symptom or its
  absence). Verify `swift test`'s actual exit code before committing. Do not `git push`.
  End the commit message with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` unless
  this session's system instructions say otherwise — follow whatever attribution the running
  session is actually told to use, not this note, if they differ.

## Abort conditions

- Step 3 shows a broken/incomplete device registry even after a CoreSimulatorService restart:
  abort to step 9 immediately, do not attempt steps 4-8.
- Any step causes an actual system-level crash (kernel panic, repeated unrecoverable
  SpringBoard/CoreSimulatorService crash loop, beachball requiring a hard reboot): stop
  interacting, let things settle, then run step 9's restore commands as soon as the machine is
  responsive again; report full details to the user, including whether a reboot was needed.
- The physical device disappears from `devicectl` mid-step-8: that is an expected possible
  outcome of the report being reproduced — record it, do not troubleshoot the physical device's
  own pairing, move on to step 9.
- If genuinely unsure whether to keep going or restore: restore. The user has said recovery is
  fine and expected; an unnecessary early restore costs a re-run, but an unrecovered symlink left
  in place overnight risks the user's next unrelated Xcode session.
