# ADR 0012: The app detects, evaluates and prepares external drives (R6)

- Status: accepted (the preparation options are **experimental**, CLAUDE.md rule 10)
- Date: 2026-10-04
- Related hypothesis: H17 (`diskutil` prepares a disk without `sudo`) — verified on disk images; on a physical USB disk `apfs addVolume` only (2026-10-04, R7-D), the others pending
- Brief: `.superpowers/sdd/r6/brief.md`

## Context

On 2026-10-04 the user asked for the app to "detect external devices (USB stick, external HD) and let the user pick the
destination when running externally", to "evaluate the device and offer options when needed (format to APFS, fix
permissions, etc.)", to "suggest a default directory structure and put it in the command", and for all of it to run
inside the app. On formatting they decided: **"Give the user the option, let them decide. If they want only one volume,
give them the option to create / configure that volume."**

This is the first time XCodeVault changes a disk's partition map or file system. Three rules in
`docs/product/NON_GOALS_AND_SAFETY.md` bear on it: the privileged helper exposes no generic disk verbs (CLAUDE.md rule
3); a disconnected or reconnected volume is a first-class failure mode (rule 6); and no destructive action is ever
automatic or presented as harmless.

## Decision

1. **Core decides everything** (`Sources/XCodeVaultCore/Drives/`). `DiskTopology` parses `diskutil list -plist`,
   `diskutil apfs list -plist` and one `diskutil info -plist` per whole disk; `DriveEvaluation` gives each external
   physical disk one verdict — Ready, Can be used, Needs preparation, Can't be used — and its options, least destructive
   first: add an APFS volume to an existing container, add an APFS partition in free space, erase one volume, erase the
   whole disk, and (no command) turn ownership on. The app draws what Core returns.
2. **One guard, `DiskSafety`, asked three times** (`DiskSafety.refusals(for:target:on:)`). No change of any kind on an
   internal disk, the boot disk, a disk image, a disk with a Time Machine volume (APFS role `Backup`, or a
   `Backups.backupdb` / `.timemachine` marker), or read-only media. No erase **and no new partition** on a disk holding a
   registered vault (any registered vault, usable or not, mounted or not): rewriting the partition map remounts the
   disk, and that remount is a rule 6 window in which the vault is not where it was (fix round 1, M3). Adding an APFS
   volume stays allowed on such a disk — it does not touch the map — and is how a case-sensitive vault (the user's own
   drive) gets the recommended case-insensitive `XCodeVault` volume. An unmounted HFS+ partition might be a Time
   Machine backup that cannot be checked: erasing it, or the whole disk, is refused until it is mounted. The options
   are computed through this function, `DiskPreparation.plan` asks it again, and `DiskPreparation.execute` reads the
   disks afresh and asks it a third time immediately before the command.
3. **Only commands E-diskprep proved run without `sudo`** are wired into Core (H17): `diskutil apfs addVolume` (with
   `-quota` as an option), `diskutil addPartition <after> APFS|"Case-sensitive APFS" <name> 0`, `diskutil eraseVolume`,
   `diskutil eraseDisk … GPT`. The argv is built from these four shapes only; the one user string in it is a validated
   volume name (no leading `-` or `.`, no `:` `/` or control characters). `-reserve` was inconclusive and is not offered.
4. **Anything that needs root is a copyable command, never run.** `sudo diskutil enableOwnership <volume>` is shown with
   **Copy Command**, beside **Show in Finder** (Get Info's "Ignore ownership on this volume", where Finder asks for the
   password). The app never asks for a password, adds **no helper verb** (rule 3 holds unchanged), and never retries a
   failed command with privileges: a failure is reported with the exact command for Terminal. Because H17 is verified on
   disk images only, this is also the route if a physical disk refuses a command.
5. **Destructive actions are never automatic.** An erase lists every volume it destroys with its used bytes, requires the
   disk's media name (whole disk) or the volume's name typed exactly, uses a destructive-styled button with Cancel as
   the default, and runs one command — nothing is chained after it. Core re-checks the typed name itself.
6. **Disconnect and identity (rule 6).** Before running, Core re-reads the disks and refuses unless the device id still
   names the same disk: media name, size, the sorted partition UUIDs and the sorted file-system UUIDs (partition volume
   UUIDs, APFS container and volume UUIDs) as previewed ("the disk changed"). The plan also records its target's own
   UUID and name; `revalidate` re-derives them, and the name the user typed, from the fresh disks and refuses if any
   changed — a volume deleted and re-added under the same device id is not the one confirmed (fix round 1, M2).
   **Residual case, stated honestly:** an MBR disk with no recognised file system (or a blank disk) has no partition or
   file-system UUID and is told apart by media name and size only; its erase stays offered, and the confirmation says
   "This disk can't be told apart from another of the same model."
   In the app, the sheet keeps the plan the user previewed (fix round 1, H1): mount and unmount events re-read the
   drives (debounced; an older read finishing late is dropped) and re-plan an open sheet, every re-plan clears the typed
   name, and if the new plan's disk identity or target differs from the previewed one the new plan is **not** swapped
   in — the sheet is blocked for good ("The disk changed. Close this and preview again.") and the run only ever uses the
   previewed plan. A drive that went away blocks it too, for good: whatever appears later under its id is not what was
   previewed (fix round 2, N4).
   The standard-folder mkdir (§8) checks identity too (fix round 2, N1): before creating it, the run refuses unless the
   vault verifies — mounted, its volume UUID, its sentinel — at the mount point the folder is under, and the vault
   directory is a real directory (no symlink) on that same volume; otherwise nothing is created.
   A window of milliseconds remains between those checks and the mkdir itself; it is accepted, as for the diskutil
   calls, and cannot be closed from user space.
7. **Journal and History.** Every run is journaled under the new kind `diskPreparation` (planned → started →
   completed/failed, with the command in its detail), including a refusal before running. History shows it.
8. **The vault layout is defined once** (`VaultLayout`): `<volume>/XCodeVault/{DerivedData,Archives,Runtimes}`.
   **Use This Drive** registers the volume with `VaultRegistry.register` (the same validations as `vault init`) and
   creates the folders; `vault init` now creates them too. A registration whose folders could not be made is a distinct,
   partial outcome ("Registered; the standard folders could not be created", with `OwnershipAdvice`); `vault init` exits
   3 for it. When the destination is a usable vault whose standard folder is missing (every vault registered before
   R6), the review says "Will create folder …" and the run's first step creates exactly that folder inside the vault
   directory, logged; a folder chosen with **Choose Another Folder…** is never created. The Run sheet's **Destination** lists ready vaults first and
   pre-fills the folder from the layout (Externalize Archives keeps the migration engine's own path); **Choose Another
   Folder…** stays as the override, and a folder on a network file system is refused. Network volumes are a blocker in
   `VolumeQualification`.
9. **The quit guard keeps every drive operation running** (`canBeStopped` false, its own explanation): `diskutil`
   stopped part-way through an erase or a map change leaves a disk nobody chose.
10. **Testing.** No test runs `diskutil` or `hdiutil`: parsing is tested from redacted fixtures (one taken from
    E-diskprep's own evidence), Core's runs from a recording fake, the app from scripted `DriveServices` and
    `OperationServices`. The experiment script itself is linted by a test: every mutating `diskutil` verb must go through
    its image-only guard.

## Consequences

- The app can now erase a user's disk. The safety argument is the guard (2), the identity re-check (6) and the typed
  name (5), all in Core and tested; the `migration-safety-reviewer` must review this change before merge.
- Physical-disk behaviour (H17): `apfs addVolume` was verified without sudo on the user's USB disk on 2026-10-04
  (macOS 26.7.1 · Intel, through the app); `addPartition`, `eraseVolume` and `eraseDisk` have disk-image evidence only.
  Every preparation option keeps the Experimental badge, and the manual procedure for the rest is in `HYPOTHESES.md` H17.
  The new volume came up with ownership ignored: the drive's recommended fix is then **Turn On Ownership** for it (Finder,
  or the copyable command), never another new volume (R7-D). Whether `diskutil` mounts a new volume under a name other than the one
  chosen ("XCodeVault 1") is not handled specially: the Drives screen re-reads and shows what is there.
- A blank disk with no mountable volume posts no mount notification; the drives are re-read on every scan and on
  **Check Again**.
- Finder's Get Info cannot be opened on a specific volume without Apple Events (an Automation prompt); the app reveals
  the volume in Finder and says which menu item to use instead.

## Evidence

- Disk images: E-diskprep, `docs/research/evidence/e-diskprep-macos26.7.1-25G241-xcode26.5-x86_64.txt` — every
  preparation command works without sudo (`COMPATIBILITY_MATRIX.md` "E-diskprep").
- Physical USB disk: `apfs addVolume` only, by the user through the app, 2026-10-04 (`COMPATIBILITY_MATRIX.md` "H17
  physical"). The new volume had Owners: Disabled. `addPartition`, `eraseVolume`, `eraseDisk`: disk images only.
