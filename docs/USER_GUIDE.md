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
| **Full Disk Access** | A scan could not read some folders because macOS privacy protection refused it | Those folders' sizes are missing from the totals until it is granted | It opens System Settings ▸ Privacy & Security ▸ Full Disk Access. You switch it on; when you come back, the app notices and scans again. Code cannot grant this permission, so the app never tries | `xcodevaultctl permissions` reports it. The app asks when a scan was refused, and its Permissions section shows the state (built and unit-tested; not yet exercised on screen) |
| **Privileged helper** — a background item that runs as root | You choose an action that needs root: creating the vault folder on a drive whose top folder belongs to root, or emptying the CoreSimulator dyld cache (experimental) | Those paths belong to root. The helper can do only a fixed list of actions, on paths it resolves itself | A one-sentence sheet with **Allow**. macOS then asks you to approve the helper once, in System Settings ▸ General ▸ Login Items & Extensions, with an administrator password — macOS's prompt, not XCodeVault's | Not available in any build made today: it needs a signed build that includes the helper (issue #30), and it has never run live. Until then the app says "Not available in this build" and shows the manual route where there is one: `vault init` and `doctor` print the command for the vault folder; the dyld cache stays listed, not cleaned |

Three details that are easy to get wrong:

- **Full Disk Access is granted per app.** For `xcodevaultctl`, macOS decides by the app you run it
  from — usually your terminal — so that is the one to switch on: H15 recorded a grant to one
  terminal app that did not reach a process started another way. For `XCodeVault.app` itself this
  is unmeasured: no signed build has been made.
- **The tools an app starts work inside its grant** — the same rule that makes your terminal's grant
  reach the commands you run in it (H15). `XCodeVault.app` starts system tools, and the developer tools
  `xcrun` resolves for the Xcode chosen with `xcode-select` — through `xcrun`'s own per-user cache, which
  it trusts as every developer tool does. It runs nothing from other copies of Xcode it finds, and
  ignores `DEVELOPER_DIR`, `TOOLCHAINS` and `SDKROOT`. `xcodevaultctl` keeps your environment: it is
  your terminal's grant, and your choice.
- **Whether the helper itself needs Full Disk Access is unmeasured.** Emptying the dyld cache needed
  root *with* Full Disk Access when it was measured from a terminal (H15). The helper runs as a
  launchd daemon, which is a different context, and it has never run live (issue #30).

Nothing else is requested. macOS itself may ask about removable volumes the first time an app
touches one — a system category with no API to check or request it in advance. Whether macOS asks
this of XCodeVault has not been observed or measured.

## The app

The app shows the same numbers and runs the same checks as the command line. Rescan with ⌘R.

| Section | What it shows | What it changes | How to undo |
|---|---|---|---|
| Overview | Internal disk used by developer tooling; how much is cleanable or relocatable; warnings; doctor issues of error severity or worse; when a scan was refused by macOS privacy protection, **Open Settings** for Full Disk Access | Nothing | — |
| Storage | Every storage category present on this Mac, with size, outcome, strategy and path; symlinks and mount points flagged | Nothing | — |
| Doctor | Unsafe or broken setups, with the proposed fix where there is one. A finding that the privileged helper can fix — the vault folder a drive refused — also has a button, or "Not available in this build." while this build cannot reach the helper | Nothing by itself: doctor proposes, it never applies a fix. The button, where there is one, creates the vault folder through the helper | Remove the folder it created, if you no longer want it |
| Clean | The cleanup plan — regenerable data only, largest first, every category labelled experimental. Select rows, then **Delete selected…**; the confirmation shows the exact count | Deletes the selected rows, or moves them to the Trash (the default). Simulator device sets (XCTest devices, Playground devices, SwiftUI Preview data) are first emptied with `simctl --set … delete all`, so only their emptied folder reaches the Trash. Rows that need root are never deleted by **Delete selected…**; the **Needs** column says what they lack. The CoreSimulator dyld cache (*experimental*) has its own button, which needs the privileged helper and a confirmation | From the Trash, before you empty it — except those simulator devices, which are gone once `simctl` deletes them, and the dyld cache, which the helper deletes outright. Otherwise Xcode regenerates the data — see [Why did the space come back?](#why-did-the-space-come-back) |
| Volumes | Mounted volumes, whether each qualifies as a vault, and the state of registered vault volumes | Nothing; registering a vault is `xcodevaultctl vault init` | — |
| Runtimes | Installed simulator runtimes | Nothing | — |
| Journal | The last 100 journal entries | Nothing | — |
| Permissions | The Full Disk Access and helper states, each with why and one control: **Open Settings** for Full Disk Access; **Install…** or **Uninstall…** for the helper — or, while this build cannot reach it, the manual route | Nothing by itself. **Open Settings** opens System Settings; when you come back, the app checks again and rescans — if macOS asks you to quit and reopen XCodeVault, do so. **Install…** registers the helper and opens Login Items & Extensions, where you approve it; **Uninstall…** removes the registration. Both need a signed build that includes the helper, and none exists yet | Switch the permission off in System Settings; for the helper, **Uninstall…** |

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
| `xcode list` | Installed Xcodes and what each supports |
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

| Command | What it changes | How to undo |
|---|---|---|
| `clean --apply` (`--trash` to move to the Trash instead) (*experimental*) | Deletes the planned regenerable paths. Without `--apply` it only prints the plan. Simulator device sets are first emptied with `simctl --set … delete all`. Root-owned rows are never deleted by `clean` | With `--trash`: restore from the Trash before emptying it — except simulator device sets, whose devices `simctl` has already deleted. Otherwise: none; Xcode regenerates the data |
| `locations set-derived-data <path>`, `set-archives <path>`, `set-compilation-cache <path>` (*experimental*) | Xcode's own Locations setting. No file is moved. DerivedData or the compilation cache on an external drive needs `--i-understand-tests-may-fail` (E2) | `locations reset-derived-data`, `reset-archives`, `reset-compilation-cache` return to Xcode's default; a previous custom location is in the journal |
| `runtime delete <id> --yes` | Deletes an installed simulator runtime through `simctl runtime delete` | Install it again (Xcode ▸ Settings ▸ Components), or `runtime import` an installer you exported |
| `runtime export <platform> --to <dir>` (*experimental*) | Downloads a runtime installer into `<dir>` | Delete the file |
| `runtime import <dmg>` (*experimental*) | Installs a runtime from an installer | `runtime delete` |
| `runtime offload <id> --library <dir> --yes` (*experimental*) | Deletes an installed runtime, only if its installer is already in the Runtime Library | `runtime import <installer>`. Devices came back after re-import in the two round trips measured, on one configuration and at the same version; a cross-version import has never been tried |
| `vault init <mount>` (*experimental*) | Creates `<mount>/XCodeVault` and a sentinel file, and records the volume | `vault forget <uuid>`. The folder stays on the volume; delete it yourself only if it holds nothing but `.xcodevault-volume.json` — `externalize` copies into it, and after `--remove-source-after-verify` that copy is the only one |
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

- **Delete selected… is disabled**: no row that `clean` may delete is selected. Rows that need root
  do not count; the **Needs** column says what they lack.
- **A row says it needs root, or "Not available in this build"**: XCodeVault's only route to root is
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
