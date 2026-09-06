# XCodeVault

Honest accounting and safe relocation of the disk space Apple developer tooling consumes —
simulator runtimes, CoreSimulator data, DerivedData, device support, caches, archives — while
keeping Xcode, Simulator, `xcodebuild`, `simctl` and `devicectl` working.

**Status: pre-release, M1 (accounting) working.** Nothing here relocates or deletes anything
yet; every command is read-only. See [STATUS.md](STATUS.md).

```bash
swift build
.build/debug/xcodevaultctl scan          # what is consuming the internal SSD, per category
.build/debug/xcodevaultctl doctor        # broken/unsafe configurations, proposed repairs
.build/debug/xcodevaultctl xcode list    # installed Xcodes and feature-detected capabilities
.build/debug/xcodevaultctl volumes       # mounted volumes and whether they qualify as destinations
.build/debug/xcodevaultctl compatibility # every category, strategy, evidence status
```

Every read command accepts `--json`.

## Why this exists

Every mature tool in this space deletes; none relocates, and the one script that tries
symlinks `~/Library/Developer/CoreSimulator` — a configuration that breaks the Simulator.
XCodeVault is built research-first: `docs/research/` holds the sourced findings, `docs/
architecture/HYPOTHESES.md` the open questions, `docs/architecture/EXPERIMENTS.md` the gating
experiments, and `docs/architecture/COMPATIBILITY_MATRIX.md` the evidence. A strategy is
labeled **experimental** everywhere until it meets the Definition of Done in
`docs/product/NON_GOALS_AND_SAFETY.md`.

Key findings so far (macOS 26.6.2 / Xcode 26.5): all installed runtime bytes live in
`/System/Library/AssetsV2/…`, not under `/Library/Developer`; and the external-volume
`xctest` failure follows the physical device, not the path. See `docs/adr/`.

## Safety rules

Never disables SIP, never modifies `/System`, never symlinks `~/Library/Developer` or its
`CoreSimulator`/`DeveloperDiskImages`, never deletes a source before verification, never
auto-deletes Archives. Full list in `CLAUDE.md` and `docs/product/NON_GOALS_AND_SAFETY.md`.

## Requirements

macOS 14+, Xcode 16+. Developed and tested on macOS 15 and 26.

## License

MIT (to be added with the first release).
