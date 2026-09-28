# User-first Docs and Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user can download XCodeVault and use it without worrying: the first run asks for nothing, each permission is asked for only when an action needs it, and every button shown can actually work.

**Architecture:** One permissions model in `XCodeVaultCore` (Full Disk Access probe, helper state, privilege requirement, privileged actions, pure UI decisions, the approval flow and the action runner) consumed by the CLI and the GUI. Everything that touches `SMAppService` or XPC stays in `Sources/XCodeVaultHelperClient/HelperClient.swift`, the one reviewed file allowed to reach the helper. The GUI holds no decisions: it asks Core what to show.

**Tech Stack:** Swift 6 (language mode 6), SwiftPM, macOS 14+, XCTest, SwiftUI, ServiceManagement (`SMAppService`), `swift-argument-parser`.

**Spec:** `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md` (approved 2026-09-27; the source of truth for scope — do not reopen its decisions).

## Operator decisions taken 2026-09-27, before this plan

The spec assumed three things the code did not match. The operator decided:

1. **Where the vault-folder action lives.** No doctor finding existed for vault-folder creation; the `sudo install -d` advice appeared only when `vault init` failed. Decision: `vault init` journals that refusal, and `doctor` turns the latest one per volume into the finding `vault-dir:<uuid>`, which carries the structured action `createVaultDirectory(volumeUUID:)`. The text remediation stays as the fallback.
2. **What "not available in this build" covers.** A signed build without `--with-helper` has no daemon plist, so `register()` would fail. Decision: `unavailableInThisBuild` = unusable team ID **or** daemon plist absent from the bundle.
3. **Whether the dyld cache is wired too.** Decision: yes — deliverable 4 also runs `removeRegenerableSystemDirectoryContents(coreSimulatorDyldCache)` through the helper, with a client-side refusal while Xcode, a simulator, `simctl` or `xcodebuild` runs (the verb has no in-use check of its own), and with the migration-safety review.

## Global Constraints

Every task's requirements implicitly include this section.

- Minimum macOS 14.0 (ADR-0001). No pre-14 code paths. `SMAppService` only; never `SMJobBless`.
- The first run asks for nothing. A permission is asked for only at the moment an action needs it.
- Wherever macOS allows it, "asking" means one system prompt; the GUI user is never handed a Terminal command as the primary route.
- Full Disk Access cannot be granted by code or password. The app may only open `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, detect the grant, and continue.
- Never run a root shell from the client: no `osascript … with administrator privileges`, no `AuthorizationExecuteWithPrivileges`, no spawned `sudo`. The helper's allowlisted verbs are the only privileged path.
- Whether the launchd daemon needs Full Disk Access is **unmeasured** — say so everywhere until the first live run (#30).
- A button that cannot work is never shown.
- Labels marked *experimental* stay where they are (CLAUDE.md rule 10).
- `register()`, the approval round-trip and XPC calls cannot run live before M5: unit-test them with fakes and record them as *pending* in `COMPATIBILITY_MATRIX.md`.
- Every refusal test has a positive control. Tests pin the condition (an enum case, a count), not the wording — except where the spec pins wording ("unmeasured").
- `scripts/public-surface.sh` rule 1 scans **every** public symbol in `XCodeVaultCore`: no public declaration may render as `throws -> Void` or `throws -> ()`. Use protocol methods (`func register() throws`) instead of public throwing closures.
- Seams are `let`, set through `init`; test-only initialisers are `internal`.
- `swift-format lint --strict`: 4-space indent, 160 columns, ordered imports, lowerCamelCase. Split long string literals with `+`.
- Code, comments, docs and commit messages in English. Conversation with the operator in Portuguese.
- Machine: no `sudo` by any route (hand the operator the commands instead); never boot, shut down or erase a simulator; check `pgrep -lx 'xcodebuild|launchd_sim'` first; build + test takes 10–20 min, so batch edits per build cycle; never move or push `~/projects/XCodeVault-pre-rewrite-2026-09-17.bundle`; no issue/PR comments without the operator's ok. Commits and pushes to `main` are authorized after the preflight.

## Standard procedures (referenced by every deliverable)

Every command assumes two variables, exported once per shell: `REPO`, the repository root, and
`SCRATCH`, a scratch directory outside the repository (logs, gold copies, the commit message). The
plan names no account-specific path: the repository is public.

### P1 — Full suite with a test count

```bash
cd "$REPO"
: "${SCRATCH:?export SCRATCH as a scratch directory outside the repository}"
swift build -Xswiftc -warnings-as-errors 2>&1 | tail -5
swift test >"$SCRATCH/suite.log" 2>&1; echo "exit=$?"
grep -E 'Executed [0-9]+ tests?' "$SCRATCH/suite.log" | tail -1
grep -oE "Test Case '-\[[^]]*\]' failed" "$SCRATCH/suite.log" | sort -u
```

Expected: `exit=0`, the last `Executed N tests, with 0 failures` line, and no failed test case. Report N in the deliverable summary.

### P2 — Mutation harness (scratchpad, not committed)

Stage everything first (`git add -A`), so any edit the harness leaks shows up in `git diff`. Write this once to `$SCRATCH/mutate.sh`:

```bash
#!/bin/bash
# mutate.sh <file> <XCTest class> <anchor> <replacement>
# One literal replacement, proven applied; measured with build and test split (MUTATION-TESTING-NOTES.md);
# restored byte for byte; the whole tree proven identical to the staged state; the class re-run green.
set -u -o pipefail
file="$1"; cls="$2"; from="$3"; to="$4"
: "${REPO:?export REPO as the repository root}"
cd "$REPO"
: "${SCRATCH:?export SCRATCH as a scratch directory outside the repository}"
git diff --quiet || { echo "ABORT: unstaged changes before the mutant — git add -A first"; exit 2; }
gold="$SCRATCH/gold-$(basename "$file")"
cp -p "$file" "$gold"
python3 - "$file" "$from" "$to" <<'PY' || { echo "MUTANT NOT APPLIED"; exit 3; }
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
n = src.count(frm)
if n != 1:
    print(f"anchor must occur exactly once, found {n}")
    sys.exit(1)
open(path, "w", encoding="utf-8").write(src.replace(frm, to))
PY
cmp -s "$file" "$gold" && { echo "MUTANT NOT APPLIED (file unchanged)"; exit 3; }
grep -qF -- "$to" "$file" || { echo "MUTANT NOT APPLIED (replacement absent)"; exit 3; }
echo "APPLIED: $(git diff --stat -- "$file" | tail -1)"
log="$SCRATCH/mutant-$cls-$(date +%s)"
if swift build --build-tests >"$log.build" 2>&1; then
    swift test --skip-build --filter "$cls" >"$log.run" 2>&1
    echo "mutant:   $(grep -E 'Executed [0-9]+ tests?' "$log.run" | tail -1)"
    echo "distinct failed test cases: $(grep -oE "Test Case '-\[[^]]*\]' failed" "$log.run" | sort -u | wc -l | tr -d ' ')"
    grep -oE "Test Case '-\[[^]]*\]' failed" "$log.run" | sort -u
    grep -q 'Fatal error\|SWIFT TASK CONTINUATION MISUSE' "$log.run" && echo "the run CRASHED — see $log.run"
else
    echo "COMPILE ERROR — NOT a test kill (see $log.build)"
fi
cp -p "$gold" "$file"
cmp "$gold" "$file" && echo "restored byte for byte"
git diff --quiet && echo "whole tree identical to the staged state" || { echo "TREE DIFFERS AFTER RESTORE"; exit 4; }
swift build --build-tests >"$log.rebuild" 2>&1 || { echo "RESTORED TREE DOES NOT BUILD"; exit 5; }
swift test --skip-build --filter "$cls" >"$log.after" 2>&1
echo "restored: $(grep -E 'Executed [0-9]+ tests?' "$log.after" | tail -1)"
```

A mutant counts as **killed** only when `APPLIED` printed, the build succeeded, and at least one distinct test case failed (or the run crashed at the intended guard, which the log must show). `COMPILE ERROR` is not a kill. `Executed 0 tests` means the filter matched nothing — fix the class name (`--filter` takes class names, not file names) and rerun.

### P3 — Freeze and independent review

Nobody reviews what they wrote. While a reviewer reads, do not edit the files under review.

```bash
cd "$REPO"
git add -A
SNAP=$(git stash create "review: deliverable N")
echo "$SNAP"; git show --stat "$SNAP" | tail -25
```

`git stash create` records only tracked content, which is why everything is staged first; check the `--stat` lists every new file. Dispatch the reviewer(s) named by the deliverable with this prompt (fill the brackets):

> You are reviewing frozen snapshot `[SNAP]` of XCodeVault, taken over `HEAD` `[HEAD SHA]`. Read it only through git: `git diff [HEAD] [SNAP]`, `git show [SNAP]:<path>`. Do not read the working tree — it may change after you start. Scope: `[files]`. Context: `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md`, `docs/adr/0007-permissions-asked-at-need.md`, and the operator decisions at the top of `docs/superpowers/plans/2026-09-27-user-first-permissions.md`. Focus: `[focus list]`. Report every checklist item PASS / FAIL / N-A with file:line, then APPROVE or REQUEST CHANGES with the minimal fix per finding. Say plainly anything you could not determine.

On REQUEST CHANGES: fix, re-stage, create a new snapshot, and re-run the same reviewer on the new SHA. Commit only after every reviewer approves.

### P4 — Commit, preflight, push

```bash
cd "$REPO"
pgrep -lx 'xcodebuild|launchd_sim' || echo "rig idle"
```

If the rig is active, the `redaction` gate's "an ordinary directory passes the target guard" fails while a device is booted — that is the guard working, not a regression. Tell the operator and wait; never stop the rig. Then:

```bash
git commit -F "$SCRATCH/commit-msg.txt"
scripts/preflight.sh
```

Expected: `preflight: ok (11 gates)`. Anything else is not a pass. If a gate fails, re-run it directly to see its output, fix in a **new** commit, and preflight again. Then `git push origin main` (HTTPS). Finish with a short summary to the operator in Portuguese: what changed, tests (N executed, 0 failures) and mutants (applied / killed per mutant), what stayed pending.

---

# Deliverable 1 — User docs, ADR-0007, the SECURITY_MODEL correction

One commit. Docs only; no Swift changes. Everything the docs say about behaviour that later deliverables add is marked **planned** until that deliverable lands and flips it.

> **Executed 2026-09-27.** The independent docs review changed several texts below — undo answers
> (device sets, `vault init`, `externalize`, `migration resume`), experimental labels on every command
> that has one, and claims that were prose rather than measurement (disconnection, the dyld rebuild,
> removable volumes, "`SMAppService` will not register an unsigned daemon"); it also corrected the
> struck claim where it originated, `FINDINGS-2026-09-05.md`. The committed files are authoritative;
> later tasks anchor on them.

### Task 1.1: README becomes user-first

**Files:**
- Modify (full rewrite): `README.md`

**Interfaces:**
- Produces: the permissions table cells "In this build" that deliverables 2–4 replace verbatim. The two cells, exactly:
  - FDA: `Planned (see \`STATUS.md\`)`
  - Helper: `Not available: it needs a signed build (issue #30). The vault folder is created with the command \`vault init\` prints; the dyld cache is listed, never cleaned`

- [ ] **Step 1: Replace `README.md` with this text**

````markdown
# XCodeVault

XCodeVault shows what Xcode, the Simulator and their tools keep on your Mac's internal disk, and
frees the part that can be freed safely — while Xcode, the Simulator, `xcodebuild`, `simctl` and
`devicectl` keep working. It is not finished: read [the honest state](#the-honest-state) before
trusting it with anything you cannot re-create.

## What it does

- **Accounts** for developer storage per category (simulator runtimes, CoreSimulator data,
  DerivedData, device support, caches, archives) and says which part is cleanable, relocatable
  with Apple's own mechanisms, or neither.
- **Cleans** the regenerable data you select, showing the plan first and journaling every change.
- **Relocates** only through Apple-supported mechanisms, or by a verified copy to an external
  drive you register.
- **Diagnoses** unsafe setups, such as data written to an external drive's path while the drive was
  unplugged, and proposes the fix. It never applies a fix on its own.

## Install

- **Today — build from source** (macOS 14 or later, a recent Xcode):

  ```bash
  git clone https://github.com/pabloguia/XCodeVault.git
  cd XCodeVault
  swift build
  ```

  `scripts/bundle-app.sh` assembles `dist/XCodeVault.app`. Builds made this way are unsigned.
- **Planned — not available yet:** a signed, notarized DMG and a Homebrew cask.

## First run

Nothing is asked for. The first run scans and shows; it changes nothing.

```bash
.build/debug/xcodevaultctl scan      # what is using the internal disk, per category
.build/debug/xcodevaultctl doctor    # unsafe or broken setups, and the proposed fix for each
.build/debug/xcodevaultctl clean     # the cleanup plan; nothing is deleted without --apply
```

## Permissions

XCodeVault asks for a permission only when an action needs it, and says why.

| Permission | Asked for when | Why | How it is asked | In this build |
|---|---|---|---|---|
| Full Disk Access | A scan could not read folders because macOS privacy protection refused it | Those folders' sizes are missing from the totals | The app opens the exact System Settings pane; you switch it on; the app notices and scans again. Code cannot grant it, so the app never tries | Planned (see `STATUS.md`) |
| Privileged helper — a background item that runs as root, approved once by an administrator | You choose an action that needs root: creating the vault folder on a drive whose top folder belongs to root, or emptying the CoreSimulator dyld cache | Those paths belong to root; the helper can do only a fixed list of actions on paths it resolves itself | A one-sentence sheet with **Allow**; then macOS asks you to approve the helper in Login Items & Extensions | Not available: it needs a signed build (issue #30). The vault folder is created with the command `vault init` prints; the dyld cache is listed, never cleaned |

XCodeVault never asks for your password itself, never runs `sudo`, and never opens a root shell.
Details, and the rest of the product, are in the [user guide](docs/USER_GUIDE.md).

## What it never does

- Disable SIP, ask you to, or modify `/System`.
- Run a root shell. Root work goes only through the helper's fixed list of actions.
- Delete Archives, or anything else that cannot be regenerated, unless you choose that item.
- Delete a source before its copy has been verified.
- Symlink `~/Library/Developer`, its `CoreSimulator`, or its `DeveloperDiskImages`.

## The honest state

| Area | State |
|---|---|
| Accounting (`scan`, `status`, `report`, `doctor`, `volumes`, `journal`, `compatibility`) | Working. Read-only; `--json` on every read command. |
| Cleanup and Apple-supported relocation (`clean`, `locations`, `runtime`) | Working, journaled, gated. These change your machine, and every strategy stays labelled **experimental** until it meets the Definition of Done. |
| Vault / external migration (`vault`, `externalize`, `restore`, `migration`) | **Experimental.** Verified copy; the source is removed only when you opt in. |
| GUI | First slice: read-only views plus the clean flow. |
| Privileged helper | Built and security-reviewed; not reachable from any client. It needs a signed build and has never run live (issue #30). |
| Releases | None. Nothing is signed or notarized. |
| CI | Every push, on `macos-15` and `macos-26`. |

Every compatibility claim was measured on a single Mac — one architecture, two macOS builds of the
same major version, one Xcode. What was not measured is marked pending in
[`docs/architecture/COMPATIBILITY_MATRIX.md`](docs/architecture/COMPATIBILITY_MATRIX.md).

## For contributors

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the contribution this project is short of is an experiment
  run on a Mac that is not the author's. Read [`SECURITY.md`](SECURITY.md) before reporting
  anything about the root helper.
- [`CLAUDE.md`](CLAUDE.md) and [`docs/product/NON_GOALS_AND_SAFETY.md`](docs/product/NON_GOALS_AND_SAFETY.md) — the safety rules in full.
- [`docs/research/`](docs/research/), [`docs/architecture/HYPOTHESES.md`](docs/architecture/HYPOTHESES.md),
  [`docs/architecture/EXPERIMENTS.md`](docs/architecture/EXPERIMENTS.md) — findings, open questions, experiments.
- [`docs/adr/`](docs/adr/) — decisions, including the ones that reversed earlier decisions.
- [`STATUS.md`](STATUS.md) — what is in flight and what is next.

## License

[MIT](LICENSE). `xcodevaultctl` statically links
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0 with the Runtime
Library Exception) and ships inside the app bundle and the Homebrew cask;
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) carries its licence text and the reasoning, and is
copied into `XCodeVault.app/Contents/Resources/`.
````

- [ ] **Step 2: Check every link resolves**

```bash
cd "$REPO"
python3 - <<'PY'
import re, os
text = open("README.md").read()
for target in re.findall(r"\]\(([^)#]+)\)", text):
    if target.startswith("http"): continue
    print(("ok      " if os.path.exists(target) else "MISSING ") + target)
PY
```

Expected: every line `ok` except `docs/USER_GUIDE.md`, which Task 1.2 creates.

### Task 1.2: `docs/USER_GUIDE.md`

**Files:**
- Create: `docs/USER_GUIDE.md`

**Interfaces:**
- Produces: the same two "In this build" cells as Task 1.1 (identical text, replaced by deliverables 2–4), the sentence `A **Permissions** section with these two rows is planned (see \`STATUS.md\`).` (replaced by deliverable 3), and the FAQ bullet beginning `- **A row says it needs root**` (replaced by deliverable 4).

- [ ] **Step 1: Create `docs/USER_GUIDE.md` with this text**

````markdown
# XCodeVault user guide

What each part of XCodeVault shows or changes on your Mac, and how to undo what it changes. What
the project is, and how far along it is, is in the [README](../README.md).

Commands are written `xcodevaultctl …`; from a source build that is `.build/debug/xcodevaultctl …`.
Every read command accepts `--json`.

## Permissions: which, when, why, and how the app asks

XCodeVault asks for a permission only at the moment an action needs it. The first run asks for
nothing: it scans, shows, and changes nothing. XCodeVault never asks for your password itself,
never runs `sudo`, and never opens a root shell ([ADR-0007](adr/0007-permissions-asked-at-need.md)).
Where macOS allows it, asking means one system prompt, not a command for you to paste.

| Permission | Asked for when | Why | How XCodeVault asks | In this build |
|---|---|---|---|---|
| **Full Disk Access** | A scan could not read some folders because macOS privacy protection refused it | Those folders' sizes are missing from the totals until it is granted | It opens System Settings ▸ Privacy & Security ▸ Full Disk Access. You switch it on; when you come back, the app notices and scans again. Code cannot grant this permission, so the app never tries | Planned (see `STATUS.md`) |
| **Privileged helper** — a background item that runs as root | You choose an action that needs root: creating the vault folder on a drive whose top folder belongs to root, or emptying the CoreSimulator dyld cache | Those paths belong to root. The helper can do only a fixed list of actions, on paths it resolves itself | A one-sentence sheet with **Allow**. macOS then asks you to approve the helper once, in System Settings ▸ General ▸ Login Items & Extensions, with an administrator password — macOS's prompt, not XCodeVault's | Not available: it needs a signed build (issue #30). The vault folder is created with the command `vault init` prints; the dyld cache is listed, never cleaned |

Two details that are easy to get wrong:

- **Full Disk Access belongs to the app that runs XCodeVault.** For the app that is
  `XCodeVault.app`. For `xcodevaultctl`, macOS decides by the app you run it from — usually your
  terminal — so that is the one to switch on. A grant to one does not reach the other.
- **Whether the helper itself needs Full Disk Access is unmeasured.** Emptying the dyld cache needed
  root *with* Full Disk Access when it was measured from a terminal (H15). The helper runs as a
  launchd daemon, which is a different context, and it has never run live (issue #30).

Nothing else is requested. macOS itself may ask about removable volumes the first time an app
touches one — a system category with no API to check or request it in advance. That has not been
observed with XCodeVault, because no signed build exists yet.

## The app

The app shows the same numbers and runs the same checks as the command line. Rescan with ⌘R.

| Section | What it shows | What it changes | How to undo |
|---|---|---|---|
| Overview | Internal disk used by developer tooling; how much is cleanable or relocatable; warnings; doctor issues of error severity or worse | Nothing | — |
| Storage | Every storage category with size, outcome, strategy and path; symlinks and mount points flagged | Nothing | — |
| Doctor | Unsafe or broken setups, each with the proposed fix | Nothing: doctor proposes, it never applies a fix | — |
| Clean | The cleanup plan — regenerable data only, largest first. Select rows, then **Delete selected…**; the confirmation shows the exact count | Deletes the selected rows, or moves them to the Trash (the default). Rows that need root are listed, never deleted here; the **Needs** column says what they lack | From the Trash, before you empty it. Otherwise Xcode regenerates the data — see [Why did the space come back?](#why-did-the-space-come-back) |
| Volumes | Mounted volumes, whether each qualifies as a vault, and the state of registered vault volumes | Nothing; registering a vault is `xcodevaultctl vault init` | — |
| Runtimes | Installed simulator runtimes | Nothing | — |
| Journal | The last 100 operations XCodeVault recorded | Nothing | — |

A **Permissions** section with these two rows is planned (see `STATUS.md`).

## The command line

### Read-only commands

These never change anything.

| Command | What it shows |
|---|---|
| `status` | A quick summary, without measuring sizes |
| `scan` | Every storage category, measured |
| `report` | `scan` plus doctor findings, with your home folder, account name, volume names and volume UUIDs redacted — made to paste into an issue |
| `doctor` | Unsafe or broken setups and the proposed fix for each; exits 2 when one is an error or worse |
| `compatibility` | Every category with its strategy, evidence status and privilege level |
| `volumes` | Mounted volumes and whether each qualifies as a vault |
| `xcode list` | Installed Xcodes and what each supports |
| `runtime list`, `runtime library --dir <dir>` | Installed runtimes; the installers in a Runtime Library folder |
| `locations show` | Xcode's DerivedData, Archives and compilation-cache locations |
| `journal` | Every change XCodeVault made, and any interrupted operation |
| `vault status`, `migration status` | Registered vault volumes; interrupted migrations |

`bench <dir>` does not touch your data, but it writes and then removes a temporary 256 MB file in `<dir>`.

### Commands that change your Mac

Each one is recorded in the journal. Those marked *experimental* have not met the Definition of Done
in [`NON_GOALS_AND_SAFETY.md`](product/NON_GOALS_AND_SAFETY.md).

| Command | What it changes | How to undo |
|---|---|---|
| `clean --apply` (`--trash` to move to the Trash instead) | Deletes the planned regenerable paths. Without `--apply` it only prints the plan. Root-owned rows are never deleted by `clean` | With `--trash`: restore from the Trash before emptying it. Without it: none; Xcode regenerates the data |
| `locations set-derived-data <path>`, `set-archives <path>`, `set-compilation-cache <path>` (*experimental*) | Xcode's own Locations setting. No file is moved. DerivedData on an external drive needs `--i-understand-tests-may-fail` (E2) | `locations reset-derived-data`, `reset-archives`, `reset-compilation-cache` |
| `runtime delete <id> --yes` | Deletes an installed simulator runtime through `simctl runtime delete` | Install it again (Xcode ▸ Settings ▸ Components), or `runtime import` an installer you exported |
| `runtime export <platform> --to <dir>` | Downloads a runtime installer into `<dir>` | Delete the file |
| `runtime import <dmg>` | Installs a runtime from an installer | `runtime delete` |
| `runtime offload <id> --library <dir> --yes` (*experimental*) | Deletes an installed runtime, only if its installer is already in the Runtime Library | `runtime import <installer>`. Devices came back after re-import in the two round trips measured, on one configuration |
| `vault init <mount>` (*experimental*) | Creates `<mount>/XCodeVault` and a sentinel file, and records the volume | `vault forget <uuid>`, then delete the folder |
| `vault forget <uuid>` | Removes the volume from XCodeVault's registry; nothing on the volume is touched | `vault init` again |
| `externalize --category archives --vault <ref> --apply` (*experimental*) | Copies Archives to the vault and verifies the copy. The originals stay unless you also pass `--remove-source-after-verify --i-confirm-deleting-non-regenerable-data` | `restore` |
| `restore --category archives --vault <ref> --name <entry> --apply` (*experimental*) | Copies a vault entry back; never overwrites | Delete the restored copy |
| `migration abort <id>` | Removes the partial vault copy of a migration interrupted before verification; the source is never touched | — |
| `migration resume <id>` | Finishes a cleanup interrupted after verification: re-verifies, then removes the original — or restores it if the two differ | — |
| `migration forget <id> --i-verified-both-copies-myself` | Clears the journal entry only, after you compared both copies yourself; no file is touched | — |

## FAQ

### My external drive was disconnected. What now?

The disconnection itself loses nothing. XCodeVault identifies a vault drive by its UUID and a
sentinel file, never by its name, and refuses to act on a vault that is not connected. `doctor`
reports what the disconnection left behind:

- **Vault volume … is not connected** — connect it before using `externalize` or `restore`.
- **A plain directory under `/Volumes`** — something wrote into `/Volumes/<name>` while the drive
  was away. macOS will mount the drive as `<name> 1` next time, and paths into `/Volumes/<name>`
  will point at the local copy. Reconcile it before reconnecting; XCodeVault never resolves this by
  deleting a copy.
- **Xcode's DerivedData or Archives location does not exist** — reconnect the drive, or
  `locations reset-derived-data` / `reset-archives` to return to the default.
- **Interrupted migration** — `doctor` names the command: `migration abort` before verification,
  `migration resume` after it.

### Why did the space come back?

Because the data is regenerable, which is why it was offered for cleaning:

- DerivedData is rebuilt on the next build; the first build of each project is a full build.
- Device Support is copied again the next time a device with that OS build connects.
- Moving to the Trash frees space only when the Trash is emptied.
- CoreSimulator dyld caches: on the one machine measured, the caches for installed runtimes were
  rebuilt within an hour after a macOS update (H11). What rebuilds a cache a user deleted is not
  identified yet (H14).

### Why is this greyed out, or why is there no button?

- **Delete selected… is disabled**: no row that `clean` may delete is selected. Rows that need root
  do not count; the **Needs** column says what they lack.
- **A row says it needs root**: XCodeVault's only route to root is its privileged helper, and this
  build cannot reach it (see [Permissions](#permissions-which-when-why-and-how-the-app-asks)).
- **Rescan is disabled**: a scan is already running.
- **Everything is labelled experimental**: no strategy has met the Definition of Done yet, and the
  label stays until one does.
````

- [ ] **Step 2: Check links**

```bash
cd "$REPO"/docs
python3 - <<'PY'
import re, os
text = open("USER_GUIDE.md").read()
for target in re.findall(r"\]\(([^)#]+)\)", text):
    if target.startswith("http"): continue
    print(("ok      " if os.path.exists(target) else "MISSING ") + target)
PY
```

Expected: all `ok` except `adr/0007-permissions-asked-at-need.md` (Task 1.4 creates it).

### Task 1.3: `UX_AND_CLI.md` gains the permissions command and the ask-at-need flow

**Files:**
- Modify: `docs/product/UX_AND_CLI.md` (append a section before `## Doctor subsystem`)

- [ ] **Step 1: Insert this section immediately before the line `## Doctor subsystem`**

```markdown
## Permissions — asked at the moment of need (spec 2026-09-27, ADR-0007)

> Status: specification. Each item says which deliverable of
> `docs/superpowers/plans/2026-09-27-user-first-permissions.md` ships it; until then it is planned.

The rule: the first run asks for nothing, and a permission is asked for only when an action needs
it. Wherever macOS allows it, asking means one system prompt; the GUI never hands the user a Terminal
command as the primary route. The client never runs a root shell (`osascript … with administrator
privileges`, `AuthorizationExecuteWithPrivileges`, spawned `sudo`): the helper's allowlisted verbs
are the only privileged path.

- **`xcodevaultctl permissions [--json]`** (read-only, deliverable 2): the Full Disk Access state
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
```

### Task 1.4: ADR-0007

**Files:**
- Create: `docs/adr/0007-permissions-asked-at-need.md`

- [ ] **Step 1: Create the ADR with this text**

```markdown
# ADR 0007: Permissions are asked for at the moment of need; no root shell in the client; Full Disk Access is guided

- Status: accepted (2026-09-27)
- Date: 2026-09-27
- Spec: `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md`
- Related hypothesis: H15. Related issue: #30. Related safety rules: 1, 3, 10. Builds on ADR-0001
  (SMAppService only, no SMJobBless) and ADR-0006 (helper logic in a library target).

## Context

The target is a user who downloads XCodeVault and uses it without worrying about it. The operator
will obtain an Apple Developer ID (M5), so the target build is a notarized app whose root operations
are approved once through `SMAppService`. Two permissions matter in practice, and each has a limit
that no design can remove:

- **Full Disk Access (TCC)** cannot be granted by code or by password. Only the user can switch it on,
  in System Settings. An app can open the exact pane and detect the grant; nothing more.
- **The privileged helper** registers through `SMAppService.daemon`, lands in `.requiresApproval`,
  and is enabled once by the user in System Settings ▸ General ▸ Login Items & Extensions with
  administrator authentication. `SMAppService` will not register an unsigned daemon, so until M5
  no verb has ever run live (#30).

H15 measured that the refusals root met inside `/Library/Developer/CoreSimulator/` (`mkdir`, `rm`,
`mount_apfs`) were the calling terminal's missing Full Disk Access, and that they vanished with the
grant. TCC therefore applies to root processes, which contradicts the desk claim in
`SECURITY_MODEL.md` that a root launchd daemon does not need Full Disk Access (struck on the same
day as this ADR). Whether the daemon has that access is unmeasured.

Two shortcuts would give "one password prompt" today, without a signed build: `osascript -e 'do
shell script … with administrator privileges'` and `AuthorizationExecuteWithPrivileges`. Both run an
arbitrary root shell from the unprivileged client — the attack surface the allowlisted helper exists
to remove (`SECURITY_MODEL.md`; CVE-2025-65842 is the class). The second is also deprecated since
OS X 10.7.

## Decision

1. **Ask at the moment of need.** The first run asks for nothing. Full Disk Access is asked for only
   when a scan reports folders refused with `EPERM`; the helper only when the user chooses an action
   that needs root.
2. **No root shell in the client.** Never `osascript … with administrator privileges`, never
   `AuthorizationExecuteWithPrivileges`, never a `sudo` spawned by the app. The helper's allowlisted
   verbs are the only privileged path. A build that cannot reach the helper says "Not available in
   this build" and shows the manual route as text.
3. **Full Disk Access is guided, not automated**, because it cannot be automated: open the exact
   pane, detect the grant with H15's indicator (can this process open `TCC.db`, reading nothing),
   and continue when the user comes back.

## Consequences

- A first run that needs no trust, and one privileged surface to review.
- Every build made today is unsigned, so no root action can run from the app; the user runs the
  documented command. That is the honest state until M5, not a gap to paper over.
- Not doing: installing the helper at first launch; a password prompt of our own; a root-shell
  fallback for unsigned builds; automating the Full Disk Access switch.
- Availability comes from the build as well as from launchd: no usable team ID, or no daemon in the
  bundle, means "Not available in this build" whatever `SMAppService` reports — so no button that
  cannot work is ever shown (operator decision 2026-09-27).
- "Unmeasured" is the only honest word for the daemon's Full Disk Access until the first live run
  records it (#30).

## Evidence

H15 (`docs/architecture/HYPOTHESES.md`); `docs/architecture/SECURITY_MODEL.md` (Registration; the
struck TCC paragraph); issue #30; `docs/architecture/COMPATIBILITY_MATRIX.md` "Pending — added
2026-09-27".
```

### Task 1.5: Correct `SECURITY_MODEL.md` in place

**Files:**
- Modify: `docs/architecture/SECURITY_MODEL.md:147-150`

- [ ] **Step 1: Replace the four lines beginning `- **A root launchd daemon does not need Full Disk Access**` with**

```markdown
- ~~**A root launchd daemon does not need Full Disk Access** — TCC is a user-level concept.~~
  **Struck 2026-09-27; kept so the reasoning that rested on it can be found.** It was a desk claim
  from the 2026-09-05 research pass, never measured here. H15 measured the opposite for root
  *processes*: inside `/Library/Developer/CoreSimulator/`, `mkdir`, `rm` and `mount_apfs` run as
  root failed with `EPERM` from a terminal without Full Disk Access and succeeded once that terminal
  had it. TCC applies to root. Whether a root **launchd daemon** — a different TCC context from a
  granted terminal — has that access is **unmeasured** until the helper's first live run (#30).
  ADR-0007 records what follows from it.
- ~~The **GUI app**, running as the user, is the part that hits TCC enumerating `~/Library`. Split
  responsibilities accordingly: app does UI and presentation, helper does privileged filesystem
  work and can also serve size accounting if TCC bites.~~ Struck with the claim above, which it
  depended on: the helper cannot be assumed to read what TCC hides from the app. ADR-0007 records
  how the app asks for Full Disk Access instead.
```

### Task 1.6: Record the helper flow as pending

**Files:**
- Modify: `docs/architecture/COMPATIBILITY_MATRIX.md` (insert after the `### Pending — added 2026-09-09` table, before the `---` that precedes `### Re-baseline`)
- Modify: `STATUS.md` (header date, "In flight", append a log entry at the end)
- Modify: `docs/process/SESSION-HANDOFF.md` ("Where the project has got to")

- [ ] **Step 1: Insert into `COMPATIBILITY_MATRIX.md`**

```markdown
### Pending — added 2026-09-27 (user-first permissions, ADR-0007)

| Item | Gates | Status |
|---|---|---|
| Helper registration: `SMAppService.daemon` `register()` → approval in Login Items & Extensions → `.enabled` | #30, M5 | **pending — needs a signed build.** Nothing in this repository can produce one; `register()` has never been called |
| Helper verbs over XPC, end to end (`createVaultDirectory`, `removeRegenerableSystemDirectoryContents`) | #30, H15 | **pending — needs a signed build.** Each side of the boundary is unit-tested on its own; the two have never been connected |
| Whether the root launchd daemon has the Full Disk Access `Caches/dyld` needs | H15 | **unmeasured** — the first live helper run (#30) records it |
```

- [ ] **Step 2: Update `STATUS.md`**

Change the first line after the title from `_Last updated: 2026-09-19.` to `_Last updated: 2026-09-27.` (keep the rest of that paragraph). Add this bullet as the first item under `## In flight`:

```markdown
- **User-first permissions** — spec `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md`,
  plan `docs/superpowers/plans/2026-09-27-user-first-permissions.md`, ADR-0007. Four deliverables,
  one commit each. **1 of 4 done:** user docs (README, `docs/USER_GUIDE.md`, `UX_AND_CLI.md`),
  ADR-0007, and the `SECURITY_MODEL.md` correction (the daemon's Full Disk Access is unmeasured, not
  "not needed"). Next: the Permissions model in Core and `xcodevaultctl permissions`. The helper
  flow is **pending — needs a signed build** (#30); `COMPATIBILITY_MATRIX.md` "Pending — added
  2026-09-27" lists it.
```

Append at the end of the file:

```markdown
## 2026-09-27 — user-first permissions, deliverable 1 of 4: the docs say what exists

The README is now one screen for a user: what it does, install, first run, a permissions table,
five things it never does, and the honest state; research and contributor material moved to a
block of links. `docs/USER_GUIDE.md` covers every GUI section and command with what it changes and
how to undo it. Everything the later deliverables add is written as **planned** here and flipped by
the deliverable that ships it — the docs must not describe a command or a button that does not
exist yet. ADR-0007 records the three decisions (ask at need; no root shell in the client; Full Disk
Access guided because it cannot be automated). `SECURITY_MODEL.md`'s "a root launchd daemon does not
need Full Disk Access" is struck in place, citing H15, with the reasoning kept.

Before this plan was written, three places where the spec did not match the code went to the
operator; the answers are recorded at the top of the plan (vault-folder finding derived from a
journaled `vault init` refusal; "not available in this build" also when the daemon is not bundled;
the dyld cache wired to the helper in deliverable 4).
```

- [ ] **Step 3: Update `docs/process/SESSION-HANDOFF.md`**

Under `## Where the project has got to (2026-09-27)`, after the paragraph that ends `…— issue #30, blocked on a signed build.`, add:

```markdown
**In flight (2026-09-27): user-first permissions**, four deliverables in
`docs/superpowers/plans/2026-09-27-user-first-permissions.md`; `STATUS.md` "In flight" says how many
are done.
```

### Task 1.7: Review, commit, preflight, push

- [ ] **Step 1: Freeze and dispatch an independent docs review (P3)**

Reviewer: `general-purpose` agent (docs only — the helper and migration reviewers have nothing to review here). Scope: `README.md`, `docs/USER_GUIDE.md`, `docs/product/UX_AND_CLI.md`, `docs/adr/0007-permissions-asked-at-need.md`, `docs/architecture/SECURITY_MODEL.md`, `docs/architecture/COMPATIBILITY_MATRIX.md`, `STATUS.md`, `docs/process/SESSION-HANDOFF.md`, `docs/superpowers/plans/2026-09-27-user-first-permissions.md`. Focus:
1. Every factual claim about the product is backed by code or by `HYPOTHESES.md` / `COMPATIBILITY_MATRIX.md`; name any claim that is prose rather than measurement.
2. Nothing unshipped is described as shipped; every such item says planned.
3. Every *experimental* and *unmeasured* the rules require is present.
4. The undo column of `USER_GUIDE.md` matches what each command actually does (read `Sources/xcodevaultctl/`).
5. `README.md` still links every document a contributor needs.

- [ ] **Step 2: Commit message (`$SCRATCH/commit-msg.txt`)**

```text
Docs: user-first README and guide, ADR-0007, daemon Full Disk Access struck to unmeasured

Deliverable 1 of 4 of docs/superpowers/plans/2026-09-27-user-first-permissions.md.

README is one screen for a user: what it does, install (source today; DMG and cask planned), first
run, a permissions table, five things it never does, the honest state. docs/USER_GUIDE.md covers
every GUI section and command: what it changes and how to undo it, plus the FAQ. UX_AND_CLI.md
specifies `xcodevaultctl permissions` and the ask-at-need flow. ADR-0007 records: ask at need; no
root shell in the client; Full Disk Access guided because it cannot be automated.

SECURITY_MODEL.md struck "a root launchd daemon does not need Full Disk Access" in place: H15
measured TCC refusing root in /Library/Developer/CoreSimulator, so the daemon's access is
unmeasured until the first live run (#30). The helper flow is recorded as pending in STATUS.md and
COMPATIBILITY_MATRIX.md.

Reviewed-by: general-purpose (independent docs-claims review)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

- [ ] **Step 3: P4** (commit, `scripts/preflight.sh` — all 11 gates, push, summary)

---

# Deliverable 2 — The Permissions model in Core, and `xcodevaultctl permissions`

One commit. Reviews: **helper-security-reviewer** (HelperClient, Package.swift, bundle-app.sh comment) **and** **migration-safety-reviewer** (the `vault init` journal record, the doctor finding that offers a data-creating action, the executor's refusal).

### Task 2.1: Full Disk Access probe

**Files:**
- Create: `Sources/XCodeVaultCore/Permissions/FullDiskAccess.swift`
- Test: `Tests/XCodeVaultCoreTests/PermissionsTests.swift` (created here; Tasks 2.2 and 2.4 add classes to it)

**Interfaces:**
- Produces: `public enum FullDiskAccessState: String, Sendable, Codable, CaseIterable { case granted, notGranted, unknown }`; `public struct FullDiskAccessProbe` with `public static let indicatorPath: String`, `public static let settingsURL: String`, `public init()`, internal `init(path: String, openReadOnly: @escaping @Sendable (String) -> Int32 = …)`, internal `let path: String`, `public func state() -> FullDiskAccessState`, internal `static func classify(openErrno: Int32) -> FullDiskAccessState`.

- [ ] **Step 1: Write the failing tests — create `Tests/XCodeVaultCoreTests/PermissionsTests.swift`**

```swift
import ServiceManagement
import XCTest

@testable import XCodeVaultCore

/// Spec §2's permissions model: one source of truth for the CLI and the GUI. Each test pins a decision —
/// which state an input maps to — never the wording of a message.
final class FullDiskAccessProbeTests: XCTestCase {
    func testAFileThisProcessCanOpenMeansGranted() {
        let t = TempDir()
        let f = t.file("indicator.db", bytes: 1)
        XCTAssertEqual(FullDiskAccessProbe(path: f).state(), .granted, "the real open(2), on a file this process may read")
    }

    func testEPERMMeansNotGranted() {
        // No unit test can make macOS answer EPERM on demand — TCC is what returns it, and a CI runner
        // may hold the grant — so the refusal is injected at the open.
        XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in EPERM }).state(), .notGranted)
        // Positive control: the same injected shape answering success is not a refusal.
        XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in 0 }).state(), .granted)
    }

    func testOtherFailuresAreUnknownRatherThanNotGranted() {
        // EACCES is permission bits and ENOENT a missing file. Reading either as "not granted" would ask
        // the user for a permission nobody showed to be missing.
        for code in [EACCES, ENOENT, EIO, ENOTDIR] {
            XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in code }).state(), .unknown, "errno \(code)")
        }
        let t = TempDir()
        XCTAssertEqual(FullDiskAccessProbe(path: t.path + "/absent.db").state(), .unknown, "the real open(2) on a missing file")
    }

    func testTheProbeOpensTheSameFileAsTheExperimentHarness() throws {
        XCTAssertEqual(FullDiskAccessProbe().path, "/Library/Application Support/com.apple.TCC/TCC.db")
        // H15's indicator lives in the harness too; the app and the experiments must measure the same thing.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staging = try String(contentsOf: root.appendingPathComponent("scripts/experiments/mount-staging.sh"), encoding: .utf8)
        XCTAssertTrue(staging.contains(FullDiskAccessProbe.indicatorPath))
    }
}
```

- [ ] **Step 2: Implement — create `Sources/XCodeVaultCore/Permissions/FullDiskAccess.swift`**

```swift
import Darwin
import Foundation

/// Whether macOS privacy protection (TCC) lets this process read what Full Disk Access guards.
///
/// Three-valued on purpose. `unknown` is not a polite `notGranted`: it is what the probe says when the
/// indicator failed to open for a reason that is not TCC's refusal, and asking at the moment of need
/// (ADR-0007) must not turn "could not tell" into a prompt for a permission nobody showed missing.
public enum FullDiskAccessState: String, Sendable, Codable, CaseIterable {
    case granted, notGranted, unknown
}

/// The one place the product checks Full Disk Access: can this process open H15's indicator file.
///
/// **An indicator, not a query of TCC.** It is `xcv_stage_tcc_indicator` in
/// `scripts/experiments/mount-staging.sh`: a process Full Disk Access reaches can open `TCC.db`; one it
/// does not reach gets `EPERM`. No API reports the grant, and none requests it.
///
/// **It never reads the file.** `open(2)` then `close(2)`, nothing in between: the database is the
/// user's privacy record.
///
/// **Whose access this measures:** the process that runs it. For `XCodeVault.app` that is the app; for
/// `xcodevaultctl`, macOS decides by the app it runs in — usually the terminal — which is the
/// asymmetry H15 recorded.
public struct FullDiskAccessProbe: Sendable {
    /// H15's indicator. `FullDiskAccessProbeTests` holds it equal to the path the harness opens.
    public static let indicatorPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// The System Settings pane where the user switches Full Disk Access on. Opening it is the most any
    /// app can do: the switch cannot be flipped by code or by password.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    let path: String
    /// Opens `path` read-only and closes it at once: `0` on success, otherwise the open's `errno`.
    let openReadOnly: @Sendable (String) -> Int32

    public init() {
        self.init(path: FullDiskAccessProbe.indicatorPath, openReadOnly: FullDiskAccessProbe.openAndClose)
    }

    /// Internal: tests inject a readable path, or an opener that answers `EPERM`.
    init(path: String, openReadOnly: @escaping @Sendable (String) -> Int32 = FullDiskAccessProbe.openAndClose) {
        self.path = path
        self.openReadOnly = openReadOnly
    }

    public func state() -> FullDiskAccessState { FullDiskAccessProbe.classify(openErrno: openReadOnly(path)) }

    /// `EPERM`, and only `EPERM`, means "not granted": it is TCC's refusal (H15). `EACCES` is permission
    /// bits and `ENOENT` a missing file; neither says anything about Full Disk Access.
    static func classify(openErrno: Int32) -> FullDiskAccessState {
        switch openErrno {
        case 0: return .granted
        case EPERM: return .notGranted
        default: return .unknown
        }
    }

    static func openAndClose(_ path: String) -> Int32 {
        // O_NONBLOCK so an injected path naming a FIFO cannot hang the caller; on a regular file it
        // changes nothing.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        close(fd)
        return 0
    }
}
```

### Task 2.2: Helper state

**Files:**
- Create: `Sources/XCodeVaultCore/Permissions/HelperState.swift`
- Test: `Tests/XCodeVaultCoreTests/PermissionsTests.swift` (append a class)

**Interfaces:**
- Produces: `public enum HelperState: String, Sendable, Codable, CaseIterable { case unavailableInThisBuild, notInstalled, awaitingApproval, enabled }` with `public init(status: SMAppService.Status, teamIDIsUsable: Bool, daemonIsBundled: Bool)`.

- [ ] **Step 1: Append the failing tests to `PermissionsTests.swift`**

```swift
final class HelperStateTests: XCTestCase {
    private let known: [SMAppService.Status] = [.notRegistered, .enabled, .requiresApproval, .notFound]

    func testEveryStatusMapsAsSpecifiedWhenTheBuildCanReachTheHelper() {
        XCTAssertEqual(HelperState(status: .enabled, teamIDIsUsable: true, daemonIsBundled: true), .enabled)
        XCTAssertEqual(HelperState(status: .requiresApproval, teamIDIsUsable: true, daemonIsBundled: true), .awaitingApproval)
        // Both mean "not installed" (HelperClient.serviceStatus() documents why both occur).
        XCTAssertEqual(HelperState(status: .notRegistered, teamIDIsUsable: true, daemonIsBundled: true), .notInstalled)
        XCTAssertEqual(HelperState(status: .notFound, teamIDIsUsable: true, daemonIsBundled: true), .notInstalled)
    }

    func testAnUnusableTeamIDMeansUnavailableWhateverLaunchdSays() {
        for s in known {
            XCTAssertEqual(HelperState(status: s, teamIDIsUsable: false, daemonIsBundled: true), .unavailableInThisBuild, "status \(s.rawValue)")
        }
        // Positive control: the same status with a usable team is not unavailable.
        XCTAssertEqual(HelperState(status: .enabled, teamIDIsUsable: true, daemonIsBundled: true), .enabled)
    }

    func testAMissingDaemonMeansUnavailableWhateverLaunchdSays() {
        // Operator decision 2026-09-27: a signed build without the daemon cannot register anything.
        for s in known {
            XCTAssertEqual(HelperState(status: s, teamIDIsUsable: true, daemonIsBundled: false), .unavailableInThisBuild, "status \(s.rawValue)")
        }
        XCTAssertEqual(HelperState(status: .requiresApproval, teamIDIsUsable: true, daemonIsBundled: true), .awaitingApproval)
    }

    func testAStatusNobodyHasSeenIsNeverEnabled() throws {
        // Measured 2026-09-27 with a scratch binary: `SMAppService.Status(rawValue: 99)` yields a value,
        // and it reaches `@unknown default`.
        let future = try XCTUnwrap(SMAppService.Status(rawValue: 99))
        XCTAssertEqual(HelperState(status: future, teamIDIsUsable: true, daemonIsBundled: true), .notInstalled)
    }
}
```

- [ ] **Step 2: Implement — create `Sources/XCodeVaultCore/Permissions/HelperState.swift`**

```swift
import ServiceManagement

/// Where the privileged helper stands for this build, as the app and the CLI present it (spec §2).
///
/// **An installation hint, never an authentication signal.** It comes from `SMAppService`'s view of a
/// plist relative to this bundle; `HelperClient.serviceStatus()` explains why that says nothing about
/// who holds the Mach name. Every connection is still checked against the helper's code signature in
/// `HelperClient.connect()`, and nothing may skip that because this reads `.enabled`.
public enum HelperState: String, Sendable, Codable, CaseIterable {
    /// This build can never reach the helper: no usable Apple team ID, or the daemon is not in the bundle.
    case unavailableInThisBuild
    case notInstalled
    case awaitingApproval
    case enabled

    /// - Parameters:
    ///   - status: `SMAppService`'s answer for the daemon's plist.
    ///   - teamIDIsUsable: `HelperIdentity.isUsableTeamID` of the team substituted at bundle time.
    ///   - daemonIsBundled: whether the daemon's launchd plist ships inside this bundle.
    public init(status: SMAppService.Status, teamIDIsUsable: Bool, daemonIsBundled: Bool) {
        // The build first: without both, `register()` cannot succeed and no connection can be validated,
        // whatever launchd reports (ADR-0007: a button that cannot work is never shown).
        guard teamIDIsUsable, daemonIsBundled else {
            self = .unavailableInThisBuild
            return
        }
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .awaitingApproval
        // `.notFound` is what an unregistered daemon has been measured to answer from this repository;
        // `.notRegistered` is what a signed install is expected to answer, unverified until M5.
        case .notRegistered, .notFound: self = .notInstalled
        // Never `.enabled` for a status nobody has seen: a root action must not run on it. The install
        // flow re-reads the status and stops with a message if it cannot progress.
        @unknown default: self = .notInstalled
        }
    }
}
```

### Task 2.3: Privilege requirement and privileged action; `CleanAction` migrated

**Files:**
- Create: `Sources/XCodeVaultCore/Permissions/PrivilegeRequirement.swift`
- Modify: `Sources/XCodeVaultCore/Clean/CleanPlanner.swift:21-34` (`privilegeRequirement`) and `:313-314` (`preflight`'s refusal)
- Modify: `Sources/xcodevaultctl/CleanCommand.swift:40-44` (the tag)
- Modify: `Sources/XCodeVault/XCodeVaultApp.swift:242` (the Needs column — compile fix)
- Modify: `Tests/XCodeVaultCoreTests/M2Tests.swift:858-886` (`PrivilegeRequirementTests`)
- Modify: `Tests/XCodeVaultCoreTests/HelperContractTests.swift` (one test)

**Interfaces:**
- Produces: `public enum PrivilegeRequirement: String, Sendable, Codable, CaseIterable { case helper, helperWithFullDiskAccess, appFullDiskAccess }` with `public static let coreSimulatorDyldCachePath: String`, `public static func forRootPath(_:) -> PrivilegeRequirement`, `public var label: String`, `public var why: String`; `public enum PrivilegedAction: Sendable, Codable, Hashable { case createVaultDirectory(volumeUUID: String) }` with `public var requirement: PrivilegeRequirement`, `public var title: String`; `CleanAction.privilegeRequirement` becomes `PrivilegeRequirement?`.

- [ ] **Step 1: Rewrite `PrivilegeRequirementTests` in `M2Tests.swift` (lines 858–886) to pin the enum case**

Replace the doc comment, class header and its first two tests (keep `testExecutorRefusesARootActionWithoutTouchingIt` unchanged) with:

```swift
/// `privilegeRequirement` is the one requirement the CLI tag, the GUI column and the executor's refusal
/// share, and its text now comes from `PrivilegeRequirement` (spec §2). What is pinned is which actions
/// get which requirement, not the wording — except "unmeasured", which the spec pins.
final class PrivilegeRequirementTests: XCTestCase {
    private func action(_ path: String, root: Bool, category: String = "x") -> CleanAction {
        CleanAction(categoryID: category, categoryName: "X", path: path, bytes: 1, isExperimental: true, risk: .low, requiresRoot: root, notes: [])
    }

    func testOnlyRootActionsCarryARequirement() {
        XCTAssertNil(action("/Library/Developer/CoreSimulator/Caches/dyld", root: false).privilegeRequirement)
        XCTAssertEqual(action("/Library/Developer/CommandLineTools", root: true).privilegeRequirement, .helper)
    }

    func testFullDiskAccessIsNamedForTheDyldCacheOnly() {
        for path in ["/Library/Developer/CoreSimulator/Caches/dyld", "/Library/Developer/CoreSimulator/Caches/dyld/25G229"] {
            XCTAssertEqual(action(path, root: true).privilegeRequirement, .helperWithFullDiskAccess, path)
        }
        // H15's `rm` was measured on this one path; a sibling that merely shares the prefix string, or another
        // root path, must not inherit a requirement nobody measured for it. The Inbox is inside the hierarchy
        // but its refusal was never re-tested with the grant (F1).
        for path in [
            "/Library/Developer/CoreSimulatorX/Caches", "/Library/Developer/CommandLineTools",
            "/Library/Developer/CoreSimulator/Caches/dyldX", "/Library/Developer/CoreSimulator/Cryptex/Images/Inbox",
        ] {
            XCTAssertEqual(action(path, root: true).privilegeRequirement, .helper, path)
        }
    }

    func testTheDaemonsFullDiskAccessIsSaidToBeUnmeasured() {
        XCTAssertTrue(PrivilegeRequirement.helperWithFullDiskAccess.label.contains("unmeasured"))
        XCTAssertTrue(PrivilegeRequirement.helperWithFullDiskAccess.why.contains("unmeasured"))
    }

    func testEveryRequirementHasItsOwnText() {
        XCTAssertEqual(Set(PrivilegeRequirement.allCases.map(\.label)).count, PrivilegeRequirement.allCases.count)
        XCTAssertEqual(Set(PrivilegeRequirement.allCases.map(\.why)).count, PrivilegeRequirement.allCases.count)
    }
```

- [ ] **Step 2: Add the contract test to `HelperContractTests.swift`** (inside the class, after `testVaultDirectoryNameIsTheProjectSpelling`)

```swift
    /// Core names the dyld cache path for Full Disk Access (`PrivilegeRequirement`); the helper owns the
    /// path it will actually empty (`HelperCleanupTarget`). Neither module sees the other, so this is the
    /// one place the two can be held equal.
    func testTheDyldCachePathIsTheOneTheHelperEmpties() {
        XCTAssertEqual(PrivilegeRequirement.coreSimulatorDyldCachePath, HelperCleanupTarget.coreSimulatorDyldCache.path)
    }
```

- [ ] **Step 3: Implement — create `Sources/XCodeVaultCore/Permissions/PrivilegeRequirement.swift`**

```swift
/// What a privileged action needs, stated once so the CLI tag, the GUI column, the executor's refusal
/// and the permissions texts cannot drift apart (spec §2; the rule moved here from `CleanAction`, a942c02).
public enum PrivilegeRequirement: String, Sendable, Codable, CaseIterable {
    /// Root, reached only through the privileged helper's allowlisted verbs.
    case helper
    /// Root inside `Caches/dyld`, where root itself was refused without Full Disk Access (H15). Whether the
    /// helper — a launchd daemon, a different TCC context from a granted terminal — has that access is
    /// unmeasured until its first live run (#30).
    case helperWithFullDiskAccess
    /// Full Disk Access for XCodeVault itself: reading what macOS privacy protection hides from it.
    case appFullDiskAccess

    /// The one path H15's Full Disk Access finding was measured on. Mirrors
    /// `HelperCleanupTarget.coreSimulatorDyldCache.path`, which this module cannot see;
    /// `HelperContractTests` holds the two equal.
    public static let coreSimulatorDyldCachePath = "/Library/Developer/CoreSimulator/Caches/dyld"

    /// The requirement of a root-owned path. Full Disk Access is named for the dyld cache and what is
    /// inside it only: a sibling that shares the prefix string, or another root path — the Inbox
    /// included, whose refusal was never re-tested with the grant (F1) — must not inherit a requirement
    /// nobody measured for it.
    public static func forRootPath(_ path: String) -> PrivilegeRequirement {
        let dyld = coreSimulatorDyldCachePath
        return (path == dyld || path.hasPrefix(dyld + "/")) ? .helperWithFullDiskAccess : .helper
    }

    /// The short tag for lists.
    public var label: String {
        switch self {
        case .helper: return "root — privileged helper"
        case .helperWithFullDiskAccess: return "root with Full Disk Access — privileged helper; its Full Disk Access is unmeasured"
        case .appFullDiskAccess: return "Full Disk Access for XCodeVault"
        }
    }

    /// One sentence of why.
    public var why: String {
        switch self {
        case .helper:
            return "This path belongs to root, and XCodeVault's only route to root is its privileged helper's fixed list of actions."
        case .helperWithFullDiskAccess:
            return "This path belongs to root inside a folder where root was refused without Full Disk Access (H15); "
                + "whether the helper has that access is unmeasured until its first live run (#30)."
        case .appFullDiskAccess:
            return "macOS privacy protection stopped XCodeVault from reading some folders, so their sizes are missing from the totals."
        }
    }
}

/// A privileged step the product can offer as a button instead of a command to paste (spec §2). The text
/// remediation always stays beside it as the fallback: this is an addition, never a replacement.
public enum PrivilegedAction: Sendable, Codable, Hashable {
    /// The helper's `createVaultDirectory(volumeUUID:)`: creates `<mount>/XCodeVault` owned by the caller.
    /// The helper resolves the UUID to a mount point itself; no path crosses the wire.
    case createVaultDirectory(volumeUUID: String)

    public var requirement: PrivilegeRequirement {
        switch self {
        case .createVaultDirectory: return .helper
        }
    }

    /// The button's title.
    public var title: String {
        switch self {
        case .createVaultDirectory: return "Create the vault folder"
        }
    }
}
```

- [ ] **Step 4: Migrate `CleanAction.privilegeRequirement` (`CleanPlanner.swift:21-34`)**

Replace the doc comment and property with:

```swift
    /// What a root action still lacks, in one place so the CLI tag, the GUI column and the executor's
    /// refusal cannot drift apart. The rule and its text live in `PrivilegeRequirement` (spec §2), which
    /// scopes Full Disk Access to the path H15 measured; this says only which actions have one.
    public var privilegeRequirement: PrivilegeRequirement? {
        guard requiresRoot else { return nil }
        return PrivilegeRequirement.forRootPath(path)
    }
```

- [ ] **Step 5: The executor's refusal (`CleanPlanner.swift:314`)**

```swift
        if let needs = a.privilegeRequirement {
            throw CleanError("\(a.path) needs \(needs.label). `clean` never runs root actions; see `xcodevaultctl permissions`.")
        }
```

- [ ] **Step 6: The CLI tag points to `permissions` (`CleanCommand.swift`, the `for a in plan.actions` loop)**

```swift
        for a in plan.actions {
            let needs = a.privilegeRequirement.map { "[\($0.label) — see `xcodevaultctl permissions`] " } ?? ""
            print(
                "  \(TextRendererPad.pad(ByteCount.format(a.bytes), 10)) \(TextRendererPad.pad(a.categoryName, 34)) \(needs)\(a.isExperimental ? "(exp.) " : "")\(a.path)"
            )
        }
```

- [ ] **Step 7: The GUI column (`XCodeVaultApp.swift:242`)**

```swift
                    TableColumn("Needs") { Text($0.privilegeRequirement?.label ?? "") }
```

### Task 2.4: The permissions report and its texts; `TextRenderer.permissions`

**Files:**
- Create: `Sources/XCodeVaultCore/Permissions/PermissionsReport.swift`
- Modify: `Sources/XCodeVaultCore/Report/TextRenderer.swift` (add `permissions(_:)`; findings print the action)
- Test: `Tests/XCodeVaultCoreTests/PermissionsTests.swift` (append a class)

**Interfaces:**
- Consumes: `FullDiskAccessState`, `HelperState` (Tasks 2.1, 2.2).
- Produces: `public struct PermissionsReport: Sendable, Codable, Equatable` with nested `FullDiskAccessEntry { state, why, nextStep }` and `HelperEntry { state, why, nextStep }`, `public init(fullDiskAccess: FullDiskAccessState, helper: HelperState)`; extensions `displayName`, `why`, `nextStep` on both state enums; `TextRenderer.permissions(_ r: PermissionsReport) -> String`.

- [ ] **Step 1: Append the failing tests**

```swift
final class PermissionsReportTests: XCTestCase {
    func testTheJSONCarriesEachStateWithWhyAndOneNextStep() throws {
        let json = try JSONOutput.encode(PermissionsReport(fullDiskAccess: .notGranted, helper: .unavailableInThisBuild))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]])
        XCTAssertEqual(object["fullDiskAccess"]?["state"], "notGranted")
        XCTAssertEqual(object["helper"]?["state"], "unavailableInThisBuild")
        for (name, entry) in object {
            XCTAssertFalse(entry["why"]?.isEmpty ?? true, name)
            XCTAssertFalse(entry["nextStep"]?.isEmpty ?? true, name)
        }
    }

    func testNotGrantedPointsAtTheExactSettingsPane() {
        XCTAssertTrue(FullDiskAccessState.notGranted.nextStep.contains(FullDiskAccessProbe.settingsURL))
        // Control: the pane is the next step only where there is something to switch on.
        XCTAssertFalse(FullDiskAccessState.granted.nextStep.contains(FullDiskAccessProbe.settingsURL))
    }

    func testEveryStateHasItsOwnText() {
        XCTAssertEqual(Set(FullDiskAccessState.allCases.map(\.why)).count, FullDiskAccessState.allCases.count)
        XCTAssertEqual(Set(HelperState.allCases.map(\.why)).count, HelperState.allCases.count)
        XCTAssertEqual(Set(HelperState.allCases.map(\.displayName)).count, HelperState.allCases.count)
    }
}
```

- [ ] **Step 2: Implement — create `Sources/XCodeVaultCore/Permissions/PermissionsReport.swift`**

```swift
/// `xcodevaultctl permissions`: each permission's state, one sentence of why, and one next step. The
/// texts live here so the CLI and the GUI say the same thing (spec §2, one source of truth).
public struct PermissionsReport: Sendable, Codable, Equatable {
    public struct FullDiskAccessEntry: Sendable, Codable, Equatable {
        public var state: FullDiskAccessState
        public var why: String
        public var nextStep: String
    }

    public struct HelperEntry: Sendable, Codable, Equatable {
        public var state: HelperState
        public var why: String
        public var nextStep: String
    }

    public var fullDiskAccess: FullDiskAccessEntry
    public var helper: HelperEntry

    public init(fullDiskAccess: FullDiskAccessState, helper: HelperState) {
        self.fullDiskAccess = FullDiskAccessEntry(state: fullDiskAccess, why: fullDiskAccess.why, nextStep: fullDiskAccess.nextStep)
        self.helper = HelperEntry(state: helper, why: helper.why, nextStep: helper.nextStep)
    }
}

extension FullDiskAccessState {
    public var displayName: String {
        switch self {
        case .granted: return "granted"
        case .notGranted: return "not granted"
        case .unknown: return "unknown"
        }
    }

    public var why: String {
        switch self {
        case .granted:
            return "This process can open the one file only Full Disk Access opens (H15's indicator; nothing is read from it)."
        case .notGranted:
            return "macOS refused this process the one file only Full Disk Access opens, so folders macOS protects cannot be measured."
        case .unknown:
            return "The check could not tell: the indicator file failed to open for a reason other than macOS privacy protection."
        }
    }

    public var nextStep: String {
        switch self {
        case .granted:
            return "Nothing to do."
        case .notGranted:
            return "Only if a scan reports folders it could not read: System Settings ▸ Privacy & Security ▸ Full Disk Access, "
                + "switch on the app you run XCodeVault from (XCodeVault.app, or your terminal for xcodevaultctl), then scan again. "
                + FullDiskAccessProbe.settingsURL
        case .unknown:
            return "Nothing to do unless a scan reports folders it could not read; then grant Full Disk Access as for \"not granted\"."
        }
    }
}

extension HelperState {
    public var displayName: String {
        switch self {
        case .unavailableInThisBuild: return "not available in this build"
        case .notInstalled: return "not installed"
        case .awaitingApproval: return "waiting for approval"
        case .enabled: return "enabled"
        }
    }

    public var why: String {
        switch self {
        case .unavailableInThisBuild:
            return "This build cannot reach the privileged helper: it has no usable Apple team ID, or the helper is not in it. "
                + "Only a signed build that includes it can, and none exists yet (issue #30)."
        case .notInstalled:
            return "The helper is not installed. XCodeVault asks for it only when you choose an action that needs root."
        case .awaitingApproval:
            return "The helper is registered, and macOS is waiting for an administrator to approve it."
        case .enabled:
            return "macOS reports the helper as enabled. That is an installation hint: every connection is still checked "
                + "against the helper's code signature."
        }
    }

    public var nextStep: String {
        switch self {
        case .unavailableInThisBuild:
            return "Actions that need root stay manual. Where there is a manual route, `doctor` or `vault init` prints it."
        case .notInstalled:
            return "Nothing to do until you choose an action that needs root."
        case .awaitingApproval:
            return "System Settings ▸ General ▸ Login Items & Extensions: switch XCodeVault on (administrator password)."
        case .enabled:
            return "Nothing to do."
        }
    }
}
```

- [ ] **Step 3: `TextRenderer.swift` — add after `findings(_:)`**

```swift
    public static func permissions(_ r: PermissionsReport) -> String {
        var o = "Full Disk Access: \(r.fullDiskAccess.state.displayName)\n"
        o += "  why:  \(r.fullDiskAccess.why)\n"
        o += "  next: \(r.fullDiskAccess.nextStep)\n"
        o += "Privileged helper: \(r.helper.state.displayName)\n"
        o += "  why:  \(r.helper.why)\n"
        o += "  next: \(r.helper.nextStep)\n"
        return o
    }
```

and inside `findings(_:)`, after the `remediation` line:

```swift
            if let a = f.action { o += "  in the app: \(a.title) — needs the privileged helper; see `xcodevaultctl permissions`\n" }
```

### Task 2.5: The vault-folder finding (operator decision 1)

**Files:**
- Modify: `Sources/XCodeVaultCore/Vault/OwnershipAdvice.swift:46-57` (split out the command)
- Modify: `Sources/XCodeVaultCore/Vault/VaultVolume.swift:163-166` (journal the refusal) and add `VaultDirectoryRefusal` at the end of the file
- Modify: `Sources/XCodeVaultCore/Doctor/Doctor.swift:21-23` (`Finding.action`)
- Modify: `Sources/XCodeVaultCore/Doctor/Doctor+Vault.swift` (new check, wired into `diagnoseVault`)
- Test: Create `Tests/XCodeVaultCoreTests/VaultDirectoryFindingTests.swift`

**Interfaces:**
- Consumes: `PrivilegedAction.createVaultDirectory(volumeUUID:)` (Task 2.3).
- Produces: `Finding.action: PrivilegedAction?` (default `nil`); internal `enum VaultDirectoryRefusal { static let reasonKey, reason, volumeUUIDKey; static func matches(_: JournalEntry) -> Bool; static func isPermissionRefusal(_: Error) -> Bool }`; `Doctor.checkUncreatableVaultDirectories(registry:journal:volumes:) -> [Finding]`; `OwnershipAdvice.createVaultDirectoryCommand(_:) -> String`.

- [ ] **Step 1: Write the failing tests — create `Tests/XCodeVaultCoreTests/VaultDirectoryFindingTests.swift`**

```swift
import XCTest

@testable import XCodeVaultCore

/// Spec §2's first structured action, placed where the operator chose on 2026-09-27: `vault init` journals
/// the permission refusal, and `doctor` turns the latest one per volume into the finding `vault-dir:<uuid>`,
/// the only finding that carries an action. The text remediation stays as the fallback.
final class VaultDirectoryFindingTests: XCTestCase {
    private let uuid = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    private func volume(_ mountPoint: String) -> Volume {
        Volume(
            deviceNode: "/dev/disk99s1", volumeName: "VAULT", volumeUUID: uuid, mountPoint: mountPoint, filesystemPersonality: "APFS",
            filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB", isSolidState: true,
            isWritable: true, ownersEnabled: true, totalBytes: 10, freeBytes: 5, isBootVolume: false)
    }

    /// A mount point this user cannot write into, which is how a root-owned volume root refuses a regular
    /// user's `mkdir`: `EACCES`. Tests run as a regular user; root would write through the mode bits.
    private func unwritableMountPoint(_ t: TempDir) -> String {
        let mnt = t.dir("mnt")
        chmod(mnt, 0o555)
        addTeardownBlock { chmod(mnt, 0o755) }
        return mnt
    }

    private func register(_ reg: VaultRegistry, _ v: Volume, _ journal: Journal, directory: String = VaultVolume.directoryName) throws {
        let id = uuid
        try reg.register(v, relativeDirectory: directory, journal: journal, isMountPoint: { _ in true }, volumeUUID: { _ in id })
    }

    // MARK: - vault init journals the refusal the helper can fix, and only that one

    func testVaultInitJournalsAPermissionRefusalOfTheDefaultFolder() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        XCTAssertThrowsError(try register(reg, volume(unwritableMountPoint(t)), journal)) {
            XCTAssertTrue("\($0)".contains("sudo install -d"), "the text fallback is unchanged: \($0)")
        }
        let refusals = try journal.entries().filter(VaultDirectoryRefusal.matches)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.detail[VaultDirectoryRefusal.volumeUUIDKey], uuid)
    }

    func testACustomDirectoryIsNotJournalledBecauseTheHelperCannotCreateIt() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        let v = volume(unwritableMountPoint(t))
        XCTAssertThrowsError(try register(reg, v, journal, directory: "Custom"))
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 0)
        // Positive control: the same volume and the default folder are journalled.
        XCTAssertThrowsError(try register(reg, v, journal))
        XCTAssertEqual(try journal.entries().filter(VaultDirectoryRefusal.matches).count, 1)
    }

    func testOnlyAPermissionRefusalCountsAsOne() {
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(CocoaError(.fileWriteNoPermission)))
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(VaultDirectoryRefusal.isPermissionRefusal(wrapped))
        // A read-only volume or a full disk is not the helper's to fix, and must not be offered it.
        XCTAssertFalse(VaultDirectoryRefusal.isPermissionRefusal(CocoaError(.fileWriteVolumeReadOnly)))
        XCTAssertFalse(VaultDirectoryRefusal.isPermissionRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    }

    // MARK: - doctor turns it into the finding while it is actionable

    private func journalWithRefusal(_ t: TempDir) throws -> Journal {
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        try journal.record(
            kind: .migration, state: .failed, summary: "vault folder could not be created (permission)",
            detail: [VaultDirectoryRefusal.reasonKey: VaultDirectoryRefusal.reason, VaultDirectoryRefusal.volumeUUIDKey: uuid])
        return journal
    }

    func testARefusalOnAMountedUnregisteredVolumeIsTheFindingWithTheAction() throws {
        let t = TempDir()
        let mnt = t.dir("mnt")
        let findings = Doctor(home: t.path).checkUncreatableVaultDirectories(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), journal: try journalWithRefusal(t), volumes: [volume(mnt)])
        XCTAssertEqual(findings.map(\.id), ["vault-dir:\(uuid)"])
        XCTAssertEqual(findings.first?.action, .createVaultDirectory(volumeUUID: uuid))
        XCTAssertTrue(findings.first?.remediation?.contains("sudo install -d") ?? false, "the text fallback stays beside the action")
    }

    func testTheFindingDisappearsOnceTheFolderExists() throws {
        let t = TempDir()
        let mnt = t.dir("mnt")
        t.dir("mnt/" + VaultVolume.directoryName)
        let findings = Doctor(home: t.path).checkUncreatableVaultDirectories(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), journal: try journalWithRefusal(t), volumes: [volume(mnt)])
        XCTAssertEqual(findings, [], "the helper would not adopt a folder that is already there anyway")
    }

    func testTheFindingDisappearsOnceTheVolumeIsRegistered() throws {
        let t = TempDir()
        let mnt = t.dir("mnt")
        let reg = VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json"))
        try reg.save([
            VaultVolume(
                volumeUUID: uuid, volumeName: "VAULT", lastMountPoint: mnt, registeredAt: Date(), sentinelID: "s",
                relativeDirectory: VaultVolume.directoryName)
        ])
        XCTAssertEqual(Doctor(home: t.path).checkUncreatableVaultDirectories(registry: reg, journal: try journalWithRefusal(t), volumes: [volume(mnt)]), [])
    }

    func testNoFindingWhileTheVolumeIsNotMounted() throws {
        let t = TempDir()
        let findings = Doctor(home: t.path).checkUncreatableVaultDirectories(
            registry: VaultRegistry(url: URL(fileURLWithPath: t.path + "/volumes.json")), journal: try journalWithRefusal(t), volumes: [])
        XCTAssertEqual(findings, [], "the helper resolves the UUID itself and refuses an unmounted volume")
    }

    /// Spec §4: the structured action is present only on the vault-dir finding. A source scan, because
    /// running every doctor rule needs the real machine (`/Volumes`, `defaults`, `simctl`) and a test must
    /// not walk real volumes. Its limit: an action attached from outside `Doctor/` would escape it.
    func testOnlyTheVaultFolderFindingCarriesAnAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/XCodeVaultCore/Doctor")
        var hits: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("action: .") { hits.append("\(name): \(line)") }
        }
        XCTAssertEqual(hits.count, 1, "\(hits)")
        XCTAssertTrue(hits.first?.contains("createVaultDirectory") ?? false, "\(hits)")
    }
}
```

- [ ] **Step 2: `OwnershipAdvice.swift` — split the command out (replace `createVaultDirectory(_:)`)**

```swift
    /// The one-time privileged command alone, for callers that frame it themselves (`doctor`'s
    /// vault-folder finding). `createVaultDirectory(_:)` wraps it for `vault init`'s refusal.
    public static func createVaultDirectoryCommand(_ dir: String) -> String {
        let (user, group) = currentUserAndGroup()
        return "sudo install -d -o \(shellQuoted(user)) -g \(shellQuoted(group)) -m 755 \(shellQuoted(dir))"
    }

    /// The one-time privileged step that creates the vault directory already owned by the user.
    ///
    /// `install -d` rather than `mkdir` + `chown` because it is one idempotent command that also
    /// fixes owner/group/mode on a directory that already exists. It is **not** atomic —
    /// `install(1)` does `mkdir(2)` then `chown(2)`/`chmod(2)`, same as doing it by hand — so this
    /// is a usability choice, not a safety one; do not restate it as closing a race.
    ///
    /// `-o/-g/-m` apply to the final component only, so with a nested `--directory` the intermediate
    /// levels stay `root:wheel`. That is harmless for writes inside the leaf, and deliberate: only
    /// the vault directory is handed over, never the volume root.
    public static func createVaultDirectory(_ dir: String) -> String {
        """
        The volume root is root-owned (that is normal, and it is what enabling ownership buys you).
        Create the vault directory once, as yourself, with:

          \(createVaultDirectoryCommand(dir))

        Then re-run this command. Nothing after this step needs sudo: everything inside the vault
        will be yours. XCodeVault will not run this for you — read it, then run it if you agree.
        """
    }
```

- [ ] **Step 3: `VaultVolume.swift` — journal the refusal (replace the `createDirectory` `do/catch` at lines 163–166)**

```swift
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            // Journalled for `doctor`, which offers the helper's `createVaultDirectory` as a button — but only
            // for the failure that verb can fix: the default folder, refused for lack of permission. The helper
            // can only ever create the default name, so a custom `--directory` stays the user's to create.
            // `try?` for the reason the writability branch below gives: a journal failure must not replace
            // the real error, which is the one the user can act on.
            if rel == VaultVolume.directoryName, VaultDirectoryRefusal.isPermissionRefusal(error) {
                _ = try? journal.record(
                    kind: .migration, state: .failed, summary: "vault folder could not be created (permission): \(dir)", paths: [dir],
                    detail: [VaultDirectoryRefusal.reasonKey: VaultDirectoryRefusal.reason, VaultDirectoryRefusal.volumeUUIDKey: uuid])
            }
            throw VaultError(
                "Cannot create \(dir): \(error.localizedDescription)\n" + OwnershipAdvice.createVaultDirectory(dir))
        }
```

and append to the end of `VaultVolume.swift`:

```swift
/// The journal record `VaultRegistry.register` leaves when it cannot create the default vault folder for
/// lack of permission, which `Doctor.checkUncreatableVaultDirectories` reads back. Writer and reader take
/// the keys from here so they cannot disagree about them.
///
/// A lone `.failed` record, like the writability refusal's: nothing was started, so there is nothing for
/// `interrupted()` to report and no `migration abort` to suggest.
enum VaultDirectoryRefusal {
    static let reasonKey = "reason"
    static let reason = "vaultDirectoryNotCreatable"
    static let volumeUUIDKey = "volumeUUID"

    static func matches(_ e: JournalEntry) -> Bool {
        e.kind == .migration && e.state == .failed && e.detail[reasonKey] == reason
    }

    /// Whether `createDirectory` failed for lack of permission — the one failure the helper's verb can fix.
    /// A read-only volume, a full disk or a name collision is not, and must not be offered it.
    static func isPermissionRefusal(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(EACCES) || e.code == Int(EPERM) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionRefusal(underlying) }
        return false
    }
}
```

- [ ] **Step 4: `Doctor.swift` — `Finding.action` (after `public var evidence: String?`)**

```swift
    /// A privileged step the app can offer as a button (spec §2). `remediation` stays the text fallback and
    /// is always set when this is. Doctor never executes it. `nil` on every finding but `vault-dir:<uuid>`.
    public var action: PrivilegedAction? = nil
```

- [ ] **Step 5: `Doctor+Vault.swift` — wire and add the check**

In `diagnoseVault`, after `f += checkVaultVolumes(registry: registry, volumes: report.volumes)`:

```swift
        f += checkUncreatableVaultDirectories(registry: registry, journal: journal, volumes: report.volumes)
```

and add, after `checkVaultVolumes`:

```swift
    /// The one finding that carries a privileged action (spec §2; operator decision 2026-09-27): a
    /// `vault init` that could not create the default vault folder because the drive's top folder belongs to
    /// root — normal once ownership is enabled (F5). `VaultRegistry.register` journals that refusal; this
    /// turns the latest one per volume into a finding while it is still actionable.
    ///
    /// Actionable means all three: the volume is mounted (the helper resolves it by UUID and refuses
    /// otherwise), it is not registered (a registered vault has its folder), and the folder is still absent
    /// (the helper's verb creates it and will not adopt one someone else owns). An attempt the user abandoned
    /// keeps this `.info` finding while that drive is mounted — stated, rather than hidden by an expiry.
    func checkUncreatableVaultDirectories(registry: VaultRegistry, journal: Journal, volumes: [Volume]) -> [Finding] {
        // An unreadable journal is already reported by the `journal-unreadable:*` findings.
        guard let entries = try? journal.entries() else { return [] }
        // An unreadable registry reads as "nothing registered", which can only add this finding, never hide
        // one; `vault-registry-unreadable` says why.
        let registered = Set(((try? registry.volumes()) ?? []).map { $0.volumeUUID.uppercased() })
        var refused: Set<String> = []
        for e in entries where VaultDirectoryRefusal.matches(e) {
            if let uuid = e.detail[VaultDirectoryRefusal.volumeUUIDKey] { refused.insert(uuid.uppercased()) }
        }
        var out: [Finding] = []
        for uuid in refused.sorted() where !registered.contains(uuid) {
            guard let v = volumes.first(where: { $0.volumeUUID?.uppercased() == uuid }), let mp = v.mountPoint, let volumeUUID = v.volumeUUID
            else { continue }
            let dir = mp + "/" + VaultVolume.directoryName
            var st = stat()
            guard lstat(dir, &st) != 0 else { continue }
            out.append(
                Finding(
                    id: "vault-dir:\(uuid)", severity: .info, title: "The vault folder could not be created on \(v.volumeName)",
                    detail: "`vault init` could not create \(dir): the drive's top folder belongs to root, which is normal once ownership is "
                        + "enabled on an external drive. The privileged helper has a verb that creates this folder and hands it to you; "
                        + "it needs a signed build (see `xcodevaultctl permissions`).",
                    path: dir,
                    remediation: "Create it once, as yourself:\n  \(OwnershipAdvice.createVaultDirectoryCommand(dir))\n"
                        + "then run `xcodevaultctl vault init \(OwnershipAdvice.shellQuoted(mp))` again.",
                    evidence: "journal: `vault init` refused for permission",
                    action: .createVaultDirectory(volumeUUID: volumeUUID)))
        }
        return out
    }
```

### Task 2.6: `HelperClient` build hints; `xcodevaultctl permissions`; cli-smoke

**Files:**
- Modify: `Sources/XCodeVaultHelperClient/HelperClient.swift` (a `bundleURL` seam, `hasUsableTeamID`, `bundlesDaemon`)
- Create: `Sources/xcodevaultctl/PermissionsCommand.swift`
- Modify: `Sources/xcodevaultctl/XCodeVaultCTL.swift:10-24` (discussion, subcommands)
- Modify: `Package.swift` (the CLI depends on `XCodeVaultHelperClient`; the client target's comment)
- Modify: `scripts/bundle-app.sh:32-38` (comment only)
- Modify: `scripts/preflight.sh:38` and `.github/workflows/ci.yml:110-119` (cli-smoke)
- Test: `Tests/XCodeVaultCoreTests/HelperClientTests.swift` (two tests)

**Interfaces:**
- Consumes: `HelperState`, `FullDiskAccessProbe`, `PermissionsReport`, `TextRenderer.permissions` (Tasks 2.1–2.4).
- Produces: `HelperClient.hasUsableTeamID: Bool`, `HelperClient.bundlesDaemon: Bool`, internal `HelperClient.bundleURL: URL` and `init(team:makeConnection:bundleURL:)` with `bundleURL` defaulting to `Bundle.main.bundleURL`.

- [ ] **Step 1: Append the failing tests to `HelperClientTests`** (inside the class, before its closing brace)

```swift
    // MARK: - Build hints for the permissions model (spec §2)

    func testTheTeamIDHintFollowsTheSameRuleAsConnect() {
        XCTAssertFalse(HelperClient().hasUsableTeamID, "the placeholder build must not look usable")
        XCTAssertTrue(HelperClient(team: goodTeam, makeConnection: { _ in NSXPCConnection() }).hasUsableTeamID)  // positive control
    }

    func testTheDaemonCountsAsBundledOnlyWhenItsPlistIsWhereSMAppServiceLooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcv-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = HelperClient(team: goodTeam, makeConnection: { _ in NSXPCConnection() }, bundleURL: root)
        XCTAssertFalse(client.bundlesDaemon, "no plist, no daemon")
        let dir = root.appendingPathComponent("Contents/Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(HelperIdentity.plistName).path, contents: Data())
        XCTAssertTrue(client.bundlesDaemon, "the plist in Contents/Library/LaunchDaemons")
    }
```

- [ ] **Step 2: `HelperClient.swift` — the seam and the two hints**

Add after `let makeConnection: …`:

```swift
    /// This build's bundle, where `SMAppService.daemon` looks for the plist. `Bundle.main.bundleURL` in
    /// production; a temporary directory in tests.
    let bundleURL: URL
```

Set it in both initialisers (the public one: `self.bundleURL = Bundle.main.bundleURL`), with the internal one becoming:

```swift
    init(team: String, makeConnection: @escaping @Sendable (String) -> NSXPCConnection, bundleURL: URL = Bundle.main.bundleURL) {
        self.team = team
        self.makeConnection = makeConnection
        self.bundleURL = bundleURL
    }
```

Add after `serviceStatus()`:

```swift
    /// Whether this build carries a team ID the peer requirement can be built from. An availability hint for
    /// the UI (spec §2); `connect()` enforces the same condition itself and does not rely on this.
    public var hasUsableTeamID: Bool { HelperIdentity.isUsableTeamID(team) }

    /// Whether the daemon's launchd plist ships in this bundle, where `SMAppService.daemon` looks for it.
    /// `scripts/bundle-app.sh` puts it there only with `--with-helper`, and a signed build without it cannot
    /// register anything — so the UI must not offer to (ADR-0007; operator decision 2026-09-27). A hint, like
    /// `serviceStatus()`: it says nothing about who holds the Mach name.
    public var bundlesDaemon: Bool {
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperIdentity.plistName)").path)
    }
```

- [ ] **Step 3: Create `Sources/xcodevaultctl/PermissionsCommand.swift`**

```swift
import ArgumentParser
import Foundation
import XCodeVaultCore
import XCodeVaultHelperClient

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Read-only. Full Disk Access and the privileged helper: the state of each, why, and the one next step.",
        discussion: """
            Nothing here asks for a permission or changes one: XCodeVault asks only when an action needs it (ADR-0007). \
            Full Disk Access is checked for this process, which macOS decides by the app you run xcodevaultctl from — \
            usually your terminal.
            """)
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let client = HelperClient()
        let report = PermissionsReport(
            fullDiskAccess: FullDiskAccessProbe().state(),
            helper: HelperState(status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, daemonIsBundled: client.bundlesDaemon))
        try emit(report, json: global.json) { TextRenderer.permissions(report) }
    }
}
```

- [ ] **Step 4: `XCodeVaultCTL.swift`** — in the discussion, change `(scan, status, report, doctor, xcode, runtime list, volumes, journal, compatibility)` to `(scan, status, report, doctor, xcode, runtime list, volumes, journal, compatibility, permissions)`; in `subcommands`, change `Volumes.self, Compatibility.self,` to `Volumes.self, Compatibility.self, PermissionsCommand.self,`.

- [ ] **Step 5: `Package.swift`** — the CLI target's dependencies become:

```swift
            dependencies: [
                "XCodeVaultCore",
                "XCodeVaultHelperClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
```

and replace the client target's comment paragraph beginning `// Nothing in \`Sources/\` depends on it yet (issue #30).` with:

```swift
        // The CLI depends on it for read-only state only (`xcodevaultctl permissions`: launchd's status,
        // whether the team ID is usable, whether the daemon is bundled). Nothing in the CLI calls
        // `connect()`. Wiring it to the app is deliverables 3 and 4 of the 2026-09-27 permissions plan;
        // a live connection stays gated on a signed bundle (issue #30).
```

- [ ] **Step 6: `scripts/bundle-app.sh:32-38`** — replace the comment block above `CLIENT_SRC=` with:

```bash
# The client needs the same substitution as the daemon (issue #30). The CLI links it since the
# 2026-09-27 permissions work (`xcodevaultctl permissions` reports whether the team ID is usable), so
# in a signed build this substitution is what makes that report true. Nothing yet opens a connection to
# the helper from a shipped binary. What it prevents is the shape the protocol called "a requirement
# written down, not a property held": a client whose team ID is still the placeholder refuses every
# connection, which is fail-closed but inert — the daemon installed and nothing able to talk to it.
# `HelperClientTests` asserts this script still names the file and still asserts its own sed.
```

- [ ] **Step 7: cli-smoke in both places**

`scripts/preflight.sh:38` becomes:

```bash
    "cli-smoke:.build/debug/xcodevaultctl status && .build/debug/xcodevaultctl xcode list && .build/debug/xcodevaultctl compatibility && .build/debug/xcodevaultctl permissions --json && .build/debug/xcodevaultctl report --json"
```

`.github/workflows/ci.yml`, in `Smoke test the CLI (read-only)`, after `.build/debug/xcodevaultctl compatibility`:

```yaml
          .build/debug/xcodevaultctl permissions --json
```

### Task 2.7: Build cycle — red, then green, then the full suite

The machine is slow, so Tasks 2.1–2.6 are written as one batch and built together.

- [ ] **Step 1: Red — write only the test files of Tasks 2.1–2.6 (Step 1 of each), then**

```bash
cd "$REPO" && swift build --build-tests 2>&1 | grep -E 'error:' | sed -E 's/.*error: //' | sort -u | head -20
```

Expected: errors naming the missing symbols (`FullDiskAccessProbe`, `HelperState`, `PrivilegeRequirement`, `PermissionsReport`, `VaultDirectoryRefusal`, `checkUncreatableVaultDirectories`, `hasUsableTeamID`, `bundlesDaemon`, `bundleURL`) and the enum-vs-String mismatches in `PrivilegeRequirementTests`.

- [ ] **Step 2: Green — apply every implementation step, then run the new and changed classes**

```bash
cd "$REPO"
swift build --build-tests 2>&1 | grep -E 'error:|warning:' | head -20
swift test --skip-build --filter 'FullDiskAccessProbeTests|HelperStateTests|PermissionsReportTests|PrivilegeRequirementTests|VaultDirectoryFindingTests|HelperClientTests|HelperContractTests' 2>&1 | grep -E "Executed [0-9]+ tests|' failed" | tail -15
```

Expected: no errors or warnings; the last `Executed N tests, with 0 failures`.

- [ ] **Step 3: Measure the CLI live, in this agent's process**

```bash
cd "$REPO" && .build/debug/xcodevaultctl permissions && .build/debug/xcodevaultctl permissions --json
```

Expected on this machine (H15: this process has no Full Disk Access): `Full Disk Access: not granted`, `Privileged helper: not available in this build`, and valid JSON with `"state" : "notGranted"` and `"state" : "unavailableInThisBuild"`. Record the output for the summary; do not claim the operator's terminal reads the same.

- [ ] **Step 4: Full suite (P1)** — expected `exit=0`, 0 failures; note N.
- [ ] **Step 5: Format check**

```bash
cd "$REPO" && "$(xcrun --find swift-format)" lint --recursive --strict --configuration .swift-format Sources Tests && echo "format ok"
```

If it reports findings in files this deliverable touched, run `"$(xcrun --find swift-format)" format --in-place --configuration .swift-format <those files>`, review the resulting diff (layout only), then lint again. Never reformat files the deliverable did not touch.

### Task 2.8: Mutants (P2)

Run `git add -A` first. Each row: file, class, anchor → replacement. All five must print `APPLIED` and kill.

- [ ] **M2-1 (spec): EPERM means notGranted**
  `Sources/XCodeVaultCore/Permissions/FullDiskAccess.swift`, `FullDiskAccessProbeTests`, `case EPERM: return .notGranted` → `case EACCES: return .notGranted`
- [ ] **M2-2 (spec): an unusable team ID means unavailable**
  `Sources/XCodeVaultCore/Permissions/HelperState.swift`, `HelperStateTests`, `guard teamIDIsUsable, daemonIsBundled else {` → `guard daemonIsBundled else {`
- [ ] **M2-3: the finding goes away once the folder exists**
  `Sources/XCodeVaultCore/Doctor/Doctor+Vault.swift`, `VaultDirectoryFindingTests`, `guard lstat(dir, &st) != 0 else { continue }` → `guard lstat(dir, &st) != 0 || true else { continue }`
- [ ] **M2-4: only the default folder is journalled**
  `Sources/XCodeVaultCore/Vault/VaultVolume.swift`, `VaultDirectoryFindingTests`, `if rel == VaultVolume.directoryName, VaultDirectoryRefusal.isPermissionRefusal(error) {` → `if VaultDirectoryRefusal.isPermissionRefusal(error) {`
- [ ] **M2-5: Full Disk Access stays scoped to the dyld cache**
  `Sources/XCodeVaultCore/Permissions/PrivilegeRequirement.swift`, `PrivilegeRequirementTests`, `return (path == dyld || path.hasPrefix(dyld + "/")) ? .helperWithFullDiskAccess : .helper` → `return .helperWithFullDiskAccess`

Invocation form (repeat per row):

```bash
bash "$SCRATCH/mutate.sh" Sources/XCodeVaultCore/Permissions/FullDiskAccess.swift FullDiskAccessProbeTests 'case EPERM: return .notGranted' 'case EACCES: return .notGranted'
```

Record for each: APPLIED, `Executed N tests, with M failures`, the distinct failed cases, restored byte for byte, tree identical, restored run 0 failures.

### Task 2.9: Docs, STATUS, reviews, commit, preflight, push

**Files:**
- Modify: `README.md`, `docs/USER_GUIDE.md`, `docs/product/UX_AND_CLI.md`, `STATUS.md`

- [ ] **Step 1: README and USER_GUIDE — the two "In this build" cells (both files, identical edit)**

FDA cell: `Planned (see \`STATUS.md\`)` → `` `xcodevaultctl permissions` reports it; the app's prompt is planned ``

Helper cell: `` Not available: it needs a signed build (issue #30). The vault folder is created with the command `vault init` prints; the dyld cache is listed, never cleaned `` → `` Not available: it needs a signed build (issue #30). `vault init`, and then `doctor`, print the command for the vault folder; the dyld cache is listed, never cleaned ``

- [ ] **Step 2: USER_GUIDE — the read-only table gains a row (after `compatibility`)**

```markdown
| `permissions` | The Full Disk Access state and the helper state, each with why and one next step. Changes nothing |
```

- [ ] **Step 3: UX_AND_CLI.md** — in "Command surface as implemented", change the read-only list's `` `journal`, `vault status`, `migration status`, `bench <dir>`. `` to `` `journal`, `vault status`, `migration status`, `permissions`, `bench <dir>`. ``, and in the Permissions section change `(read-only, deliverable 2)` to `(read-only; shipped 2026-09-27)`.

- [ ] **Step 4: STATUS.md** — in the "User-first permissions" bullet, replace `**1 of 4 done:**` with `**2 of 4 done:**` and change `Next: the Permissions model in Core and \`xcodevaultctl permissions\`.` to `Deliverable 2: the Permissions model in Core, \`xcodevaultctl permissions\` (in cli-smoke), and the \`vault-dir:<uuid>\` finding carrying the structured action. Next: the GUI Permissions section and the Full Disk Access prompt.`; append a log section `## 2026-09-27 — user-first permissions, deliverable 2 of 4: one model, one command` recording: N tests executed / 0 failures; the five mutants with applied/killed; the live `permissions` output from this process (notGranted / unavailableInThisBuild) and that the operator's terminal was not measured; declared gaps — the CLI's `Bundle.main` inside `XCodeVault.app` (does the CLI see the app's registration?) is unmeasured; an abandoned vault-folder attempt keeps an `.info` finding while its drive is mounted.

- [ ] **Step 5: Freeze and review (P3)** — both reviewers, in parallel, on the same SNAP.

helper-security-reviewer — scope: `Sources/XCodeVaultHelperClient/HelperClient.swift`, `Package.swift`, `scripts/bundle-app.sh`, `Sources/xcodevaultctl/PermissionsCommand.swift`, `Sources/XCodeVaultCore/Permissions/HelperState.swift`. Focus: (1) the new accessors are read-only and do not change what `connect()` checks or when; (2) nothing reads `.enabled` or `bundlesDaemon` as a reason to skip `setCodeSigningRequirement`; (3) the CLI linking the client adds no path to `connect()`; (4) `bundleURL` is an internal seam, not public; (5) `helper-invariants.sh` still passes and the single-`NSXPCConnection` rule holds; (6) the bundle-app.sh comment is accurate.

migration-safety-reviewer — scope: `Sources/XCodeVaultCore/Vault/VaultVolume.swift`, `Sources/XCodeVaultCore/Vault/OwnershipAdvice.swift`, `Sources/XCodeVaultCore/Doctor/Doctor.swift`, `Sources/XCodeVaultCore/Doctor/Doctor+Vault.swift`, `Sources/XCodeVaultCore/Clean/CleanPlanner.swift`, `Tests/XCodeVaultCoreTests/VaultDirectoryFindingTests.swift`. Focus: (1) the new journal record can never be read as an interrupted migration (no `migration abort` suggested for it); (2) the finding is offered only while the volume is mounted, unregistered and the folder absent; (3) `vault init`'s ordering guarantees ("guards first", "Nothing was written") are unchanged; (4) the executor still refuses every root action before touching it; (5) volume identity stays UUID-based.

- [ ] **Step 6: Commit message**

```text
Permissions: one model in Core, `xcodevaultctl permissions`, and the vault-folder finding

Deliverable 2 of 4 of docs/superpowers/plans/2026-09-27-user-first-permissions.md.

Core gains the spec's single source of truth: FullDiskAccessProbe (H15's indicator: open TCC.db
read-only, read nothing; EPERM alone is notGranted), HelperState (from SMAppService.Status, the
team-ID rule and — operator decision — whether the daemon is bundled; an unknown status is never
enabled), PrivilegeRequirement (a942c02's rule moved here; CleanAction uses it, the CLI tag points to
`permissions`) and PrivilegedAction. `xcodevaultctl permissions [--json]` reports both states with
one next step each, and joins cli-smoke in preflight and CI.

`vault init` journals a permission refusal of the default vault folder; `doctor` turns the latest one
per volume into `vault-dir:<uuid>`, the only finding carrying an action (createVaultDirectory), with
the `sudo install -d` text kept as the fallback. The helper still cannot run: no build can reach it.

Tests: N executed, 0 failures. Mutants: 5 applied, 5 killed (EPERM, team ID, folder exists, default
folder only, dyld scope).

Reviewed-by: helper-security-reviewer
Reviewed-by: migration-safety-reviewer
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

(Replace N with the measured count before committing.)

- [ ] **Step 7: P4**

---

# Deliverable 3 — GUI Permissions section and the ask-at-need flow (Full Disk Access works today)

One commit. Reviews: **helper-security-reviewer** (the app target now links `XCodeVaultHelperClient` for read-only state) **and** **migration-safety-reviewer** (`DiskUsage` feeds `CleanPlanner` and migration verification).

### Task 3.1: The scan records privacy refusals

**Files:**
- Modify: `Sources/XCodeVaultCore/Support/DiskUsage.swift` (a counter, a predicate, two increments)
- Modify: `Sources/XCodeVaultCore/Scan/ScanReport.swift:45` (`ScanSummary.permissionDeniedCount`)
- Modify: `Sources/XCodeVaultCore/Scan/Scanner.swift:157` (`summarize` adds it up)
- Test: Create `Tests/XCodeVaultCoreTests/PermissionControlsTests.swift`

**Interfaces:**
- Produces: `DiskUsage.permissionDeniedCount: Int` (default 0), internal `static func isPrivacyRefusal(_ code: Int32) -> Bool`; `ScanSummary.permissionDeniedCount: Int` (default 0).

- [ ] **Step 1: Write the failing tests — create `Tests/XCodeVaultCoreTests/PermissionControlsTests.swift`**

```swift
import XCTest

@testable import XCodeVaultCore

/// The scan's half of asking for Full Disk Access at the moment of need (spec §3): it must say when macOS
/// privacy protection — not ordinary permission bits — refused a read.
final class ScanPrivacyRefusalTests: XCTestCase {
    func testOnlyEPERMCountsAsAPrivacyRefusal() {
        XCTAssertTrue(DiskUsage.isPrivacyRefusal(EPERM))
        for code in [EACCES, ENOENT, EIO] { XCTAssertFalse(DiskUsage.isPrivacyRefusal(code), "errno \(code)") }
    }

    func testAnEACCESFolderIsUnreadableButNotAPrivacyRefusal() throws {
        let t = TempDir()
        let locked = t.dir("tree/locked")
        t.file("tree/locked/f", bytes: 10)
        chmod(locked, 0o000)
        addTeardownBlock { chmod(locked, 0o755) }
        let usage = try XCTUnwrap(DiskUsage.measure(t.path + "/tree"))
        // Positive control: the refusal was seen, so the zero below is not the walk missing the folder.
        XCTAssertTrue(usage.unreadable.contains(locked), "\(usage.unreadable)")
        XCTAssertEqual(usage.permissionDeniedCount, 0)
    }

    func testTheSummaryAddsUpPrivacyRefusals() {
        var usage = DiskUsage.zero
        usage.unreadable = ["/x/a", "/x/b"]
        usage.permissionDeniedCount = 2
        let item = StorageItem(
            categoryID: "derivedData", path: "/x", exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false, usage: usage,
            volumeMountPoint: nil, onBootVolume: true)
        let scanner = XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: "/nonexistent", catalog: [StorageCatalog.category("derivedData")!], measureSizes: false,
            detectXcodeCapabilities: false)
        let summary = scanner.summarize(items: [item], runtimes: [])
        XCTAssertEqual(summary.permissionDeniedCount, 2)
        XCTAssertTrue(summary.lowerBound)
    }
}
```

- [ ] **Step 2: `DiskUsage.swift`**

After `public var unreadable: [String]`:

```swift
    /// How many of `unreadable` were refused with `EPERM` — macOS privacy protection's signature (H15) —
    /// as opposed to `EACCES`, which is ordinary permission bits. The app asks for Full Disk Access only
    /// when a scan reports one of these (ADR-0007): it is the one measured reason to ask.
    public var permissionDeniedCount: Int = 0
```

Before `measure(_:)`:

```swift
    /// `EPERM`, and only it, is the privacy refusal. Separate so the rule is testable: no unit test can
    /// make macOS refuse a read with `EPERM` on demand.
    static func isPrivacyRefusal(_ code: Int32) -> Bool { code == EPERM }
```

In the `fts_open` failure branch, before `usage.unreadable.append(path)`:

```swift
            if DiskUsage.isPrivacyRefusal(errno) { usage.permissionDeniedCount += 1 }
```

In `case FTS_DNR, FTS_ERR, FTS_NS:`, before `usage.unreadable.append(entPath)`:

```swift
                if DiskUsage.isPrivacyRefusal(ent.pointee.fts_errno) { usage.permissionDeniedCount += 1 }
```

- [ ] **Step 3: `ScanReport.swift`** — after `public var lowerBound: Bool = false  // some paths unreadable`:

```swift
    /// Unreadable entries refused by macOS privacy protection (`EPERM`), summed across items. Non-zero is
    /// what lets the app ask for Full Disk Access (ADR-0007).
    public var permissionDeniedCount: Int = 0
```

- [ ] **Step 4: `Scanner.swift`** — after `if item.usage?.isLowerBound == true { s.lowerBound = true }`:

```swift
            s.permissionDeniedCount += item.usage?.permissionDeniedCount ?? 0
```

### Task 3.2: The GUI's Full Disk Access decisions, extracted

**Files:**
- Create: `Sources/XCodeVaultCore/Permissions/PermissionControls.swift`
- Test: `Tests/XCodeVaultCoreTests/PermissionControlsTests.swift` (append a class)

**Interfaces:**
- Produces: `public enum PermissionPrompts { public static func shouldAskForFullDiskAccess(permissionDeniedCount: Int, state: FullDiskAccessState) -> Bool }`; `FullDiskAccessState.offersOpenSettings: Bool`.

- [ ] **Step 1: Append the failing tests**

```swift
/// The GUI's decisions, extracted so they can be tested (spec §4): the app target has no tests.
final class FullDiskAccessPromptTests: XCTestCase {
    func testTheFirstRunAsksForNothing() {
        // Nothing refused, not granted: no prompt — asking is for the moment of need only.
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: 0, state: .notGranted))
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: 0, state: .unknown))
    }

    func testARefusedScanAsksUnlessTheGrantIsKnownToBeThere() {
        XCTAssertTrue(PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: 3, state: .notGranted))
        XCTAssertTrue(PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: 3, state: .unknown))
        // Granted and still refused means something other than Full Disk Access; asking for it would mislead.
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: 3, state: .granted))
    }

    func testThePermissionsRowOffersSettingsUnlessGranted() {
        XCTAssertTrue(FullDiskAccessState.notGranted.offersOpenSettings)
        XCTAssertTrue(FullDiskAccessState.unknown.offersOpenSettings)
        XCTAssertFalse(FullDiskAccessState.granted.offersOpenSettings)
    }
}
```

- [ ] **Step 2: Create `Sources/XCodeVaultCore/Permissions/PermissionControls.swift`**

```swift
/// What the GUI shows about permissions, decided here so it is testable (spec §4): the app target has
/// no tests, and a decision nobody can test is the one the next refactor gets wrong.
public enum PermissionPrompts {
    /// Ask for Full Disk Access only at the moment of need (ADR-0007): a scan was refused by macOS privacy
    /// protection, and the grant is not known to be there. The first run, which refuses nothing, asks for
    /// nothing.
    public static func shouldAskForFullDiskAccess(permissionDeniedCount: Int, state: FullDiskAccessState) -> Bool {
        permissionDeniedCount > 0 && state != .granted
    }
}

extension FullDiskAccessState {
    /// Whether the Permissions row offers **Open Settings**: whenever the grant is not known to be there.
    public var offersOpenSettings: Bool { self != .granted }
}
```

### Task 3.3: The GUI

**Files:**
- Modify: `Package.swift` (the `XCodeVault` target depends on `XCodeVaultHelperClient`; the client target's comment)
- Modify: `Sources/XCodeVault/XCodeVaultApp.swift`

**Interfaces:**
- Consumes: `FullDiskAccessProbe`, `HelperState`, `PermissionsReport`, `PermissionPrompts`, `offersOpenSettings`, `ScanSummary.permissionDeniedCount`, `HelperClient.serviceStatus()/hasUsableTeamID/bundlesDaemon`.
- Produces: `AppModel.fullDiskAccess`, `AppModel.helperState`, `AppModel.refreshPermissions()`, `AppModel.openFullDiskAccessSettings()`, `AppModel.appDidBecomeActive()`, `SidebarSection.permissions`, `PermissionsView(model:)` — deliverable 4 extends these.

- [ ] **Step 1: `Package.swift`** — the app target:

```swift
        .executableTarget(
            name: "XCodeVault",
            dependencies: ["XCodeVaultCore", "XCodeVaultHelperClient", "XCodeVaultHelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

and in the client target's comment, change `Wiring it to the app is deliverables 3 and 4 of the 2026-09-27 permissions plan;` to `The app links it for the same read-only state (Permissions section); deliverable 4 of the 2026-09-27 permissions plan adds registration and the verb calls;`.

- [ ] **Step 2: Imports** — the top of `XCodeVaultApp.swift` becomes (`Combine` for `NotificationCenter.publisher(for:)`):

```swift
import AppKit
import Combine
import SwiftUI
import XCodeVaultCore
import XCodeVaultHelperClient
```

- [ ] **Step 3: `AppModel`** — add after `var lastCleanResult: CleanResult?`:

```swift
    var fullDiskAccess: FullDiskAccessState = .unknown
    var helperState: HelperState = .unavailableInThisBuild
    /// Set when the app sends the user to System Settings, so coming back re-checks and rescans once, not on
    /// every activation — a scan measures sizes, it is not free.
    var returningFromSettings = false

    /// Both checks are cheap and read-only: one `open(2)` of H15's indicator, and `SMAppService`'s status.
    func refreshPermissions() {
        fullDiskAccess = FullDiskAccessProbe().state()
        let client = HelperClient()
        helperState = HelperState(status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, daemonIsBundled: client.bundlesDaemon)
    }

    /// The most an app can do for Full Disk Access (ADR-0007): open the exact pane.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: FullDiskAccessProbe.settingsURL) else { return }
        returningFromSettings = true
        NSWorkspace.shared.open(url)
    }

    func appDidBecomeActive() async {
        guard returningFromSettings else { return }
        returningFromSettings = false
        await refresh()
    }
```

and make the first line of `refresh()`'s body `refreshPermissions()` (before `isScanning = true; lastError = nil`).

- [ ] **Step 4: `SidebarSection`** — add the case and its symbol:

```swift
enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview", storage = "Storage", doctor = "Doctor", clean = "Clean", volumes = "Volumes", runtimes = "Runtimes",
        journal = "Journal", permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "internaldrive";
        case .storage: "chart.pie";
        case .doctor: "stethoscope";
        case .clean: "trash"
        case .volumes: "externaldrive";
        case .runtimes: "iphone";
        case .journal: "list.bullet.rectangle"
        case .permissions: "lock.shield"
        }
    }
}
```

- [ ] **Step 5: `MainView`** — the detail `Group` and the reactivation hook:

```swift
            Group {
                if let r = model.report {
                    switch section {
                    case .overview:
                        OverviewView(
                            report: r, findings: model.findings, fullDiskAccess: model.fullDiskAccess,
                            openSettings: { model.openFullDiskAccessSettings() })
                    case .storage: StorageView(report: r)
                    case .doctor: DoctorView(findings: model.findings)
                    case .clean: CleanView(model: model)
                    case .volumes: VolumesView(report: r, checks: model.vaultChecks)
                    case .runtimes: RuntimesView(report: r)
                    case .journal: JournalView(entries: model.journal)
                    case .permissions: PermissionsView(model: model)
                    }
                } else if section == .permissions {
                    PermissionsView(model: model)  // needs no scan
                } else {
                    ContentUnavailableView(
                        "Scanning…", systemImage: "magnifyingglass",
                        description: Text("Discovering Xcodes, runtimes, volumes and measuring storage. Nothing is changed."))
                }
            }
```

and after the `.alert(…)` modifier chain on the `NavigationSplitView`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.appDidBecomeActive() }
        }
```

- [ ] **Step 6: `OverviewView`** — new stored properties and the banner:

```swift
struct OverviewView: View {
    let report: ScanReport; let findings: [Finding]
    let fullDiskAccess: FullDiskAccessState
    let openSettings: @MainActor () -> Void
```

and, inside the `VStack`, immediately after the `Grid { … }`:

```swift
                if PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount: s.permissionDeniedCount, state: fullDiskAccess) {
                    GroupBox {
                        HStack {
                            Label("Some folders could not be read", systemImage: "lock")
                            Spacer()
                            Button("Open Settings", action: openSettings)
                        }
                        Text(PrivilegeRequirement.appFullDiskAccess.why).font(.callout).foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 7: `PermissionsView`** — add at the end of the file:

```swift
/// Spec §3: two rows, each with a status, one sentence of why, and one control. The texts come from
/// `PermissionsReport`, the same the CLI prints; this view decides nothing.
struct PermissionsView: View {
    @Bindable var model: AppModel
    var body: some View {
        let report = PermissionsReport(fullDiskAccess: model.fullDiskAccess, helper: model.helperState)
        Form {
            Section("Full Disk Access") {
                LabeledContent("Status", value: report.fullDiskAccess.state.displayName)
                Text(report.fullDiskAccess.why).font(.callout)
                if model.fullDiskAccess.offersOpenSettings {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                }
            }
            Section("Privileged helper") {
                LabeledContent("Status", value: report.helper.state.displayName)
                Text(report.helper.why).font(.callout)
                Text(report.helper.nextStep).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("XCodeVault asks for a permission only when an action needs it. It never runs a shell or asks for your password.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { model.refreshPermissions() }
    }
}
```

### Task 3.4: Build cycle, full suite, mutants

- [ ] **Step 1: Red** — test file only: `swift build --build-tests 2>&1 | grep 'error:' | head` — expected: missing `isPrivacyRefusal`, `permissionDeniedCount`, `PermissionPrompts`, `offersOpenSettings`.
- [ ] **Step 2: Green** — all implementation steps; `swift build -Xswiftc -warnings-as-errors`; `swift test --skip-build --filter 'ScanPrivacyRefusalTests|FullDiskAccessPromptTests|FilesystemTests'` — expected 0 failures.
- [ ] **Step 3: Full suite (P1)** and the format check (as Task 2.7 Step 5).
- [ ] **Step 4: Mutants (P2)**, after `git add -A`:
  - **M3-1: ask only at need** — `Sources/XCodeVaultCore/Permissions/PermissionControls.swift`, `FullDiskAccessPromptTests`, `permissionDeniedCount > 0 && state != .granted` → `state != .granted`
  - **M3-2: EACCES is not a privacy refusal** — `Sources/XCodeVaultCore/Support/DiskUsage.swift`, `ScanPrivacyRefusalTests`, `static func isPrivacyRefusal(_ code: Int32) -> Bool { code == EPERM }` → `static func isPrivacyRefusal(_ code: Int32) -> Bool { code == EPERM || code == EACCES }`
- [ ] **Step 5: Visual check — ask the operator first.** Launching the app opens a window on their screen. With their ok: `scripts/bundle-app.sh`, open `dist/XCodeVault.app`, and screenshot the Permissions section (computer-use, after `request_access`). Without it, record "GUI compiled and its decisions unit-tested; not exercised on screen" as a declared gap.

### Task 3.5: Docs, STATUS, reviews, commit, preflight, push

- [ ] **Step 1: README and USER_GUIDE, both files — the FDA "In this build" cell** `` `xcodevaultctl permissions` reports it; the app's prompt is planned `` → `Works: the Overview asks when a scan was refused; the Permissions section shows the state`. In README's honest-state table, the GUI row becomes `First slice: read-only views, the clean flow, and a Permissions section.`
- [ ] **Step 2: USER_GUIDE** — replace `A **Permissions** section with these two rows is planned (see \`STATUS.md\`).` with a table row inserted after `Journal`:

```markdown
| Permissions | The Full Disk Access and helper states, each with why and one control: **Open Settings** for Full Disk Access; for the helper, the manual route while this build cannot reach it | Nothing by itself. **Open Settings** opens System Settings; when you come back, the app checks again and rescans | Switch the permission off in System Settings |
```

- [ ] **Step 3: UX_AND_CLI.md** — `(deliverable 3; buttons for the helper in deliverable 4)` → `(shipped 2026-09-27; buttons for the helper in deliverable 4)`; `**Full Disk Access at need** (deliverable 3)` → `**Full Disk Access at need** (shipped 2026-09-27)`.
- [ ] **Step 4: STATUS.md** — `**2 of 4 done:**` → `**3 of 4 done:**`; the "Next" sentence becomes `Deliverable 3: the GUI Permissions section and the Full Disk Access prompt, driven by EPERM counted in the scan. Next: the helper's register/approval/unregister flow and the root-action buttons, gated on a signed build.`; append a log section `## 2026-09-27 — user-first permissions, deliverable 3 of 4: the GUI asks at need` with the test count, mutants, and whether the visual check ran.
- [ ] **Step 5: Freeze and review (P3)** — both reviewers.

helper-security-reviewer — scope: `Package.swift`, `Sources/XCodeVault/XCodeVaultApp.swift`. Focus: the app gains the client module for read-only calls only (`serviceStatus`, `hasUsableTeamID`, `bundlesDaemon`); no `connect()`, no registration; nothing opens a URL other than the Full Disk Access pane; the single-connection rule and `helper-invariants.sh` hold.

migration-safety-reviewer — scope: `Sources/XCodeVaultCore/Support/DiskUsage.swift`, `Sources/XCodeVaultCore/Scan/ScanReport.swift`, `Sources/XCodeVaultCore/Scan/Scanner.swift`. Focus: `unreadable`, `skippedMountPoints` and `isLowerBound` behave exactly as before; nothing that verifies a migration or plans a deletion reads the new counter; the counter cannot suppress a refusal or a lower-bound flag.

- [ ] **Step 6: Commit message**

```text
GUI: Permissions section, and Full Disk Access asked for only when a scan is refused

Deliverable 3 of 4 of docs/superpowers/plans/2026-09-27-user-first-permissions.md.

The scan counts unreadable entries refused with EPERM (macOS privacy protection, H15), separately
from EACCES; the summary adds them up. The Overview says "Some folders could not be read" with Open
Settings only when that count is non-zero and the grant is not known to be present — the first run
asks for nothing. A Permissions section shows both states with why and one control, and re-checks and
rescans when the user comes back from System Settings. The decisions live in Core
(PermissionPrompts, offersOpenSettings) and are tested; the view decides nothing. The app links the
helper client for read-only state only.

Tests: N executed, 0 failures. Mutants: 2 applied, 2 killed (ask only at need; EACCES is not a
privacy refusal).

Reviewed-by: helper-security-reviewer
Reviewed-by: migration-safety-reviewer
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

- [ ] **Step 7: P4**

---

# Deliverable 4 — The helper's register/approval/unregister flow, and the root-action buttons, gated on a signed build

One commit. Reviews: **helper-security-reviewer** (HelperClient registration and XPC calls, the app's use of them, `bundle-app.sh`, `public-surface.sh`) **and** **migration-safety-reviewer** (the runner that creates the vault folder and empties the dyld cache, its journal, its in-use refusal). In every build this machine can produce, all of it renders as "Not available in this build".

### Task 4.1: `HelperClient` — registration and one-message XPC calls

**Files:**
- Modify: `Sources/XCodeVaultHelperClient/HelperClient.swift`
- Test: `Tests/XCodeVaultCoreTests/HelperClientTests.swift`

**Interfaces:**
- Produces: `HelperClient.Failure.connectionFailed(String)`, `.unexpectedProxy`; `public func register() throws`; `public func unregister() async throws`; `public static func openApprovalSettings()`; `public func createVaultDirectory(volumeUUID: String) async throws -> HelperResult`; `public func removeRegenerableSystemDirectoryContents(target: HelperCleanupTarget) async throws -> HelperResult`; internal `func send(_:) async throws -> HelperResult`; internal `final class ResumeOnce<T: Sendable>`.

- [ ] **Step 1: Append the failing tests to `HelperClientTests`**

```swift
    // MARK: - One message over one connection (deliverable 4; never run live, #30)

    /// The daemon's side of a fake connection: answers each verb with a canned result and records the call.
    private final class FakeDaemon: NSObject, XCodeVaultHelperXPC, @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        let result: HelperResult
        init(result: HelperResult) { self.result = result }
        private func record(_ s: String) { lock.withLock { calls.append(s) } }
        func version(reply: @escaping @Sendable (String) -> Void) { reply("fake") }
        func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
            record("clean:\(target)"); reply(result)
        }
        func createVaultDirectory(volumeUUID: String, reply: @escaping @Sendable (HelperResult) -> Void) {
            record("vault:\(volumeUUID)"); reply(result)
        }
        func forgetMountObservation(target: String, reply: @escaping @Sendable (HelperResult) -> Void) {
            record("forget:\(target)"); reply(result)
        }
    }

    /// A connection that hands out a chosen proxy, or fails through the error handler, and records the order
    /// of the calls that matter. `invalidate()` also fires the stored error handler, as a real connection
    /// does after a reply — which is what `ResumeOnce` exists to survive.
    private final class ProxyConnection: NSXPCConnection, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        let proxy: Any
        let failure: (any Error)?
        var handler: (@Sendable (any Error) -> Void)?
        init(proxy: Any, failure: (any Error)? = nil) {
            self.proxy = proxy
            self.failure = failure
            super.init()
        }
        private func record(_ s: String) { lock.withLock { events.append(s) } }
        override func setCodeSigningRequirement(_ requirement: String) { record("requirement") }
        override func resume() { record("resume") }
        override func invalidate() {
            record("invalidate")
            handler?(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid))
        }
        override func remoteObjectProxyWithErrorHandler(_ handler: @escaping @Sendable (any Error) -> Void) -> Any {
            record("proxy")
            self.handler = handler
            if let failure { handler(failure) }
            return proxy
        }
    }

    func testAVerbIsSentAfterTheRequirementAndTheConnectionIsInvalidatedAfterTheReply() async throws {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "created"))
        let connection = ProxyConnection(proxy: daemon)
        let result = try await HelperClient(team: goodTeam, makeConnection: { _ in connection }).createVaultDirectory(volumeUUID: "U-1")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(daemon.calls, ["vault:U-1"])
        XCTAssertEqual(connection.events, ["requirement", "resume", "proxy", "invalidate"])
    }

    func testAReplyFollowedByTheInvalidationErrorResumesOnce() async throws {
        // `invalidate()` fires the error handler after the reply; without ResumeOnce this crashes the process.
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "done"))
        let result = try await HelperClient(team: goodTeam, makeConnection: { _ in ProxyConnection(proxy: daemon) })
            .removeRegenerableSystemDirectoryContents(target: .coreSimulatorDyldCache)
        XCTAssertEqual(result.message, "done")
        XCTAssertEqual(daemon.calls, ["clean:coreSimulatorDyldCache"], "the enum's raw value crosses the wire, never a path")
    }

    func testAConnectionErrorThrowsAndTheDaemonIsNeverCalled() async {
        let daemon = FakeDaemon(result: HelperResult(ok: true, message: "unused"))
        let connection = ProxyConnection(proxy: NSObject(), failure: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted))
        do {
            _ = try await HelperClient(team: goodTeam, makeConnection: { _ in connection }).createVaultDirectory(volumeUUID: "U-1")
            XCTFail("an interrupted connection must throw")
        } catch let failure as HelperClient.Failure {
            guard case .connectionFailed = failure else { return XCTFail("\(failure)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(daemon.calls, [])
        XCTAssertTrue(connection.events.contains("invalidate"), "a failed call still releases its connection")
    }

    func testAnUnusableTeamIsRefusedBeforeAnyConnectionExists() async {
        let connection = ProxyConnection(proxy: FakeDaemon(result: HelperResult(ok: true, message: "unused")))
        do {
            _ = try await HelperClient(team: HelperIdentity.teamIDPlaceholder, makeConnection: { _ in connection }).createVaultDirectory(volumeUUID: "U-1")
            XCTFail("the placeholder build must refuse")
        } catch {
            XCTAssertEqual(error as? HelperClient.Failure, .unusableTeamID(HelperIdentity.teamIDPlaceholder))
        }
        XCTAssertEqual(connection.events, [], "refused before the connection was touched")
    }

    func testAProxyThatIsNotTheHelperIsAnErrorNotACrash() async {
        do {
            _ = try await HelperClient(team: goodTeam, makeConnection: { _ in ProxyConnection(proxy: NSObject()) }).createVaultDirectory(volumeUUID: "U")
            XCTFail("expected unexpectedProxy")
        } catch {
            XCTAssertEqual(error as? HelperClient.Failure, .unexpectedProxy)
        }
    }
```

If the compiler rejects the `remoteObjectProxyWithErrorHandler` override signature, copy the exact signature from the error message (the SDK's annotation of the handler's `@Sendable` is what may differ) — the test's intent does not change.

Also correct the three pre-existing comments that say "`SMAppService` will not register an unsigned daemon" (`HelperClient.swift`'s header, `HelperIdentity.helperRequirement`'s doc in `HelperProtocol.swift`, `HelperClientTests`' header): nothing recorded measures it (docs review of deliverable 1, F10). Replace each with what is recorded — no code had called `register()` before this deliverable, and no build has had a real Developer ID team ID, which both ends of the connection require.

- [ ] **Step 2: Implement in `HelperClient.swift`**

Add two cases to `Failure` and their descriptions:

```swift
        /// The helper did not reply: not running, not approved, the peer refused, or the connection broke.
        case connectionFailed(String)
        /// What came back was not the helper's interface. Unreachable with a connection `connect()`
        /// configured; stated so a future change turns it into an error rather than a crash.
        case unexpectedProxy
```

```swift
            case .connectionFailed(let why):
                return "The privileged helper did not reply (\(why)). Whether it acted is unknown; rescan to see."
            case .unexpectedProxy:
                return "The connection did not return the privileged helper's interface. Refusing to use it."
```

Add after `bundlesDaemon`:

```swift
    // MARK: - Registration (deliverable 4 of the 2026-09-27 permissions plan)
    //
    // **Never called live.** No build has had a real Developer ID team ID (M5, issue #30), and both ends
    // of the connection require one. The decisions around these calls — when to register, how long to
    // wait, what counts as approved — live in Core's `HelperApprovalFlow`, tested with a fake.

    /// Registers the daemon. For a daemon this lands in "requires approval": the user approves it in System
    /// Settings ▸ General ▸ Login Items & Extensions, with administrator authentication.
    public func register() throws {
        try SMAppService.daemon(plistName: HelperIdentity.plistName).register()
    }

    /// Removes the registration, so no stale Background Task Management entry outlives the user's intent
    /// (SECURITY_MODEL.md, Registration).
    public func unregister() async throws {
        try await SMAppService.daemon(plistName: HelperIdentity.plistName).unregister()
    }

    /// Opens System Settings at Login Items & Extensions, where the user approves the helper.
    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Verbs (never run live, #30)

    public func createVaultDirectory(volumeUUID: String) async throws -> HelperResult {
        try await send { helper, reply in helper.createVaultDirectory(volumeUUID: volumeUUID, reply: reply) }
    }

    public func removeRegenerableSystemDirectoryContents(target: HelperCleanupTarget) async throws -> HelperResult {
        try await send { helper, reply in helper.removeRegenerableSystemDirectoryContents(target: target.rawValue, reply: reply) }
    }

    /// One message over one connection, then the connection is invalidated.
    ///
    /// **The peer check is `connect()`'s and only `connect()`'s.** The requirement is set before `resume()`,
    /// so nothing is sent to an unvalidated peer, whatever `serviceStatus()` reports.
    ///
    /// **Exactly one outcome.** The reply and the proxy's error handler can both fire — invalidating after a
    /// reply calls the error handler too — so the continuation resumes through `ResumeOnce`, and the second
    /// caller is dropped instead of crashing the process.
    func send(_ message: (any XCodeVaultHelperXPC, @escaping @Sendable (HelperResult) -> Void) -> Void) async throws -> HelperResult {
        let connection = try connect()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: Failure.connectionFailed(error.localizedDescription))
            }
            guard let helper = proxy as? any XCodeVaultHelperXPC else {
                once.resume(throwing: Failure.unexpectedProxy)
                return
            }
            message(helper) { result in once.resume(returning: result) }
        }
    }
}

/// Resumes a continuation at most once. `@unchecked Sendable` because every access is under the lock.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
```

(The `}` that closed `HelperClient` moves to before `ResumeOnce`, as shown; `ResumeOnce`'s own closing `}` ends the file.)

### Task 4.2: Core — the dyld action, the helper protocol, the approval flow, the runner, the controls

**Files:**
- Modify: `Sources/XCodeVaultCore/Permissions/PrivilegeRequirement.swift` (a second action)
- Modify: `Sources/XCodeVaultCore/Clean/CleanPlanner.swift` (`CleanAction.privilegedAction`; `CleanExecutor.simulatorWorkIsRunning`; the dyld warning text)
- Modify: `Sources/XCodeVaultCore/Permissions/PermissionControls.swift` (`actionControl`, `rowButton`)
- Create: `Sources/XCodeVaultCore/Permissions/PrivilegedHelper.swift`
- Test: Create `Tests/XCodeVaultCoreTests/PrivilegedHelperTests.swift`; append to `PermissionControlsTests.swift`

**Interfaces:**
- Consumes: `HelperState`, `PrivilegedAction`, `Journal`, `CleanExecutor.xcodeIsRunning`.
- Produces: `PrivilegedAction.emptyCoreSimulatorDyldCache`; `CleanAction.privilegedAction: PrivilegedAction?`; `public static func CleanExecutor.simulatorWorkIsRunning() -> Bool`; `public enum PrivilegedActionControl { case run, requestHelper, notAvailableInThisBuild }`; `public enum HelperRowButton { case install, uninstall, none }`; `HelperState.actionControl`, `HelperState.rowButton`; `public protocol PrivilegedHelper: Sendable { func state() -> HelperState; func register() throws; func openApprovalSettings(); func unregister() async throws; func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply }`; `public struct PrivilegedActionReply`; `public enum HelperApprovalOutcome`; `public struct HelperApprovalFlow` (`init(helper:pollInterval:maxPolls:)`, `run() async -> HelperApprovalOutcome`); `public enum PrivilegedActionOutcome { case done(PrivilegedActionReply), refused(String), failed(String) }`; `public struct PrivilegedActionRunner` (`init(helper:journal:isXcodeRunning:isSimulatorWorkRunning:)`, `run(_:) async -> PrivilegedActionOutcome`).

- [ ] **Step 1: Write the failing tests — append to `PermissionControlsTests.swift`**

```swift
/// Spec §4's first mutant target: a control that runs a root action appears only when the helper is enabled.
final class PrivilegedActionControlTests: XCTestCase {
    func testOnlyAnEnabledHelperRunsAnAction() {
        XCTAssertEqual(HelperState.enabled.actionControl, .run)
        XCTAssertEqual(HelperState.awaitingApproval.actionControl, .requestHelper)
        XCTAssertEqual(HelperState.notInstalled.actionControl, .requestHelper)
        XCTAssertEqual(HelperState.unavailableInThisBuild.actionControl, .notAvailableInThisBuild)
        XCTAssertEqual(HelperState.allCases.filter { $0.actionControl == .run }, [.enabled])
    }

    func testTheHelperRowNeverOffersAButtonThisBuildCannotHonour() {
        XCTAssertEqual(HelperState.unavailableInThisBuild.rowButton, HelperRowButton.none)
        XCTAssertEqual(HelperState.notInstalled.rowButton, .install)
        XCTAssertEqual(HelperState.awaitingApproval.rowButton, .install)
        XCTAssertEqual(HelperState.enabled.rowButton, .uninstall)
    }

    func testOnlyTheWholeDyldCacheMapsToTheHelperVerb() {
        func action(_ path: String, root: Bool) -> CleanAction {
            CleanAction(categoryID: "x", categoryName: "X", path: path, bytes: 1, isExperimental: true, risk: .low, requiresRoot: root, notes: [])
        }
        XCTAssertEqual(action(PrivilegeRequirement.coreSimulatorDyldCachePath, root: true).privilegedAction, .emptyCoreSimulatorDyldCache)
        // The verb empties the whole cache; a path inside it must not borrow that.
        XCTAssertNil(action(PrivilegeRequirement.coreSimulatorDyldCachePath + "/25G229", root: true).privilegedAction)
        XCTAssertNil(action("/Library/Developer/CommandLineTools", root: true).privilegedAction)
        XCTAssertNil(action(PrivilegeRequirement.coreSimulatorDyldCachePath, root: false).privilegedAction)
    }

    func testTheSimulatorWorkPredicateNamesTheProcessesThatUseTheCache() {
        for path in [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/launchd_sim",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl", "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
        ] {
            XCTAssertTrue(CleanExecutor.isSimulatorWorkExecutable(path), path)
        }
        XCTAssertFalse(CleanExecutor.isSimulatorWorkExecutable("/usr/bin/xcodebuild-wrapper"))
        XCTAssertFalse(CleanExecutor.isSimulatorWorkExecutable("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
    }
}
```

- [ ] **Step 2: Write the failing tests — create `Tests/XCodeVaultCoreTests/PrivilegedHelperTests.swift`**

```swift
import XCTest

@testable import XCodeVaultCore

/// A scripted helper: `state()` answers from `states` in order and repeats the last one.
final class FakeHelper: PrivilegedHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [HelperState]
    private var _registerCalls = 0
    private var _settingsOpened = 0
    private var _performed: [PrivilegedAction] = []
    let registerError: (any Error)?
    let reply: PrivilegedActionReply
    let performError: (any Error)?

    init(
        _ states: [HelperState], registerError: (any Error)? = nil, reply: PrivilegedActionReply = PrivilegedActionReply(ok: true, message: "done"),
        performError: (any Error)? = nil
    ) {
        self.states = states
        self.registerError = registerError
        self.reply = reply
        self.performError = performError
    }

    var registerCalls: Int { lock.withLock { _registerCalls } }
    var settingsOpened: Int { lock.withLock { _settingsOpened } }
    var performed: [PrivilegedAction] { lock.withLock { _performed } }

    func state() -> HelperState { lock.withLock { states.count > 1 ? states.removeFirst() : states[0] } }
    func register() throws {
        lock.withLock { _registerCalls += 1 }
        if let registerError { throw registerError }
    }
    func openApprovalSettings() { lock.withLock { _settingsOpened += 1 } }
    func unregister() async throws {}
    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply {
        lock.withLock { _performed.append(action) }
        if let performError { throw performError }
        return reply
    }
}

private struct Refused: Error {}

/// Spec §3's register → open Settings → poll → enabled, driven with a fake: `register()` and approval cannot
/// run live before M5 (#30).
final class HelperApprovalFlowTests: XCTestCase {
    private func flow(_ helper: FakeHelper, polls: Int = 5) -> HelperApprovalFlow {
        HelperApprovalFlow(helper: helper, pollInterval: .zero, maxPolls: polls)
    }

    func testAnUnavailableBuildNeverRegistersOrOpensSettings() async {
        let unavailable = FakeHelper([.unavailableInThisBuild])
        let outcome = await flow(unavailable).run()
        XCTAssertEqual(outcome, .notAvailableInThisBuild)
        XCTAssertEqual(unavailable.registerCalls, 0)
        XCTAssertEqual(unavailable.settingsOpened, 0)
        // Positive control: an installable build does register.
        let installable = FakeHelper([.notInstalled, .awaitingApproval, .enabled])
        _ = await flow(installable).run()
        XCTAssertEqual(installable.registerCalls, 1)
    }

    func testAnEnabledHelperNeedsNoApproval() async {
        let helper = FakeHelper([.enabled])
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(helper.registerCalls, 0)
        XCTAssertEqual(helper.settingsOpened, 0)
    }

    func testNotInstalledRegistersOpensSettingsAndWaitsForApproval() async {
        let helper = FakeHelper([.notInstalled, .awaitingApproval, .awaitingApproval, .enabled])
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(helper.registerCalls, 1)
        XCTAssertEqual(helper.settingsOpened, 1)
    }

    func testARegisterThatThrowsIntoApprovalIsNotAFailure() async {
        // For a daemon, `register()` is reported to throw while the service lands in approval — unmeasured here
        // (#30). The outcome is read from the status, not from the throw.
        let helper = FakeHelper([.notInstalled, .awaitingApproval, .awaitingApproval, .enabled], registerError: Refused())
        let outcome = await flow(helper).run()
        XCTAssertEqual(outcome, .enabled)
    }

    func testARegisterThatThrowsAndLeavesItNotInstalledFails() async {
        let helper = FakeHelper([.notInstalled], registerError: Refused())
        let outcome = await flow(helper).run()
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(helper.settingsOpened, 0, "nothing to approve")
    }

    func testWaitingIsBounded() async {
        let helper = FakeHelper([.awaitingApproval])
        let outcome = await flow(helper, polls: 3).run()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(helper.settingsOpened, 1)
    }

    func testARegistrationThatVanishesStopsTheWait() async {
        let helper = FakeHelper([.awaitingApproval, .awaitingApproval, .notInstalled])
        let outcome = await flow(helper).run()
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
    }

    func testCancellationStopsTheWait() async {
        let helper = FakeHelper([.awaitingApproval])
        let task = Task { await HelperApprovalFlow(helper: helper, pollInterval: .seconds(60), maxPolls: 10).run() }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }
}

/// The runner that performs a root action through the helper, journaled, refusing while the cache is in use.
final class PrivilegedActionRunnerTests: XCTestCase {
    private func runner(_ helper: FakeHelper, _ t: TempDir, xcode: Bool = false, simulators: Bool = false) -> PrivilegedActionRunner {
        PrivilegedActionRunner(
            helper: helper, journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), isXcodeRunning: { xcode },
            isSimulatorWorkRunning: { simulators })
    }

    func testNothingRunsUnlessTheHelperIsEnabled() async {
        let t = TempDir()
        let waiting = FakeHelper([.awaitingApproval])
        guard case .refused = await runner(waiting, t).run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must refuse") }
        XCTAssertEqual(waiting.performed, [])
        // Positive control: enabled runs it.
        let enabled = FakeHelper([.enabled])
        guard case .done = await runner(enabled, t).run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must run") }
        XCTAssertEqual(enabled.performed, [.createVaultDirectory(volumeUUID: "U")])
    }

    func testTheDyldCacheIsRefusedWhileXcodeOrSimulatorWorkRuns() async {
        let t = TempDir()
        for (xcode, simulators) in [(true, false), (false, true)] {
            let helper = FakeHelper([.enabled])
            guard case .refused = await runner(helper, t, xcode: xcode, simulators: simulators).run(.emptyCoreSimulatorDyldCache) else {
                return XCTFail("must refuse with xcode=\(xcode) simulators=\(simulators)")
            }
            XCTAssertEqual(helper.performed, [])
        }
        let idle = FakeHelper([.enabled])
        guard case .done = await runner(idle, t).run(.emptyCoreSimulatorDyldCache) else { return XCTFail("idle must run") }
        XCTAssertEqual(idle.performed, [.emptyCoreSimulatorDyldCache])
    }

    func testTheVaultFolderIsNotBlockedBySimulatorWork() async {
        let t = TempDir()
        let helper = FakeHelper([.enabled])
        guard case .done = await runner(helper, t, simulators: true).run(.createVaultDirectory(volumeUUID: "U")) else {
            return XCTFail("the in-use refusal is scoped to the cache")
        }
    }

    func testOnlyTheCacheRunOpensAsStartedSoOnlyItCanShowAsInterrupted() {
        // A crash mid-call leaves only the opening record. `.started` is what `interrupted()` lists; the vault
        // folder opens `.planned`, so it is never shown as an interrupted migration with `migration abort`.
        XCTAssertEqual(PrivilegedAction.emptyCoreSimulatorDyldCache.openingState, .started)
        XCTAssertEqual(PrivilegedAction.createVaultDirectory(volumeUUID: "U").openingState, .planned)
    }

    func testEachRunIsJournalledOpenedThenClosed() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let r = PrivilegedActionRunner(helper: FakeHelper([.enabled]), journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
        _ = await r.run(.emptyCoreSimulatorDyldCache)
        _ = await r.run(.createVaultDirectory(volumeUUID: "U"))
        let e = try journal.entries()
        XCTAssertEqual(e.map(\.state), [.started, .completed, .planned, .completed])
        XCTAssertEqual(e.map(\.kind), [.clean, .clean, .migration, .migration])
        XCTAssertEqual(e[0].id, e[1].id)
        XCTAssertEqual(e[2].id, e[3].id)
        // The vault-folder run opens with `.planned`, so a crash mid-call is never listed as an interrupted
        // migration with `migration abort` suggested for it.
        XCTAssertEqual(try journal.interrupted().count, 0)
    }

    func testAFailedReplyAndAThrownCallAreJournalledFailed() async throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let failing = FakeHelper([.enabled], reply: PrivilegedActionReply(ok: false, message: "refused by helper"))
        let failed = await PrivilegedActionRunner(helper: failing, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            .run(.emptyCoreSimulatorDyldCache)
        XCTAssertEqual(failed, .failed("refused by helper"))
        let throwing = FakeHelper([.enabled], performError: Refused())
        guard case .failed = await PrivilegedActionRunner(helper: throwing, journal: journal, isXcodeRunning: { false }, isSimulatorWorkRunning: { false })
            .run(.emptyCoreSimulatorDyldCache)
        else { return XCTFail("a thrown call is a failure") }
        XCTAssertEqual(try journal.entries().map(\.state), [.started, .failed, .started, .failed])
    }

    func testAnUnwritableJournalRefusesBeforeActing() async {
        let t = TempDir()
        let notADirectory = t.file("f", bytes: 1)
        let helper = FakeHelper([.enabled])
        let r = PrivilegedActionRunner(
            helper: helper, journal: Journal(url: URL(fileURLWithPath: notADirectory + "/j.jsonl")), isXcodeRunning: { false },
            isSimulatorWorkRunning: { false })
        guard case .refused = await r.run(.createVaultDirectory(volumeUUID: "U")) else { return XCTFail("must refuse") }
        XCTAssertEqual(helper.performed, [], "nothing is done that the journal cannot record")
    }
}
```

- [ ] **Step 3: `PrivilegeRequirement.swift` — the second action**

In `PrivilegedAction`, add the case and extend every switch:

```swift
    /// The helper's `removeRegenerableSystemDirectoryContents(coreSimulatorDyldCache)`: empties
    /// `Caches/dyld`, leaving the directory itself (operator decision 2026-09-27). Experimental: what rebuilds
    /// a deleted cache is not identified (H14).
    case emptyCoreSimulatorDyldCache

    public var requirement: PrivilegeRequirement {
        switch self {
        case .createVaultDirectory: return .helper
        case .emptyCoreSimulatorDyldCache: return .helperWithFullDiskAccess
        }
    }

    public var title: String {
        switch self {
        case .createVaultDirectory: return "Create the vault folder"
        case .emptyCoreSimulatorDyldCache: return "Empty the CoreSimulator dyld cache"
        }
    }

    /// Only the cache is in use while Xcode or a simulator runs; the runner refuses it then.
    var usesTheSimulatorCaches: Bool {
        if case .emptyCoreSimulatorDyldCache = self { return true }
        return false
    }

    /// The cache is cleanup, and opens `.started` so a crash mid-call shows as an interrupted clean. The
    /// vault folder is recorded like `vault init`'s own records, and opens `.planned` so it is never listed as
    /// an interrupted migration with `migration abort` suggested for it.
    var journalKind: JournalEntry.Kind {
        switch self {
        case .createVaultDirectory: return .migration
        case .emptyCoreSimulatorDyldCache: return .clean
        }
    }

    var openingState: JournalEntry.State {
        switch self {
        case .createVaultDirectory: return .planned
        case .emptyCoreSimulatorDyldCache: return .started
        }
    }

    var journalPaths: [String] {
        switch self {
        case .createVaultDirectory: return []
        case .emptyCoreSimulatorDyldCache: return [PrivilegeRequirement.coreSimulatorDyldCachePath]
        }
    }

    var journalDetail: [String: String] {
        switch self {
        case .createVaultDirectory(let volumeUUID): return [VaultDirectoryRefusal.volumeUUIDKey: volumeUUID]
        case .emptyCoreSimulatorDyldCache: return [:]
        }
    }
```

- [ ] **Step 4: `CleanPlanner.swift`**

After `privilegeRequirement` in `CleanAction`:

```swift
    /// The helper verb that performs this action, when one exists: the whole dyld cache only. The verb empties
    /// every build's cache, so a path inside it must not borrow that (operator decision 2026-09-27). `clean`
    /// never runs this; the app does, through `PrivilegedActionRunner`.
    public var privilegedAction: PrivilegedAction? {
        guard requiresRoot, path == PrivilegeRequirement.coreSimulatorDyldCachePath else { return nil }
        return .emptyCoreSimulatorDyldCache
    }
```

In `CleanExecutor`, after `isXcodeExecutable(_:bundleIdentifierAt:)`:

```swift
    /// Whether a simulator, `simctl` or `xcodebuild` is running — the processes that use the CoreSimulator
    /// dyld cache, which the helper's cleanup verb does not check for itself (`scripts/bundle-app.sh`). Fails
    /// closed like `xcodeIsRunning`: "I cannot tell" is not "no".
    public static func simulatorWorkIsRunning() -> Bool {
        switch runningExecutablePaths() {
        case .none: return true
        case .some(let paths): return paths.contains(where: isSimulatorWorkExecutable)
        }
    }

    static func isSimulatorWorkExecutable(_ path: String) -> Bool {
        ["launchd_sim", "simctl", "xcodebuild"].contains((path as NSString).lastPathComponent)
    }
```

In `plan(report:categories:granular:)`, the dyld warning's first string becomes:

```swift
                "CoreSimulator dyld caches are root-owned and need root with Full Disk Access (H15). `clean` lists them for accounting and never "
                    + "deletes them; the app can empty them through the privileged helper, which needs a signed build and whose own Full Disk "
                    + "Access is unmeasured. "
```

(the remaining `+ "Most of this total is NOT durable free space — …"` lines are unchanged).

- [ ] **Step 5: `PermissionControls.swift` — append**

```swift
/// What stands next to an action that needs the privileged helper.
public enum PrivilegedActionControl: Sendable, Equatable {
    /// The helper is enabled: the button runs the action.
    case run
    /// A build that can reach the helper, not yet approved: the button opens the sheet with **Allow**.
    case requestHelper
    /// This build can never reach the helper: no button; "Not available in this build" and the manual route.
    case notAvailableInThisBuild
}

/// The helper row's one button.
public enum HelperRowButton: Sendable, Equatable {
    case install, uninstall, none
}

extension HelperState {
    /// Spec §4's key decision: a control that runs a root action appears only when the helper is enabled,
    /// and a build that cannot reach the helper shows no button at all (ADR-0007).
    public var actionControl: PrivilegedActionControl {
        switch self {
        case .enabled: return .run
        case .notInstalled, .awaitingApproval: return .requestHelper
        case .unavailableInThisBuild: return .notAvailableInThisBuild
        }
    }

    /// **Install…** continues from "waiting for approval" too: it opens Login Items & Extensions and waits.
    public var rowButton: HelperRowButton {
        switch self {
        case .unavailableInThisBuild: return .none
        case .notInstalled, .awaitingApproval: return .install
        case .enabled: return .uninstall
        }
    }
}
```

- [ ] **Step 6: Create `Sources/XCodeVaultCore/Permissions/PrivilegedHelper.swift`**

```swift
import Foundation

/// What XCodeVault needs from its privileged helper, in Core's terms, so the decisions around it — when to
/// register, how long to wait, when to refuse — live here and are tested with fakes. The app conforms it to
/// `HelperClient`; Core does not import the client (Package.swift).
///
/// Methods, not closures, on purpose: `scripts/public-surface.sh` rule 1 refuses any public declaration
/// shaped `throws -> Void` — the shape of a fault-injection hook — and a protocol method renders without it.
public protocol PrivilegedHelper: Sendable {
    func state() -> HelperState
    func register() throws
    func openApprovalSettings()
    func unregister() async throws
    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply
}

/// The helper's answer in Core's terms: a copy of `HelperResult`, which Core cannot see.
public struct PrivilegedActionReply: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var bytesFreed: UInt64

    public init(ok: Bool, message: String, bytesFreed: UInt64 = 0) {
        self.ok = ok
        self.message = message
        self.bytesFreed = bytesFreed
    }
}

public enum HelperApprovalOutcome: Sendable, Equatable {
    case enabled
    case notAvailableInThisBuild
    case timedOut
    case cancelled
    case failed(String)
}

/// Spec §3: `register()` → open Login Items & Extensions → poll the status → `enabled`. Never run live before
/// M5 (#30); `HelperApprovalFlowTests` drives it with a fake.
public struct HelperApprovalFlow: Sendable {
    let helper: any PrivilegedHelper
    let pollInterval: Duration
    let maxPolls: Int

    /// Five minutes at one poll a second by default: approving needs the user to find the switch and
    /// authenticate. Waiting stops when the caller's task is cancelled.
    public init(helper: any PrivilegedHelper, pollInterval: Duration = .seconds(1), maxPolls: Int = 300) {
        self.helper = helper
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    public func run() async -> HelperApprovalOutcome {
        switch helper.state() {
        case .unavailableInThisBuild:
            return .notAvailableInThisBuild
        case .enabled:
            return .enabled
        case .awaitingApproval:
            break
        case .notInstalled:
            do {
                try helper.register()
            } catch {
                // For a daemon, `register()` is reported to throw while the service lands in approval —
                // unmeasured here (#30). So the outcome is read from the status, not from the throw.
                if helper.state() != .awaitingApproval { return .failed("\(error)") }
            }
            if helper.state() == .enabled { return .enabled }
        }
        helper.openApprovalSettings()
        for _ in 0..<maxPolls {
            do { try await Task.sleep(for: pollInterval) } catch { return .cancelled }
            switch helper.state() {
            case .enabled: return .enabled
            case .awaitingApproval: continue
            case .notInstalled: return .failed("The helper's registration disappeared while waiting for approval.")
            case .unavailableInThisBuild: return .notAvailableInThisBuild
            }
        }
        return .timedOut
    }
}

public enum PrivilegedActionOutcome: Sendable, Equatable {
    case done(PrivilegedActionReply)
    case refused(String)
    case failed(String)
}

/// Runs one privileged action through the helper, journaled like every change the product makes.
public struct PrivilegedActionRunner: Sendable {
    let helper: any PrivilegedHelper
    let journal: Journal
    let isXcodeRunning: @Sendable () -> Bool
    let isSimulatorWorkRunning: @Sendable () -> Bool

    /// The two defaults are safety checks; `scripts/public-surface.sh` rule 3 pins them to the real ones.
    public init(
        helper: any PrivilegedHelper, journal: Journal = Journal(),
        isXcodeRunning: @escaping @Sendable () -> Bool = CleanExecutor.xcodeIsRunning,
        isSimulatorWorkRunning: @escaping @Sendable () -> Bool = CleanExecutor.simulatorWorkIsRunning
    ) {
        self.helper = helper
        self.journal = journal
        self.isXcodeRunning = isXcodeRunning
        self.isSimulatorWorkRunning = isSimulatorWorkRunning
    }

    public func run(_ action: PrivilegedAction) async -> PrivilegedActionOutcome {
        // Consistency with what the UI showed, not security: `HelperState` is an installation hint, and the
        // peer is authenticated by `HelperClient.connect()` whatever this says.
        guard helper.state() == .enabled else { return .refused("The privileged helper is not enabled.") }
        if action.usesTheSimulatorCaches {
            // The helper's cleanup verb has no in-use check of its own, so the client refuses while anything
            // that uses the dyld cache runs. Both checks answer "running" when they cannot tell.
            if isXcodeRunning() { return .refused("Xcode is running. Quit it first: it uses the dyld cache while it runs.") }
            if isSimulatorWorkRunning() {
                return .refused("A simulator, simctl or xcodebuild is running and uses the dyld cache. Try again when they have stopped.")
            }
        }
        let id = UUID().uuidString
        do {
            try journal.record(
                id: id, kind: action.journalKind, state: action.openingState, summary: "helper: \(action.title)", paths: action.journalPaths,
                detail: action.journalDetail)
        } catch {
            return .refused("The journal could not be written, so nothing was done: \(error)")
        }
        do {
            let reply = try await helper.perform(action)
            // After the fact: a failure to record cannot undo what the helper did, so it is not thrown.
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: reply.ok ? .completed : .failed, summary: "helper: \(action.title): \(reply.message)",
                paths: action.journalPaths, bytes: reply.ok ? reply.bytesFreed : nil, detail: action.journalDetail)
            return reply.ok ? .done(reply) : .failed(reply.message)
        } catch {
            _ = try? journal.record(
                id: id, kind: action.journalKind, state: .failed, summary: "helper: \(action.title): \(error)", paths: action.journalPaths,
                detail: action.journalDetail)
            return .failed("\(error)")
        }
    }
}
```

### Task 4.3: The app — the live adapter, the sheet, the buttons

**Files:**
- Create: `Sources/XCodeVault/LiveHelper.swift`
- Modify: `Sources/XCodeVault/XCodeVaultApp.swift` (`AppModel`, `MainView`, `DoctorView`, `CleanView`, `PermissionsView`, two new views)

**Interfaces:**
- Consumes: everything from Tasks 4.1–4.2; `AppModel.refreshPermissions()` and `PermissionsView` from deliverable 3.

- [ ] **Step 1: Create `Sources/XCodeVault/LiveHelper.swift`**

```swift
import XCodeVaultCore
import XCodeVaultHelperClient
import XCodeVaultHelperProtocol

/// The app's adapter from Core's `PrivilegedHelper` to `HelperClient`. Thin on purpose: every decision is in
/// Core (`HelperApprovalFlow`, `PrivilegedActionRunner`), where fakes test it, and every check that protects
/// the boundary is in `HelperClient`, which the security review reads. This file only forwards — it is the
/// one untested link, and it holds nothing that could be wrong in an interesting way.
struct LiveHelper: PrivilegedHelper {
    let client = HelperClient()

    func state() -> HelperState {
        HelperState(status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, daemonIsBundled: client.bundlesDaemon)
    }

    func register() throws { try client.register() }

    func openApprovalSettings() { HelperClient.openApprovalSettings() }

    func unregister() async throws { try await client.unregister() }

    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply {
        let result: HelperResult
        switch action {
        case .createVaultDirectory(let volumeUUID):
            result = try await client.createVaultDirectory(volumeUUID: volumeUUID)
        case .emptyCoreSimulatorDyldCache:
            result = try await client.removeRegenerableSystemDirectoryContents(target: .coreSimulatorDyldCache)
        }
        return PrivilegedActionReply(ok: result.ok, message: result.message, bytesFreed: result.bytesFreed)
    }
}
```

- [ ] **Step 2: `AppModel` — add after `appDidBecomeActive()`**

```swift
    /// A root action waiting on the helper's approval: set when the user chose one and the helper still needs
    /// approving; `showsHelperSheet` presents the one-sentence explanation with **Allow**.
    var pendingPrivilegedAction: PrivilegedAction?
    var showsHelperSheet = false
    /// Non-nil while waiting for the user to approve the helper in System Settings.
    var helperProgress: String?
    var lastPrivilegedResult: String?
    private var approvalTask: Task<Void, Never>?

    /// Every button that runs a root action comes through here and decides by `helperState.actionControl`,
    /// the tested function, never on its own.
    func request(_ action: PrivilegedAction) {
        switch helperState.actionControl {
        case .run:
            Task { await perform(action) }
        case .requestHelper:
            pendingPrivilegedAction = action
            showsHelperSheet = true
        case .notAvailableInThisBuild:
            return  // no button is shown in this state (ADR-0007)
        }
    }

    /// **Allow** in the sheet (with the action) and **Install…** in Permissions (without one).
    func installHelper(then action: PrivilegedAction?) {
        showsHelperSheet = false
        pendingPrivilegedAction = nil
        helperProgress = "Waiting for you to approve XCodeVault in System Settings ▸ General ▸ Login Items & Extensions…"
        approvalTask = Task {
            let outcome = await HelperApprovalFlow(helper: LiveHelper()).run()
            helperProgress = nil
            refreshPermissions()
            switch outcome {
            case .enabled:
                if let action { await perform(action) }
            case .notAvailableInThisBuild:
                lastError = HelperState.unavailableInThisBuild.why
            case .timedOut:
                lastError = "macOS has not approved the helper yet. Approve it in System Settings ▸ General ▸ Login Items & Extensions, then try again."
            case .cancelled:
                break
            case .failed(let why):
                lastError = why
            }
        }
    }

    func stopWaitingForApproval() { approvalTask?.cancel() }

    func perform(_ action: PrivilegedAction) async {
        switch await PrivilegedActionRunner(helper: LiveHelper()).run(action) {
        case .done(let reply): lastPrivilegedResult = reply.message
        case .refused(let why), .failed(let why): lastError = why
        }
        await refresh()
    }

    func uninstallHelper() async {
        do { try await LiveHelper().unregister() } catch { lastError = "\(error)" }
        refreshPermissions()
    }
```

- [ ] **Step 3: New views — add at the end of `XCodeVaultApp.swift`**

```swift
/// What stands next to a root action. `HelperState.actionControl` decides; this only renders it, and never
/// renders a button for a build that cannot reach the helper.
struct PrivilegedActionControlView: View {
    let action: PrivilegedAction
    let state: HelperState
    let perform: @MainActor () -> Void
    var body: some View {
        switch state.actionControl {
        case .run: Button(action.title, action: perform)
        case .requestHelper: Button(action.title + "…", action: perform)
        case .notAvailableInThisBuild: Text("Not available in this build.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Spec §3: one sentence of why, and **Allow**.
struct HelperRequestSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.pendingPrivilegedAction?.title ?? "Install the privileged helper").font(.headline)
            Text(model.pendingPrivilegedAction?.requirement.why ?? PrivilegeRequirement.helper.why)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.showsHelperSheet = false
                    model.pendingPrivilegedAction = nil
                }
                Button("Allow") { model.installHelper(then: model.pendingPrivilegedAction) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
```

- [ ] **Step 4: `MainView`** — `DoctorView(findings: model.findings)` becomes `DoctorView(model: model)`, and add to the `NavigationSplitView`'s modifier chain (after `.onReceive`):

```swift
        .sheet(isPresented: $model.showsHelperSheet) { HelperRequestSheet(model: model) }
        .overlay(alignment: .top) {
            if let progress = model.helperProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress)
                    Button("Stop waiting") { model.stopWaitingForApproval() }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .alert(
            "Done", isPresented: Binding(get: { model.lastPrivilegedResult != nil }, set: { if !$0 { model.lastPrivilegedResult = nil } })
        ) {
            Button("OK") {
                // Dismissing is the whole action, as with the error alert above.
            }
        } message: {
            Text(model.lastPrivilegedResult ?? "")
        }
```

- [ ] **Step 5: `DoctorView`** — takes the model and renders the action:

```swift
struct DoctorView: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.findings.isEmpty {
            ContentUnavailableView("No findings", systemImage: "checkmark.seal")
        } else {
            List(model.findings) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(f.severity.rawValue.uppercased()).font(.caption).bold().foregroundStyle(
                            f.severity >= .error ? .red : (f.severity == .warning ? .orange : .secondary));
                        Text(f.title).bold()
                    }
                    Text(f.detail).font(.callout)
                    if let p = f.path { Text(p).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    if let r = f.remediation { Text("→ " + r).font(.callout) }
                    if let action = f.action {
                        PrivilegedActionControlView(action: action, state: model.helperState) { model.request(action) }
                    }
                    if let e = f.evidence { Text("evidence: " + e).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
        }
    }
}
```

- [ ] **Step 6: `CleanView`** — add `@State private var confirmPrivileged: CleanAction?`, and after `ForEach(plan.skipped, …)`:

```swift
                let privileged = plan.actions.filter { $0.privilegedAction != nil }
                if !privileged.isEmpty {
                    GroupBox("Needs the privileged helper") {
                        ForEach(privileged) { a in
                            HStack {
                                Text("\(a.categoryName) (experimental) — \(ByteCount.format(a.bytes))")
                                Spacer()
                                if let action = a.privilegedAction {
                                    PrivilegedActionControlView(action: action, state: model.helperState) { confirmPrivileged = a }
                                }
                            }
                        }
                    }
                }
```

and after the existing `.confirmationDialog(…)`:

```swift
            .confirmationDialog(
                confirmPrivileged?.privilegedAction?.title ?? "",
                isPresented: Binding(get: { confirmPrivileged != nil }, set: { if !$0 { confirmPrivileged = nil } }),
                presenting: confirmPrivileged
            ) { a in
                Button("Empty \(ByteCount.format(a.bytes))", role: .destructive) {
                    if let action = a.privilegedAction { model.request(action) }
                }
            } message: { _ in
                Text(
                    "Experimental. Simulators run without a shared cache until something rebuilds it, and what rebuilds a deleted cache is not identified (H14). Refused while Xcode, a simulator, simctl or xcodebuild runs."
                )
            }
```

- [ ] **Step 7: `PermissionsView`** — the helper section becomes:

```swift
            Section("Privileged helper") {
                LabeledContent("Status", value: report.helper.state.displayName)
                Text(report.helper.why).font(.callout)
                switch model.helperState.rowButton {
                case .install: Button("Install…") { model.installHelper(then: nil) }
                case .uninstall: Button("Uninstall…") { confirmUninstall = true }
                case .none: Text(report.helper.nextStep).font(.callout).foregroundStyle(.secondary)
                }
            }
```

with `@State private var confirmUninstall = false` on the view and, after `.task { … }`:

```swift
        .confirmationDialog("Uninstall the privileged helper?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallHelper() } }
        } message: {
            Text("Actions that need root are unavailable until you install it again.")
        }
```

### Task 4.4: Texts that change with the flow; the safety default pinned; gate comments

**Files:**
- Modify: `Sources/XCodeVaultCore/Permissions/PermissionsReport.swift` (two `nextStep` texts)
- Modify: `scripts/public-surface.sh:165-172` (`DEFAULTS`)
- Modify: `scripts/bundle-app.sh:7-21` (header comment)
- Modify: `Package.swift` (the client target's comment)

- [ ] **Step 1: `PermissionsReport.swift`** — in `HelperState.nextStep`:

```swift
        case .notInstalled:
            return "Nothing to do until you choose an action that needs root; the app's Permissions section can also install it ahead of time."
```

```swift
        case .enabled:
            return "Nothing to do. The app's Permissions section can uninstall it."
```

- [ ] **Step 2: `public-surface.sh`** — add to `DEFAULTS`, after the `VaultRegistry` rows:

```python
    ("PrivilegedActionRunner", "init", "isXcodeRunning", "CleanExecutor.xcodeIsRunning"),
    ("PrivilegedActionRunner", "init", "isSimulatorWorkRunning", "CleanExecutor.simulatorWorkIsRunning"),
```

- [ ] **Step 3: `bundle-app.sh` header** — re-verify each of the five "Gate on this flag" items against `Sources/XCodeVaultHelperCore/HelperService.swift` (read the cleanup verb, `mountStatus(ofDescriptor:)`, `openGuardedDirectory`, `volumeUUID(ofMountPoint:)`, `HelperAudit`), then rewrite lines 7–21 so they state only what is still true, each with its evidence (file:line), and replace "Nothing in the shipped code connects to the privileged helper — no NSXPCConnection anywhere in the app or the CLI" with: "The app can connect since the 2026-09-27 permissions work — gated on a usable team ID and on this flag, so no build made without `--sign` and `--with-helper` can. It has never run live (#30)." Keep `--with-helper` off by default. The item "no in-use check" stays, amended: "the client now refuses while Xcode, a simulator, `simctl` or `xcodebuild` runs (`PrivilegedActionRunner`), which protects against accident; the verb itself still has none, so a hostile client is not constrained by it."

- [ ] **Step 4: `Package.swift`** — the client target's comment sentence `The app links it for the same read-only state (Permissions section); deliverable 4 of the 2026-09-27 permissions plan adds registration and the verb calls;` becomes `The app links it for the Permissions section and, since deliverable 4 of the 2026-09-27 permissions plan, for registration and the verb calls;`.

### Task 4.5: Build cycle, full suite, gates, mutants

- [ ] **Step 1: Red** — the three test files only; `swift build --build-tests 2>&1 | grep 'error:' | head -20` — expected: missing `PrivilegedHelper`, `HelperApprovalFlow`, `PrivilegedActionRunner`, `actionControl`, `rowButton`, `privilegedAction`, `isSimulatorWorkExecutable`, `emptyCoreSimulatorDyldCache`, `createVaultDirectory(volumeUUID:)` on `HelperClient`, `Failure.connectionFailed`.
- [ ] **Step 2: Green** — all implementation; `swift build -Xswiftc -warnings-as-errors`; then

```bash
swift test --skip-build --filter 'HelperClientTests|HelperApprovalFlowTests|PrivilegedActionRunnerTests|PrivilegedActionControlTests|HelperContractTests' 2>&1 | grep -E "Executed [0-9]+ tests|' failed" | tail -10
```

- [ ] **Step 3: The two helper gates**

```bash
bash scripts/helper-invariants.sh && bash scripts/public-surface.sh
```

Expected: both ok; `public-surface` reports two more safety defaults than before (8).

- [ ] **Step 4: Full suite (P1)** and the format check.
- [ ] **Step 5: Mutants (P2)**, after `git add -A`:
  - **M4-1 (spec): an action button appears only when enabled** — `Sources/XCodeVaultCore/Permissions/PermissionControls.swift`, `PrivilegedActionControlTests`, `case .enabled: return .run` → `case .enabled, .awaitingApproval: return .run` (compiles with a warning, which `--build-tests` does not reject)
  - **M4-2: the runner refuses unless enabled** — `Sources/XCodeVaultCore/Permissions/PrivilegedHelper.swift`, `PrivilegedActionRunnerTests`, `guard helper.state() == .enabled else {` → `guard helper.state() != .unavailableInThisBuild else {`
  - **M4-3: the in-use refusal** — same file, `PrivilegedActionRunnerTests`, `if isSimulatorWorkRunning() {` → `if false {`
  - **M4-4: a register that throws into approval is not a failure** — same file, `HelperApprovalFlowTests`, `if helper.state() != .awaitingApproval { return .failed("\(error)") }` → `return .failed("\(error)")`
  - **M4-5: exactly one resume** — `Sources/XCodeVaultHelperClient/HelperClient.swift`, `HelperClientTests`, `let c = continuation` + newline + `        continuation = nil` → `let c = continuation` (pass the anchor as `$'let c = continuation\n        continuation = nil'`). Expected detection: the run crashes with the continuation-misuse fatal error in `testAReplyFollowedByTheInvalidationErrorResumesOnce`; record it as "killed by a crash at the intended guard", distinct from an assertion kill.
  - **M4-6: the safety default is pinned** — not a test class, so by hand: copy `PrivilegedHelper.swift` to the scratchpad, replace `isSimulatorWorkRunning: @escaping @Sendable () -> Bool = CleanExecutor.simulatorWorkIsRunning` with `isSimulatorWorkRunning: @escaping @Sendable () -> Bool = { false }`, confirm with `git diff --stat`, run `bash scripts/public-surface.sh; echo "exit=$?"` (expected: exit 1 naming `PrivilegedActionRunner.init`), restore with `cp -p`, `cmp`, `git diff --quiet`, and run the gate again (expected ok).

### Task 4.6: Docs, STATUS, matrix, reviews, commit, preflight, push

- [ ] **Step 1: README and USER_GUIDE, both files — the helper "In this build" cell** `` Not available: it needs a signed build (issue #30). `vault init`, and then `doctor`, print the command for the vault folder; the dyld cache is listed, never cleaned `` → `Not available in any build made today: it needs a signed build that includes the helper (issue #30), and it has never run live. Until then the app says "Not available in this build" and shows the manual route`. README's honest-state "Privileged helper" row becomes `Built and security-reviewed. The app can register it and call its two verbs, gated on a signed build that includes it — none exists, so it has never run live (issue #30).`

  In USER_GUIDE's app table, within the **Clean** row, the sentence `Rows that need root are listed, never deleted here; the **Needs** column says what they lack` becomes `Rows that need root are never deleted by **Delete selected…**; the **Needs** column says what they lack. The CoreSimulator dyld cache (*experimental*) has its own button, which needs the privileged helper and a confirmation`, and the **Permissions** row's "What it shows" cell becomes `The Full Disk Access and helper states, each with why and one control: **Open Settings** for Full Disk Access; **Install…** or **Uninstall…** for the helper — or, while this build cannot reach it, the manual route`.
- [ ] **Step 2: USER_GUIDE FAQ** — replace the bullet beginning `- **A row says it needs root**` with:

```markdown
- **A row says it needs root, or "Not available in this build"**: XCodeVault's only route to root is
  its privileged helper, and this build cannot reach it — no build made today can (see
  [Permissions](#permissions-which-when-why-and-how-the-app-asks)). The app never shows a button that
  cannot work: it shows the manual route instead, where one exists. With a build that can reach the
  helper, the same place shows a button that asks for it at that moment.
```

- [ ] **Step 3: UX_AND_CLI.md** — `**The helper at need** (deliverable 4)` → `**The helper at need** (shipped 2026-09-27, gated on a signed build; never run live)`.
- [ ] **Step 4: SECURITY_MODEL.md, "Registration"** — replace the blockquote beginning `> **Specification, not shipped behaviour.**` with:

```markdown
> **Written, unit-tested, never run live (2026-09-27).** `HelperClient` registers and unregisters the
> daemon through `SMAppService.daemon(plistName:)`, opens Login Items & Extensions for the approval, and
> calls the two verbs over one validated connection per message. The app decides when through Core's
> `HelperApprovalFlow` and `PrivilegedActionRunner`, tested with fakes. None of it has run against a
> real daemon: no build has had a real Developer ID team ID (M5), and `scripts/bundle-app.sh` keeps
> the daemon behind `--with-helper`, off by default (#30). `COMPATIBILITY_MATRIX.md` records it as
> pending.
```

- [ ] **Step 5: COMPATIBILITY_MATRIX.md** — append four rows to the 2026-09-27 pending table:

```markdown
| Client approval flow (`HelperApprovalFlow`): register → open Settings → poll → enabled | #30 | **unit-tested with a fake only** — pending a signed build |
| Client verb calls (`HelperClient.send`): requirement before resume, one outcome, invalidation | #30 | **unit-tested with a fake connection only** — pending a signed build |
| Whether `xcodevaultctl` inside `XCodeVault.app` sees the app's registration (`Bundle.main`) | #30 | **unmeasured** |
| A release build that includes the helper | #30, M5 | **gap:** `scripts/release.sh` calls `bundle-app.sh --release --sign …` without `--with-helper`, so a release made today would show "Not available in this build" (operator decision 2). M5 must add the flag, after the `bundle-app.sh` backlog is closed |
```

- [ ] **Step 6: STATUS.md** — `**3 of 4 done:**` → `**4 of 4 done:**`; replace the "Next" sentence with `Deliverable 4: the helper's register/approval/unregister flow and the root-action buttons (vault folder, dyld cache), gated on a signed build — in every build made today they render "Not available in this build". Nothing of it has run live (#30).`; in "Next three actions" item 3, append `The client half now exists (permissions deliverable 4); the first signed build is what runs it.`; append a log section `## 2026-09-27 — user-first permissions, deliverable 4 of 4: the helper flow, gated` with tests, mutants (including M4-5's crash-kill wording and M4-6's gate), and the declared gaps. Update `docs/process/SESSION-HANDOFF.md`'s in-flight line to say the four deliverables are done.
- [ ] **Step 7: Freeze and review (P3)** — both reviewers.

helper-security-reviewer — scope: `Sources/XCodeVaultHelperClient/HelperClient.swift`, `Sources/XCodeVault/LiveHelper.swift`, `Sources/XCodeVault/XCodeVaultApp.swift`, `Package.swift`, `scripts/bundle-app.sh`, `scripts/public-surface.sh`, `Sources/XCodeVaultCore/Permissions/PrivilegedHelper.swift`. Focus: (1) `send` cannot talk to the helper without `connect()`'s requirement set before `resume()`; (2) only enum raw values and a UUID string cross the wire; (3) one connection per message, always invalidated; exactly one continuation resume; (4) nothing treats `.enabled` as authentication; (5) no root shell, no `osascript`, no `AuthorizationExecuteWithPrivileges` anywhere; (6) `forgetMountObservation` is not exposed by any client (its safety depends on an interactive confirmation naming the target); (7) the rewritten bundle-app.sh backlog is accurate against `HelperService.swift`; (8) `helper-invariants.sh` passes and the single-`NSXPCConnection` rule holds.

migration-safety-reviewer — scope: `Sources/XCodeVaultCore/Permissions/PrivilegedHelper.swift`, `Sources/XCodeVaultCore/Permissions/PrivilegeRequirement.swift`, `Sources/XCodeVaultCore/Clean/CleanPlanner.swift`, `Sources/XCodeVault/XCodeVaultApp.swift` (the Clean and Doctor views), `Tests/XCodeVaultCoreTests/PrivilegedHelperTests.swift`. Focus: (1) the dyld cache is emptied only after an explicit destructive confirmation, only when enabled, and never while Xcode, a simulator, `simctl` or `xcodebuild` runs (fail-closed); (2) only the exact cache path maps to the verb; (3) every run is journaled before acting and refused when the journal cannot be written; (4) a crash mid-call leaves a record that never suggests `migration abort` for the vault folder; (5) *experimental* stays on the dyld action everywhere it is shown; (6) nothing deletes non-regenerable data.

- [ ] **Step 8: Commit message**

```text
Helper: register/approval/unregister and the root-action buttons, gated on a signed build

Deliverable 4 of 4 of docs/superpowers/plans/2026-09-27-user-first-permissions.md.

HelperClient registers and unregisters the daemon through SMAppService, opens Login Items &
Extensions, and calls createVaultDirectory and removeRegenerableSystemDirectoryContents over one
validated connection per message (requirement before resume, one outcome via ResumeOnce, always
invalidated). Core decides when: HelperApprovalFlow (register -> open Settings -> poll -> enabled;
a register that throws into approval is not a failure; bounded; cancellable) and
PrivilegedActionRunner (only when enabled; journaled before acting; the dyld cache refused while
Xcode, a simulator, simctl or xcodebuild runs, fail-closed). The app shows a root action's button
only when HelperState.actionControl says so; a build that cannot reach the helper — every build made
today — says "Not available in this build" and shows the manual route. Permissions offers Install…
and Uninstall… (unregister). public-surface pins the runner's two safety defaults.

Never run live: register(), approval and the XPC calls are tested with fakes and recorded as pending
in COMPATIBILITY_MATRIX.md (#30). Whether the daemon has the Full Disk Access Caches/dyld needs is
unmeasured.

Tests: N executed, 0 failures. Mutants: 6 applied; 5 killed by assertions, 1 by a crash at the
intended guard (double resume); the public-surface gate caught the default swap.

Reviewed-by: helper-security-reviewer
Reviewed-by: migration-safety-reviewer
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

- [ ] **Step 9: P4**, then offer the operator a visual check of the app (Permissions section and a doctor finding rendering "Not available in this build"), as in Task 3.4 Step 5.

---

## Self-review (done while writing)

- **Spec coverage.** §1 → Tasks 1.1–1.6 (flipped in 2.9, 3.5, 4.6). §2 → 2.1 (FDA), 2.2 (HelperState, amended by operator decision 2), 2.3 (PrivilegeRequirement; `CleanAction` migrated, not duplicated), 2.5 (doctor structured action, operator decision 1; `sudo xcode-select` untouched). §3 CLI → 2.6; GUI → 3.3 (section, re-check on return, Full Disk Access at need) and 4.3 (sheet, register/open/poll/run, unsigned text, Uninstall). §4 → the tests in 2.x/3.x/4.x, `permissions --json` in cli-smoke (2.6), the three named mutants (M2-1, M2-2, M4-1) plus the rest, declared gaps (4.6), reviews (P3 per deliverable), preflight (P4). §5 → one deliverable per commit, in order.
- **Placeholders.** None, except the test count `N` in commit messages, which is measured at execution.
- **Type consistency.** `PrivilegeRequirement.coreSimulatorDyldCachePath`, `PrivilegedAction.createVaultDirectory(volumeUUID:)` / `.emptyCoreSimulatorDyldCache`, `HelperState(status:teamIDIsUsable:daemonIsBundled:)`, `HelperClient.hasUsableTeamID` / `bundlesDaemon`, `VaultDirectoryRefusal.{reasonKey,reason,volumeUUIDKey}`, `PermissionPrompts.shouldAskForFullDiskAccess(permissionDeniedCount:state:)`, `HelperState.actionControl` / `rowButton`, `PrivilegedActionRunner(helper:journal:isXcodeRunning:isSimulatorWorkRunning:)` are used with the same names and types in every task that consumes them.
