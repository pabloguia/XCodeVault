# ADR 0015: The vault folder is named by the user, one vault per volume per Mac

- Status: accepted (EXPERIMENTAL with the rest of the drive flow — rule 10)
- Date: 2026-10-08
- Related: ADR-0012 (drives), ADR-0014 (ownership), H18 (the side finding that led here)

## Context

A vault was always `<volume>/XCodeVault`. Two things were wrong with that:

1. With the drive's volume also named `XCodeVault` (the preparation's suggested name), the path read
   `/Volumes/XCodeVault/XCodeVault`.
2. A drive shared by two Macs would give both the same folder. `VaultRegistry.register` wrote its sentinel over whatever
   sentinel was there, so the second Mac silently took over the first one's vault.

The user's scenarios: several drives on one Mac (B), and one drive shared by several Macs, one folder each (C). A third —
several vaults on one drive for one Mac — was offered and not chosen.

## Decision

1. **The folder name is suggested (`Vault`) and editable**, in the Drives row and the Plan before ownership is turned on,
   and in **Use This Drive**. One field, `AppModel.vaultFolderName`, feeds all of them. `VaultFolderName.problem` decides
   what is a folder's name: one component, no `/` `:` or control characters (checked on bytes), no `.` `..`, no space at
   either end, at most 200 bytes, and none of the names macOS keeps (`.Spotlight-V100`, `.fseventsd`, …).
2. **Identity stays the volume UUID.** A Mac has at most one vault per volume; several drives are several vaults. Nothing
   in the registry's shape, the picker, the verifier or the doctor changes, and no registered vault is migrated: a vault
   already registered keeps its `relativeDirectory`, and an old registry decodes to `XCodeVault`, as before.
3. **The helper is untouched.** Its one folder name, `XCodeVault` (`VaultDirectory.name`), stays; the app now creates the
   folder itself while the drive is still the user's to write (`VaultFolderPrecreate`), so the helper's
   `createVaultDirectory` is only offered for that legacy name (`DriveRegistration.vaultFolderHelperStep`).
4. **A sentinel already in the folder is never overwritten.** The sentinel records a hash of the writing Mac's hardware
   identifier (`HostFingerprint`; not a secret, not an identity proof). `register` adopts a sentinel of this volume and
   this Mac (or from before the field existed), and refuses one of another Mac, of another volume, or one it cannot read,
   with "Nothing was written; choose another folder name". `VaultFolderPrecreate` refuses the same folder before ownership.

5. **A typed name is never made a vault over files in use.** The app's path (Use This Drive, its preview, and the precreate)
   uses a folder only when it is absent, empty (Finder's `.DS_Store` aside) or already this Mac's vault; otherwise it blocks
   with "choose another folder name". The CLI's `--directory` keeps its earlier behaviour.
6. **A sentinel is created exclusively** (a temporary file, then `link(2)`), so two Macs claiming a name at once cannot
   replace each other. If this Mac cannot be identified (`gethostuuid` fails) a new sentinel is not written.

## Consequences

- Several vaults on one drive for one Mac are **not** supported (the registry is keyed by volume). If they are wanted, the
  identity becomes (volume UUID, folder) and every consumer of `volumeUUID` as a vault id changes: about 18 source files.
- Two Macs that chose the same name find out when the second tries to register, not by corrupting the first.
- A folder made by an older version of this build under another Mac's name has no host recorded and is adopted by whoever
  registers it first. That is the price of not breaking vaults registered before this decision.
- An adopted legacy sentinel is not stamped with the host, so two Macs can end up sharing its `sentinelID`.
- A drive already registered under one folder cannot be registered again under another name without `vault forget`.
- The CLI's `vault init --directory` now defaults to `Vault` and keeps accepting a nested path.
