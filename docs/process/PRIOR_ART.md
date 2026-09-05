# Prior Art

Full sourced landscape in `../research/FINDINGS-2026-09-05.md` §F9.

## The market shape

**Every mature tool in this space deletes. Not one relocates.** DevCleaner (~1.6k
stars, 2.8.0 Nov 2025, Homebrew cask, macOS 14+), ClearDisk (~590 stars, 79 cache
paths), CodePurge, xcleaner, CleanMyMac CLI (v1.0.0 beta Jul 2026), DaisyDisk,
CleanMyMac — delete-only, all of them. Apple's own supported relocation covers exactly
three things: Derived Data, Archives, Compilation Cache.

Demand is documented and unmet: XcodesApp issue #781 ("Add Storage Management Tools for
Xcode Junk", opened 2025-12-10) sits open and unanswered; the Apple forum thread on
relocating CoreSimulator runs from 2019 to at least Oct 2024 with no working solution
ever posted.

**The gap is real. So is the reason it exists** — the substrate is actively hostile
(sealed cryptex runtimes, indirection-sensitive Simulator subsystems, external-volume
sandbox semantics, layout changes between Xcode majors). A project that ships careful
relocation for the provably-safe subset plus a real disconnect story is first in the
category. A project that ships `rsync -a` + `ln -s` for everything is mac-ssd-rescue
with a nicer icon, and breaks in the same documented ways.

## `Viniciuscarvalho/mac-ssd-rescue` — what it actually is

MIT, 100% bash, `mac-ssd-rescue.sh` (328 lines, self-declared v1.0.0), **3 commits, 2
stars, 0 forks, 0 issues, 0 releases**. A single-author weekend project with no users —
a starting point for a spec, **not a codebase to reuse**.

Migration, in full:
```bash
rsync -a --delete "$src/" "$dest/" 2>/dev/null
src_count=$(find "$src" -type f | wc -l); dest_count=$(find "$dest" -type f | wc -l)
(( dest_count < src_count )) && die "copy verification failed"
rm -rf "$src"; ln -s "$dest" "$src"
```

Defects to learn from, each of which is a requirement for us:
- `rsync -a` with **no `-X -A -E`** → xattrs, ACLs and resource forks are dropped. A
  correctness risk for code-signed bundles and `.xcarchive`s, not a cosmetic one.
- Verification is a **file count** with `<`. A copy that truncated every file passes.
- **stderr discarded** (`2>/dev/null`) under `set -euo pipefail` → partial failures kill
  the script with no diagnostic.
- **No free-space check** on the destination, **no filesystem-type check** (an exFAT
  stick is accepted, where symlinks and POSIX permissions misbehave), boot-volume
  exclusion is a hardcoded English `"Macintosh HD"` string.
- Restore has **no verification at all**, and if the target is missing it deletes the
  symlink — silently converting "drive unplugged" into "config gone".
- **No story whatsoever for the drive being absent.** No mount watcher, no stub, no
  guard. README advice: *"Keep the USB drive connected while using Xcode."*
- **`$HOME`-only.** It never touches `/Library/Developer`, so on Xcode 15+ it never
  reaches the runtimes that actually hold the gigabytes — while its README claims the
  CoreSimulator row covers "Simulator runtimes, 5-20 GB".
- **The CoreSimulator symlink it creates is a documented-broken configuration** (Jeff
  Johnson, Aug 2025 — breaks the Simulator's Files app even same-disk). See H5.

## What we take from it

The category list as a starting point, and every one of the failure modes above as an
explicit requirement in `../architecture/MIGRATION_ENGINE.md`. Nothing else.

Also: `doctor` must detect leftovers from users who ran it (or similar scripts) before
installing XCodeVault — absolute symlinks into `/Volumes/*/mac-ssd-rescue/`, broken
symlinks where the source was deleted, and any `~/Library/Developer/CoreSimulator`
symlink at all.
