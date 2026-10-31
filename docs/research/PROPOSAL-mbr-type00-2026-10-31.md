# Proposal: the type-00 MBR entry `diskutil` cannot see (STATUS open item 6)

_Research only, 2026-10-31 overnight session. Nothing is implemented; the operator decides._

## What was measured

Evidence: `docs/research/evidence/e-mbr-type00-from-image-file-macos26.7.1-25G241-x86_64.txt`.

- On a raw image whose MBR holds a type-`0x00` entry with a real extent beside a FAT32 one, `diskutil list` shows
  only the FAT32 partition (`disk9s2`). The type-00 entry has no node, so the erase confirmation of #63 cannot
  name it, and erasing such a disk lists nothing for it.
- The four MBR entries can be read from the image **file** by the user, with no privilege (`bytes 446–509`).
- For an image the user attached, `/dev/rdiskN` is owned by that user and readable too.
- A physical disk's node is `root:operator` (`crw-r-----`): not readable without root. The case #63 is about — a
  USB disk — is therefore **not** reachable this way. Only disk images are.

## Options

1. **Nothing (recommended for now).** The gap is a naming gap in a confirmation sheet, on a disk the user has
   already chosen to erase. Disk images are not offered for preparation at all (`DiskRefusal.diskImage`), so the
   one place this technique works is a place the product already refuses.
2. **Disk images only:** read the MBR from the backing file (`hdiutil info -plist` → `image-path`) or from the
   user-owned `/dev/rdiskN`, and add any non-empty entry `diskutil` did not list to the confirmation. Cost: a
   parser and a test fixture; benefit: none today, given the refusal above.
3. **Physical disks:** reading sector 0 needs root. The helper's allowlist has no such verb, and adding one is a
   helper change (security review, ADR, and the helper is held out of releases by ADR-0016 until #30 Part F
   passes). Not proposed.

## What would change the recommendation

A real report of a type-00 entry holding data on a USB disk a user meant to keep. Until then, option 1, with the
gap kept in STATUS "Open items" as it is.
