# XCodeVault user guide

What each part of XCodeVault shows or changes on your Mac, and how to undo what it changes. What
the project is, and how far along it is, is in the [README](../README.md).

Commands are written `xcodevaultctl …`; from a source build that is `.build/debug/xcodevaultctl …`.
Every read command accepts `--json`.

## Permissions: which, when, why, and how the app asks

By design ([ADR-0007](adr/0007-permissions-asked-at-need.md)), XCodeVault asks for a permission only
at the moment an action needs it; the last column of the table says what this build does. Nothing is
asked for up front: the first run scans, shows, and changes nothing, and asks for Full Disk Access only
if that scan was refused. XCodeVault never asks for your password
itself, never runs `sudo`, and never opens a root shell. Where macOS allows it, asking means one
system prompt, not a command for you to paste.

| Permission | Asked for when | Why | How XCodeVault asks | In this build |
|---|---|---|---|---|
| **Full Disk Access** | A scan could not read some folders because macOS privacy protection refused it, or could not fully read a size | Those folders' sizes are missing from the totals until it is granted | It opens System Settings ▸ Privacy & Security ▸ Full Disk Access. You switch it on; when you come back, the app notices and scans again. Code cannot grant this permission, so the app never tries | `xcodevaultctl permissions` reports it. The app asks when a scan was refused, and its Access screen shows the state (built and unit-tested; not yet exercised on screen) |
| **Privileged helper** — a background item that runs as root | You choose an action that needs root: creating the vault folder on a drive whose top folder belongs to root, or emptying the CoreSimulator dyld cache (experimental) | Those paths belong to root. The helper can do only a fixed list of actions, on paths it resolves itself | A one-sentence sheet with **Allow**. macOS then asks you to approve the helper once, in System Settings ▸ General ▸ Login Items & Extensions, with an administrator password — macOS's prompt, not XCodeVault's | Not available in any build made today: it needs a signed build that includes the helper (issue #30), and it has never run live. Until then the app's helper row says "Not in this build" and shows what to do instead: it needs a signed build that includes the helper, and none is released yet; where there is a manual route, `vault init` and `doctor` print the command for the vault folder; the dyld cache stays listed, not cleaned |

Three details that are easy to get wrong:

- **Full Disk Access is granted per app.** For `xcodevaultctl`, macOS decides by the app you run it
  from — usually your terminal — so that is the one to switch on: H15 recorded a grant to one
  terminal app that did not reach a process started another way. For `XCodeVault.app` itself this
  is unmeasured: no signed build has been made.
- **The tools an app starts work inside its grant** — the same rule that makes your terminal's grant
  reach the commands you run in it (H15). `XCodeVault.app` starts system tools, and the developer tools
  `xcrun` resolves for the Xcode chosen with `xcode-select` — through `xcrun`'s own per-user cache, which
  it trusts as every developer tool does. It ignores `DEVELOPER_DIR`, `TOOLCHAINS` and `SDKROOT`.
  `xcodevaultctl` keeps your environment: it is your terminal's grant, and your choice. Neither runs
  anything from another copy of Xcode it finds, only from the one `xcode-select -p` names: the others
  are read, not run (ADR-0009).
- **Whether the helper itself needs Full Disk Access is unmeasured.** Emptying the dyld cache needed
  root *with* Full Disk Access when it was measured from a terminal (H15). The helper runs as a
  launchd daemon, which is a different context, and it has never run live (issue #30).

Nothing else is requested. macOS itself may ask about removable volumes the first time an app
touches one — a system category with no API to check or request it in advance. Whether macOS asks
this of XCodeVault has not been observed or measured.

## The app

The app shows the same numbers and runs the same checks as the command line, in the language macOS uses for it
(English, Brazilian Portuguese, Spanish, Japanese or Simplified Chinese; every translation except English is still
awaiting native review). Rescan with ⌘R. The sidebar has two groups: **Save space** — what you can reclaim, and how —
and **Details** — everything the scan, the doctor and the journal recorded. **Back** (⌘[) in the toolbar returns to the
screen you were on before — after **Review** on an Overview card, or a click in the sidebar — like a browser's Back.

### Save space

**Overview** draws the internal disk as one bar: other data, developer data split by the way each item can be
reclaimed, and free space. Under it are three cards, one per way of reclaiming space, each with an "up to" amount (or, when some folders could not be read, "at least"), how
much of it uses verified strategies, what it promises, what undoing it costs, and **Review**, which opens that way's
view. The cards are alternatives for the same files — DerivedData, for example, can be deleted *or* moved — so they
overlap; the total under them counts each file once. The bar counts each item once too, under its main option.
Simulator runtime images that `simctl` measured but the catalog does not count yet are on their own line. The Overview
also shows at most one access row (see [How access is asked for](#how-access-is-asked-for)), scan warnings, and doctor
findings of error severity or worse.

What each way costs to undo:

| Way | What it frees | Cost to undo | In the app |
|---|---|---|---|
| **Delete — comes back on demand** (Temporary) | Space now; it grows back as Xcode rebuilds or downloads it again | Rebuild or re-download time. Simulator devices are the exception: deleting one deletes its apps and their data, and they do not come back | **Delete** deletes the rows you select (see below) |
| **Park on an external drive** (Temporary) | Space until you bring it back: a verified copy waits on your vault drive | Copy it back when you need it — no download | **Park** shows the commands; **Run…** runs them in the app (see [Running a command from the app](#running-a-command-from-the-app)) |
| **Run from an external drive** (Permanent) | Space for good: the data lives on the external drive and stops growing on this Mac | Nothing to download, but the drive must be connected while you work | **Run externally** shows the commands; **Run…** runs them in the app |

Everything that stays on this Mac — Archives among it, which nothing here ever offers to delete — is counted in the
bar, never in a card.

| View | What it shows | What it changes | How to undo |
|---|---|---|---|
| Delete | The cleanup plan — regenerable data only, grouped by category, with the cost to undo each row and its markers (*experimental*, and what a row lacks when it needs root). Select rows, then **Delete Selected…**; the confirmation shows the exact count. Above the table, the helper's row when a row needs root. Below it, in one panel folded by default (open when the table is empty): the planner's warnings, the CoreSimulator dyld cache (*experimental*) with its own control, the rows another tool deletes (simulator devices and runtimes) with **Copy Command** — and, for runtimes, **Run…** — and what the planner skipped, and why | Deletes the selected rows, or moves them to the Trash (the default). Simulator device sets (XCTest devices, Playground devices, SwiftUI Preview data) are first emptied with `simctl --set … delete all`, so only their emptied folder reaches the Trash. Rows that need root are never deleted by **Delete Selected…**. The dyld cache needs the privileged helper and its own confirmation. The rows another tool deletes are never deleted by **Delete Selected…**: **Copy Command** puts the command on the clipboard, and you run it — or, for a runtime, **Run…** runs `runtime delete` in the Run sheet | From the Trash, before you empty it — except those simulator devices, which are gone once `simctl` deletes them, and the dyld cache, which the helper deletes outright. Otherwise Xcode regenerates the data — see [Why did the space come back?](#why-did-the-space-come-back) |
| Park | The categories that can be parked, each with its size, markers, the command, **Copy Command** and **Run…**, and the vault drive's state: none registered, not connected, connected but not usable, or ready. A migration that was interrupted shows a banner with the commands that recover it | **Copy Command** copies the command for Terminal. **Run…** opens the Run sheet (below): Archives are copied to the vault and verified, the originals kept; a runtime is offloaded (deleted here, its installer kept on the drive) | Archives: nothing to undo until you remove the originals, a separate step. Runtime: import its installer again |
| Run externally | The categories that can run from an external drive, with the same rows | DerivedData and Archives: Xcode's folder setting, with **Undo**. Runtime Library: exports an installer | **Undo** in the sheet resets Xcode to its default folder; an exported installer is a file you can delete |

### Running a command from the app

**Run…** opens a sheet in three steps. Every step goes through the same Core code as the command line, and everything
it changes is journaled and shows in History.

1. **Review.** The choices the command line took as flags are controls: the vault (the only ready one is chosen for
   you), a folder (always chosen in a folder panel), the runtime, the platform, and for DerivedData the checkbox "I
   understand that unit tests may fail for projects built there" (`--i-understand-tests-may-fail`). The sheet shows
   where the data comes from and goes, its size, what undoing it costs, Core's warnings, and the experimental badge
   where the strategy is experimental. Anything that stops it — Xcode running, the vault offline, too little space, no
   installer in the library yet, and for an offload or a runtime deletion a simulator, `simctl` or a test run still
   running — disables the button and says why; **Check Again** reviews it again once that has changed. For an offload
   whose library has no installer,
   **Export Installer First** runs the export in the same sheet and comes back to the offload.
2. **Confirm.** One button whose title is the exact action, such as "Copy 18 GB of Archives to the vault PABLO". When
   it deletes something on this Mac it is styled as destructive and is not the default: Return cancels.
3. **Running.** The stage (checking, copying, verifying, deleting, exporting, applying), a progress bar — measured
   while copying to the vault, otherwise moving without a measure (an export shows only the time elapsed: whether its
   folder grows during the download has not been measured) — and the time elapsed. **Show Details** opens the live
   log: each command as it runs and everything it prints, following the newest line while **Follow output** is on.
   **Copy Log** copies it; the whole log is also kept in a file whose path the sheet shows, also after it ends. It
   cannot be stopped from the app once it starts, and there is no rescan while it runs. Quitting depends on what it is
   doing: while it copies, verifies or removes an original, exports an installer or offloads a runtime, the app offers
   only **Keep Running** — stopping there would leave a half-written copy, an export nobody has tested stopping, or an
   offload whose runtime may already be gone while its record says it failed. While it deletes a runtime (Delete) or
   changes a folder, **Stop and Quit** stops the command, waits for it to end, records the
   operation as failed, and then quits.

When it ends the sheet says what happened, with **Show in History**. After Archives are copied and verified, **Remove
Original…** frees their space on this Mac: it needs the checkbox "I confirm deleting non-regenerable data (Archives)"
and a confirmation, compares the original with the vault copy again, and deletes nothing if they differ. **Remove
Original…** is offered only in this sheet: once you close it, the originals stay where they are, and neither the app
nor `externalize` removes them later (`externalize` refuses because the vault copy already exists) — delete them
yourself once you have checked the vault copy, or keep both. After a folder change, **Undo** puts back the folder Xcode used before, or resets it to the default when it
used the default; the button says which. If a copy fails, the originals are untouched; when part of the copy may still
be on the vault, the sheet and the banner give the `migration abort <id>` command that removes it. One operation runs
at a time. Restoring from the vault, and resuming or aborting an interrupted migration, are still command-line only:
the banner gives the commands.

### Details

| Screen | What it shows | What it changes |
|---|---|---|
| Storage | A chart of the size in each way of reclaiming, for items on all drives (its symbol, name and size; each item counted once, so a per-device breakdown and a symlink are listed but not added). Click a bar to show only that bucket's rows; the **Bucket** menu does the same without a pointer; a chip names the filter, and its × or **All** clears it, as does clicking the bar again. The Overview's bar counts only the internal disk, so its amounts can be smaller. Below it, every storage item the scan found, largest first, sortable by any column: size, the way of reclaiming it is counted under (its symbol and name), category, outcome, strategy and path; symlinks and mount points flagged | Nothing |
| Simulators | A chart of every measured runtime and device, coloured and marked by kind (runtime or device) and labelled by name; one not measured has no bar, and a line under the chart says how many. Click a bar to select its row in the table below and scroll to it. Then the installed simulator runtimes, largest first, with their total; the simulator devices with the size of their data, the runtime each one runs (iOS, watchOS, tvOS, visionOS and its version), and their total — each device's data folder as `simctl` reports it, so it can differ from the Delete view's "Simulator devices" row, which measures the whole `Devices` folder. A size the scan did not measure says "not measured". Both tables sort by any column | Nothing: runtimes and devices are deleted with `simctl`, whose commands the Delete view lists |
| Drives | One row per drive — the running system's System and Data volumes as one "Internal disk (boot)" row — with whether it qualifies as a vault (blockers shown, warnings folded behind their count) and, on a registered vault's own row, its state as a badge. Each drive whose size was measured has a bar of its space: other data, the developer data the scan found on it by way of reclaiming, and free space, with a legend that names each part and its size. On a vault the bar shows what the scan found there; XCodeVault's records keep no sizes of what was placed on it. Registered vaults that are not connected have a section of their own | Nothing; registering a vault is `xcodevaultctl vault init` |
| Health | A line of counts by severity ("1 warning · 3 info"), then one card per doctor finding, most severe first, then largest: the severity as a symbol and a word, the title, one short sentence, the size when the finding has one, and the fix — or, where the privileged helper can fix it (the vault folder a drive refused), its control. **Details** unfolds the full explanation, the per-device sizes, why `clean` does not offer it, the whole fix, the path and the evidence. The findings' own text stays English | Nothing by itself: the doctor proposes, it never applies a fix. The control, where it is a button, creates the vault folder through the helper; remove the folder if you no longer want it |
| History | One row per operation — not one per journal record — grouped by the day it started (Today, Yesterday, then the date), newest first, the newest 100: the time, a badge for its kind (a symbol, a color and a short name: Cleanup, Runtime deleted, Runtime parked, Runtime export, Runtime import, Migration, Xcode location, Privileged helper, Other), its state as a symbol and a word (Completed, Failed, Interrupted, Rolled back, Skipped, Planned — recorded but never started), the summary — whole in its tooltip, with how it ended — and the size when one was recorded. **Interrupted** means the journal records a start and no end, as `xcodevaultctl doctor` counts it; an operation another `xcodevaultctl` is running at that moment shows so too until it ends. A failed or interrupted row shows how it ended under its summary; every step of an operation, such as which path a
cleanup could not delete, is in `xcodevaultctl journal`. **Kinds** hides kinds; **Show all** brings them back. The
summaries are the journal's own English | Nothing |
| Access | One row per permission — Full Disk Access and the privileged helper — each with its state as a symbol and a word, one sentence of why, and one button | See below |

### How access is asked for

Access is asked for where it matters, and in one place you can always open: the **Access** screen. The Overview shows
the one row that holds back something the scan measured — Full Disk Access when folders could not be read, the helper
when rows only root can delete wait on it and this build can reach it — and the Delete view shows the helper's row above its table when a row in it
needs root. Each row has one button: **Open Full Disk Access Settings** (or **Check again** when the check could not
tell), and **Install the Helper…** or **Approve in System Settings…** for the helper; once the helper is enabled, Access
offers **Uninstall…**, with a confirmation. **Open Full Disk Access Settings** first makes one attempt to open a folder macOS
guards with Full Disk Access (`~/Library/Safari`; it reads nothing), which should put XCodeVault in the pane's list,
then opens System Settings ▸ Privacy & Security ▸ Full Disk Access. XCodeVault should now be in the list — turn its
switch on. If it isn't there, add it with **+** (that step is not yet verified on every macOS version; H16). Whenever
you come back to the app it checks again and updates the Access row, the banner and the Overview; it rescans once if Full
Disk Access was just granted — if macOS asks you to quit and reopen XCodeVault, do so. A build you made yourself (ad hoc
signed, not a release) may appear in the list under its path, such as `…/XCodeVault.app`, rather than under its name and
icon; it is the same app. **Install the Helper…**
registers the helper and opens Login Items & Extensions, where you approve it. In a build that cannot reach the helper —
every build made today — its row says "Not in this build" and, instead of a button, a condition: the helper needs a signed
build that includes it, and none is released yet (issue #30); where there is a manual route, run the step that
`xcodevaultctl doctor` or `xcodevaultctl vault init` prints. In such a build the Overview does not show the helper's row:
it stays on the Access screen and above the Delete table, with the bytes it holds back. To undo, switch the permission
off in System Settings; for the helper, **Uninstall…**.

## The command line

### Read-only commands

These never change anything.

| Command | What it shows |
|---|---|
| `status` | A quick summary, without measuring sizes |
| `scan` | Every storage category, measured |
| `report` | `scan` plus doctor findings, with your home folder, account name, volume names and volume UUIDs redacted — made to paste into an issue |
| `doctor` | Unsafe or broken setups, with the proposed fix where there is one; exits 2 when one is an error or worse |
| `compatibility` | Every category with its strategy, evidence status and privilege level |
| `permissions` | The Full Disk Access state and the helper state, each with why and one next step. Changes nothing |
| `volumes` | Mounted volumes and whether each qualifies as a vault |
| `xcode list` | Installed Xcodes, and what the selected one supports; for the others it says their capabilities were not probed |
| `runtime list` | Installed runtimes |
| `runtime library --dir <dir>` (*experimental*) | The installers in a Runtime Library folder, and whether each installed runtime has one |
| `locations show` | Xcode's DerivedData, Archives and compilation-cache locations |
| `journal` | The last 50 journal entries by default (`--last N`): every change XCodeVault made, and any interrupted operation |
| `vault status` (*experimental*) | Registered vault volumes, and whether each is verified |
| `migration status` (*experimental*) | Interrupted migrations and leftover partial copies |

The *experimental* rows read the state of an experimental strategy (the Runtime Library, vaults and
migrations), so their help carries the label too.

`bench <dir>` does not touch your data, but it writes and then removes a temporary 256 MB file in `<dir>`.

### Commands that change your Mac

Each one is recorded in the journal, except `vault forget`, which only edits XCodeVault's registry.
No strategy has met the Definition of Done in [`NON_GOALS_AND_SAFETY.md`](product/NON_GOALS_AND_SAFETY.md)
yet, so every command below is *experimental* except `runtime delete` (Apple's own
`simctl runtime delete`) and the `locations reset-*` commands, which return to Xcode's default.

The `runtime` commands work with the Xcode `xcode-select -p` names (`DEVELOPER_DIR` steers it). With
none selected they refuse rather than pick another copy of Xcode.

| Command | What it changes | How to undo |
|---|---|---|
| `clean --apply` (`--trash` to move to the Trash instead) (*experimental*) | Deletes the planned regenerable paths. Without `--apply` it only prints the plan. Simulator device sets are first emptied with `simctl --set … delete all`. Root-owned rows are never deleted by `clean` | With `--trash`: restore from the Trash before emptying it — except simulator device sets, whose devices `simctl` has already deleted. Otherwise: none; Xcode regenerates the data |
| `locations set-derived-data <path>`, `set-archives <path>`, `set-compilation-cache <path>` (*experimental*) | Xcode's own Locations setting. No file is moved. DerivedData or the compilation cache on an external drive needs `--i-understand-tests-may-fail` (E2) | `locations reset-derived-data`, `reset-archives`, `reset-compilation-cache` return to Xcode's default; a previous custom location is in the journal |
| `runtime delete <id> --yes` | Deletes an installed simulator runtime through `simctl runtime delete` | Install it again (Xcode ▸ Settings ▸ Components), or `runtime import` an installer you exported |
| `runtime export <platform> --to <dir>` (*experimental*) | Downloads a runtime installer into `<dir>` | Delete the file |
| `runtime import <dmg>` (*experimental*) | Installs a runtime from an installer | `runtime delete` |
| `runtime offload <id> --library <dir> --yes` (*experimental*) | Deletes an installed runtime, only if its installer is already in the Runtime Library | `runtime import <installer>`. Devices came back after re-import in the two round trips measured, on one configuration and at the same version; a cross-version import has never been tried |
| `vault init <mount>` (*experimental*) | Creates `<mount>/XCodeVault` — or the folder `--directory` names, with any folder missing on the way to it — and a sentinel file, and records the volume | `vault forget <uuid>`. The folder stays on the volume, as do folders created on the way to it; delete it yourself only if it holds nothing but `.xcodevault-volume.json` — `externalize` copies into it, and after `--remove-source-after-verify` that copy is the only one |
| `vault forget <uuid>` (*experimental*) | Removes the volume from XCodeVault's registry. Nothing on the volume is touched, and nothing is journaled | `vault init` again |
| `externalize --category archives --vault <ref> --apply` (*experimental*) | Copies Archives to the vault and verifies the copy. The originals stay unless you also pass `--remove-source-after-verify --i-confirm-deleting-non-regenerable-data` | If the originals were kept (the default): delete the vault copy under the vault folder's `archives/` — `restore` refuses while the original exists. If you removed them: `restore` |
| `restore --category archives --vault <ref> --name <entry> --apply` (*experimental*) | Copies a vault entry back; never overwrites | Delete the restored copy |
| `migration abort <id>` (*experimental*) | Removes the partial copy of a migration interrupted before verification — on the vault for `externalize`, at the local destination for `restore`. The source is never touched | — |
| `migration resume <id>` (*experimental*) | Finishes a cleanup interrupted after verification: re-verifies, then removes the original — or restores it if the two differ. Archives need `--i-confirm-deleting-non-regenerable-data` | `restore` — the vault copy is kept |
| `migration forget <id> --i-verified-both-copies-myself` (*experimental*) | Clears the journal entry only, after you compared both copies yourself; no file is touched | — |

## FAQ

### My external drive was disconnected. What now?

XCodeVault identifies a vault drive by its UUID and a sentinel file, never by its name, and refuses
to act on a vault that is not connected. What was measured is a forced unmount in the middle of a
migration (E6, software variant, one machine): the failure was clean and journaled, and the source
was never touched. A physical unplug has not been measured yet (H3). `doctor` reports what a
disconnection leaves behind:

- **Vault volume … is not connected** — connect it before using `externalize` or `restore`.
- **Shadow data at …** — the drive is not connected, and a folder with files in it sits where it
  was last mounted. **Possible shadow data at …: it could not be read in full** means XCodeVault
  could not read all of that folder, so it cannot tell what is in it: inspect it as a user who can
  read it, and do not delete it unread. Either way, reconcile it before reconnecting the drive;
  until then XCodeVault refuses to act on that vault.
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
- CoreSimulator dyld caches (listed by `clean`, never deleted by it): on the one machine measured,
  the caches for installed runtimes were rebuilt within an hour after a macOS update (H11). No cache
  deleted by hand has been seen rebuilt, and what triggers a rebuild is not identified (H14).

### Why is this greyed out, or why is there no button?

- **Delete Selected… is disabled**: no row that `clean` may delete is selected. Rows that need root
  do not count; their marker in the **Markers** column says what they lack.
- **A row says it needs root, or the helper says "Not in this build"**: XCodeVault's only route to root is
  its privileged helper, and this build cannot reach it — no build made today can (see
  [Permissions](#permissions-which-when-why-and-how-the-app-asks)). The app never shows a button that
  cannot work: it shows the manual route instead, where one exists. With a build that can reach the
  helper, the same place shows a button that asks for it at that moment.
- **Rescan is disabled**: a scan is already running.
- **Everything is labelled experimental**: no strategy has met the Definition of Done yet, and the
  label stays until one does.

### I built XCodeVault from `main` between 2026-09-18 and 2026-09-28. Should I check anything?

Only if you ran one of the commands below while Xcode was open. In builds from those days, the check
for a running Xcode read only the first few dozen processes the system listed, so it could answer "not
running" with Xcode open. It was fixed on 2026-09-28. There has been no release, so no release has it.

- **`clean` of DerivedData or previews**: a build running at the time may have failed. The next build
  starts from scratch; nothing needs checking.
- **`externalize … --remove-source-after-verify`, or `migration resume` finishing a removal**: Xcode
  may have been writing into the original while it was removed. The copy is verified again after the
  original is moved aside, which catches what was written before that moment, not during the deletion.
  Run `xcodevaultctl doctor` and `xcodevaultctl migration status`, and look for anything you made in
  Xcode during the removal — in the vault copy and at the original location.
- **`locations set-*` or `reset-*`**: Xcode keeps these settings in memory and may write its old value
  back when it quits. Run `xcodevaultctl locations show`, and set them again if they are not what you
  chose.
