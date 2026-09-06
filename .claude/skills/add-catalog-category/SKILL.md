---
name: add-catalog-category
description: Add or change a storage category in the XCodeVault storage catalog (Sources/XCodeVaultCore/Catalog). Use when a new developer-storage path is discovered or a category's strategy changes.
---

# Adding a storage-catalog category

1. Read `docs/product/STORAGE_CATALOG.md` (model + corrections) and the existing entries in
   `Sources/XCodeVaultCore/Catalog/`.
2. Discover, don't assume: confirm the path exists on a real Xcode install, how it is created,
   whether it is a directory, a mount point, or a mount graft (`du -x` vs `du`), and who owns it.
3. Fill every required field: identifier, name, path template(s), owning subsystem,
   regenerability, deletion safety, relocation safety, recommended strategy, privilege level,
   macOS/Xcode version applicability, architecture notes, external-drive requirements,
   dependencies, rollback capability, verification procedure, risk level, and an **evidence**
   pointer (a matrix entry, a research finding F#, or an Apple doc URL).
4. No evidence pointer ⇒ the entry's strategy is `unverified` and must render as
   *experimental* everywhere (`isExperimental == true`).
5. Forbidden strategies are compile-time facts: never `symlinkRelocation` for
   `~/Library/Developer`, its `CoreSimulator`, or `DeveloperDiskImages`; never anything that
   modifies `/System`.
6. Add a unit test for discovery (fixture directory tree) and for the strategy/labeling rules.
7. Update `docs/product/STORAGE_CATALOG.md` if the category list changed.
