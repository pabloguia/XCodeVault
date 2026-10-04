# Savings visibility, internationalization and visual identity — design

_2026-10-03. Status: proposed, awaiting the operator's review. Supersedes nothing; extends
`docs/product/UX_AND_CLI.md` and the 2026-09-27 user-first permissions design._

## 1. Why

A review of the app and the CLI (2026-10-03) found the data model right and the presentation wrong
for the user the product is for:

1. **The summary answers engineering questions, not the user's.** It reports "cleanable",
   "relocatable", "cold-storage eligible", "Apple-managed" and "must remain local". The user asks
   three different things: *what can I delete and get back by downloading/rebuilding*, *what can I
   move out and bring back without downloading*, and *what can run from an external disk for good*.
2. **The headline numbers overlap without saying so.** DerivedData counts in both "cleanable" and
   "relocatable"; Archives in both "relocatable" and "cold storage". Adding the lines gives more
   bytes than the disk holds.
3. **Temporary and permanent savings are not distinguished.** Deleting regenerable data frees space
   that grows back; parking data on a vault frees it until it is brought back; running from an
   external disk stops the internal growth. These are different promises and must be different
   numbers.
4. **Privileged access is explained per screen, not once.** Full Disk Access is already asked for in
   context; the helper shows "Not available in this build" with no next step in every build without
   a Developer ID.
5. **The app has no identity**: no icon (`Info.plist` has no `CFBundleIconFile`), eight
   engineer-named sidebar sections, a numeric grid as the overview.
6. **The CLI help is accurate but internal**: experiment and hypothesis IDs (H15, E8b) and "Definition
   of Done" in user-facing abstracts, no examples, and the default command (`status`) shows no
   savings and no next step.
7. **Everything is English-only**, hard-coded in Swift string literals in Core, the CLI and the app.

## 2. Scope and order

Five sub-projects, each its own plan and commit series, in dependency order:

| # | Sub-project | Depends on |
|---|---|---|
| S1 | Savings model in Core | — |
| S2 | Localization infrastructure + five languages | — (S3–S5 use it) |
| S3 | CLI: savings-first `status`, plans per bucket, help with examples | S1, S2 |
| S4 | GUI: savings dashboard, bucket views, one access checklist | S1, S2, S5 |
| S5 | Visual identity: logo, app icon, palette, bucket colors | — |

Out of scope: any new storage strategy, any change to what is verified or experimental, making the
privileged helper run live (still blocked on a Developer ID build, #30), GUI execution of migrations
(see §6.4).

## 3. S1 — Savings model

### 3.1 Buckets

Every catalog category maps to the **options** a user has, each one of four user-facing buckets:

| Bucket (`SavingsBucket`) | User label (en) | What it promises | Cost to undo |
|---|---|---|---|
| `.deleteAndRegenerate` | Delete — comes back on demand | Freed now; grows back as you work | Rebuild or re-download time |
| `.parkExternally` | Park on an external drive | Freed until you bring it back | One copy back; no download |
| `.runFromExternal` | Run from an external drive | Freed for good; stops growing here | None; needs the drive connected |
| `.keepLocal` | Stays on this Mac | Nothing to reclaim safely | — |

Temporary savings = `.deleteAndRegenerate` + `.parkExternally`. Permanent savings = `.runFromExternal`.

### 3.2 Derivation (in Core, pure, tested against the whole catalog)

`StorageCategory.savingsOptions: [SavingsBucket]`, derived — never a second hand-maintained field
that can disagree with `allowedStrategies`:

- `.deleteAndRegenerate` if (`allowedStrategies` contains `.safeCleanup` **or** `cleanupCommand != nil`)
  **and** `regenerability != .nonRegenerable`. Rule 5: Archives never land here.
- `.parkExternally` if `allowedStrategies` contains `.coldStorage`, **or** the category is
  `simulatorRuntimeAssets` (offload via the Runtime Library, `runtime offload`). The runtime case is
  named, not inferred, because its strategy is `.appleManaged`; a catalog rule pins that the exception
  list has exactly the categories that have a park command.
- `.runFromExternal` if `allowedStrategies` contains `.nativeConfiguration`, `.userDirectoryRelocation`
  or `.downloadRepository` (the Runtime Library is a directory of installers meant to live on an
  external drive; it is a park *destination*, never a park source).
  `.symlinkRelocation` and `.canonicalMount` never produce it (ADR-0002, ADR-0004, rule 7).
- `.keepLocal` iff none of the above.

`primaryBucket` is the first option in the order run-from-external, park, delete — the most durable
saving the category supports. It is what the dashboard counts a byte under.

Each option carries `isExperimental` from the category (rule 10), the command that performs it, and
whether it needs root (`privilege`) or a vault.

Expected mapping for the current catalog (pinned by a test so a catalog change that moves a category
between buckets fails loudly and is a reviewed decision):

- delete: deviceSupport, previews, xcodePackages, xcodeCaches, deviceLogs, swiftPMCaches,
  simulatorUserCaches, xctestDevices, playgroundDevices, coreSimulatorSystemCaches (root,
  experimental), simulatorRuntimeAssets, simulatorDevices (`simctl delete`, user-recreatable), and
  DerivedData as an alternative.
- park: archives, simulatorRuntimeAssets.
- run from external: derivedData, archives (new archives only — existing ones are parked),
  runtimeLibrary (only counts when it sits on the boot volume).
- keep local: runtimeMounts, developerDiskImages, coreDevice, toolchains, commandLineTools,
  runtimeInbox, runtimeBundles, and the breakdown categories (counted inside their parent).

The `simulatorDevices` placement is a product decision this spec asks the operator to confirm: the
devices are user-recreatable, not regenerable, and deleting one loses its app data.

### 3.3 Summary (`SavingsSummary`, added to `ScanReport`; `ScanSummary` stays for compatibility)

Per bucket, over items on the boot volume, breakdowns skipped (same rule as today):

- `optionBytes[bucket]` — bytes for which that bucket is *an* option. Not additive across buckets,
  and every rendering says so.
- `primaryBytes[bucket]` — bytes counted once, under the primary bucket. Additive; sums to the
  boot-volume developer total.
- `verifiedBytes[bucket]` — the non-experimental part of `optionBytes`.
- `isLowerBound` — set when any counted item could not be fully read (the existing lower-bound
  signal). Bytes that could not be read cannot be measured, so there is no "bytes needing access"
  number; every headline is then rendered as "at least", and the access row (§6.3) says why.
- `reclaimableUnionBytes` — the union of the three saving buckets (each byte once), the honest
  "up to" headline.

Headlines: **Temporary: up to X** (delete ∪ park), **Permanent: up to Y** (run from external),
**Total reclaimable: up to Z** (union), each with its verified share.

### 3.4 Amendment (2026-10-03, after the S1 whole-branch review)

The review found two promises the first cut got wrong; these rulings replace the conflicting text above.

- **Experimental is decided per option, not per category.** `isExperimental` on a category describes its
  *recommended* strategy, and `.appleManaged` categories are never experimental by that definition, so a
  runtime's *park* (via `runtime offload`, labelled EXPERIMENTAL in the CLI) was counted as verified. An
  option is verified only when the category's `evidenceStatus == .verified` **and** the option is not a
  named park command. Every "verified" number counts only verified options.
- **Options can apply to new data only.** Archives' run-from-external (`locations set-archives`) moves where
  *new* archives go; existing archives are only parked. Such an option is listed but contributes no bytes:
  `primaryBucket` is the most durable option that applies to existing data, and the permanent headline
  counts only those.
- **`SavingsOption` carries the per-option facts** S3/S4 render: `bucket`, `isExperimental`,
  `appliesToExistingData`, and `losesUserData` (a delete of `.userRecreatable` data — simulator devices
  lose their app data and do not come back by themselves). Privilege is **not** on the option: the clean
  planner already carries it per action (`CleanAction.privilegeRequirement`), and a second copy would drift.
- **JSON names** are the implemented ones, not §3.3's draft names: `optionBytes`, `primaryBytes`,
  `verifiedOptionBytes`; `temporaryBytes`, `permanentBytes`, `reclaimableBytes` and their `verified…`
  counterparts, all **stored** (encoded), so `--json` carries all three headlines; `isLowerBound`.

## 4. S2 — Localization

### 4.1 Mechanism

- Source of truth: one String Catalog per module that has user-facing text,
  `Sources/<Module>/Localization/Localizable.xcstrings` (Xcode-editable JSON; translators can use any
  tool that reads it).
- `scripts/gen-strings.swift` compiles each catalog into `L10nTable.generated.swift`: a static
  `[String: [String: String]]` keyed by locale then key. **No runtime resource bundle**, so the
  stand-alone and Homebrew `xcodevaultctl` cannot crash on a missing `Bundle.module`.
- `L10n` in Core: `L10n.tr("key", args...)` resolves the locale (§4.2), falls back to `en`, then to
  the key itself; format arguments through `String(format:locale:)`; plurals through catalog
  `variations.plural` compiled to CLDR categories (`one`/`other`, plus `zh`/`ja` which only use
  `other`).
- Byte counts, dates and numbers use `ByteCountFormatStyle` / `FormatStyle` with the resolved locale.
- Keys are stable English-ish identifiers (`savings.bucket.delete.title`), not English sentences, so
  rewording English does not orphan translations.

### 4.2 Locale resolution

1. `--lang <code>` on the CLI (global option), 2. `XCODEVAULT_LANG`, 3. the app's/process's
`Locale.preferredLanguages`, 4. `en`. Supported: `en`, `pt-BR`, `es`, `ja`, `zh-Hans`. Unsupported
preferences fall through to the next.

### 4.3 What is never localized

`--json` output (keys and enum raw values stay stable English; it is an API), journal entries on
disk, category ids, command names and flags, paths, and log lines in evidence files. Safety-critical
confirmations are localized, but the CLI's typed confirmation flags (`--i-confirm-…`) are not.

### 4.4 Languages and quality

`en` (base), `pt-BR`, `es`, `ja`, `zh-Hans` ship together. Non-English strings are first drafted by
the implementer and marked `"state": "needs_review"` in the catalog until a native speaker reviews
them; `docs/process/LOCALIZATION.md` lists the review state per language. The app's `Info.plist`
gains `CFBundleLocalizations` for the five. No `InfoPlist.strings`: the app's name is the same in every language.

### 4.5 Adding a language (the "resources for new languages")

- `docs/process/LOCALIZATION.md`: glossary (vault, park, runtime, DerivedData stay untranslated
  product/Apple terms), tone, how to add a locale in three steps, how to test (`--lang`).
- `scripts/l10n.sh add <code>` seeds every key for the new locale with `needs_review` copies of `en`;
  `scripts/l10n.sh check` is a CI gate (part of `preflight.sh`) that fails on a missing key, a
  placeholder mismatch (`%@`/`%lld` count and order) between `en` and any locale, or a stale
  generated table.

### 4.6 Amendment (2026-10-03, after the S2 whole-branch review)

- **One catalog, in Core**, replacing "one String Catalog per module" in §4.1. Keys are namespaced by
  where they are shown: `savings.*` (shared), `cli.*`, `app.*`. One table keeps `check` exact (every
  literal key in `Sources/` is checked against it) and gives the CLI and the app one vocabulary. Revisit
  only if the generated file's compile time on this machine becomes a problem (measure at ~200 keys).
- **Glossary**, replacing §4.5's "vault, park … stay untranslated": product nouns and command words stay
  untranslated where they are typed (`vault init`, `runtime offload`, `--lang`); in prose the *concept* is
  translated (pt-BR "guardar", "disco-cofre"; ja "退避"), because a sentence that mixes in an untranslated
  English verb reads as a bug to the user.
- **Placeholders are compared in order**, as §4.5 always said; positional (`%1$@`) and non-positional
  specifiers are never mixed in one template. Catalog features the tool does not compile (`substitutions`,
  device variations, `%#@…@`) are refused by `check`, not ignored.

## 5. S3 — CLI

- `xcodevaultctl` / `status`: still fast (no size measurement) but ends with the last measured
  savings if a recent scan exists, otherwise "Run `xcodevaultctl scan` to measure what you can
  reclaim", plus the one access line from `permissions` when something blocks a saving.
- `scan` text output leads with the three headlines and a per-bucket table (category, size, cost to
  undo, verified/experimental, command), then the existing per-item detail behind `--details`.
- New read-only `plan <delete|park|external>`: the categories in that bucket, sizes, and the exact
  commands, in the order to run them. It executes nothing; the existing verbs (`clean`, `externalize`,
  `runtime offload`, `locations set-*`) stay the only writers.
- Help: subcommands grouped in the overview by task (See, Save space, Drives, Recover, Diagnose);
  every command gets an `EXAMPLES` section; hypothesis/experiment IDs move from abstracts to a
  "Background" line in the discussion; "experimental" stays in every abstract that has it (rule 10).
- Exit codes and `--json` unchanged except for the added `savings` object.

## 6. S4 — GUI

### 6.1 Navigation

Sidebar, two groups:
- **Save space**: Overview, Delete, Park, Run externally.
- **Details**: Storage (all items), Simulators, Drives (volumes + vaults), Health (doctor), History
  (journal), Access (permissions).

### 6.2 Overview

- A horizontal bar of the internal disk: other data / developer data split by primary bucket / free.
- Three cards — Temporary (delete), Temporary (park), Permanent (run externally) — each: big "up to"
  number, verified share, cost to undo in one sentence, a **Review** button to its bucket view.
- A note that the cards are alternatives for the same bytes, with the union total.
- At most one access banner (§6.3) and the doctor's critical findings.

### 6.3 Access — asked for simply, in one place, at the moment it matters

- One checklist row per need (Full Disk Access, privileged helper) with status, one sentence of why
  in terms of bytes ("Lets XCodeVault measure 3 folders it cannot read now"), and one button.
- Contextual: a bucket view whose rows need an access shows the same row inline above its table.
- The helper row in a build without the helper says what to do instead (the CLI command or "requires
  the signed release") rather than "Not available in this build".
- No new mechanism: still `SMAppService` approval and the Settings pane (ADR-0007); XCodeVault never
  asks for the user's password itself.

### 6.4 Bucket views

- **Delete**: today's Clean view, grouped and with a cost-to-undo column; same confirmation and
  journaling. Unchanged deletion semantics.
- **Park** and **Run externally**: the plan for each category with its status (no vault registered,
  vault offline, ready) and, per row, a **Copy command** button and a "how to" disclosure. GUI
  execution of `externalize` / `runtime offload` / `locations set-*` is a follow-up that needs its own
  spec and the migration-safety review; this design does not add a GUI writer.

## 7. S5 — Visual identity

- Concept: a rounded-square vault door seen front-on, its dial's notches forming an outward arrow —
  "storage, safely moved out". No hammer, no Xcode or Apple marks (trademark).
- Palette: deep indigo `#2B2D6E` (primary), teal `#1FB5A8` (accent), plus bucket colors used
  everywhere a bucket appears, in both the GUI and colored CLI output (respecting `NO_COLOR` and
  non-TTY): delete = amber, park = blue, run externally = green, keep local = gray; each paired with an
  SF Symbol so color is never the only signal (accessibility).
- Deliverables: `Resources/Brand/logo.svg` (master), `logo-mono.svg`, `AppIcon.icns` generated by
  `scripts/make-icon.sh` from the SVG at all `iconset` sizes, wired into `Info.plist` and
  `bundle-app.sh`; `docs/brand/BRAND.md` with usage rules; the README header uses the logo.

## 8. Testing

- S1: derivation table test over the whole catalog (the §3.2 mapping pinned), summary tests with
  fixture items covering overlap (DerivedData), breakdowns, off-boot items, lower bounds, and the
  invariant `sum(primaryBytes) == developer total on boot volume`.
- S2: `l10n.sh check` gate; unit tests for locale resolution order, fallback, plurals in `en`/`ja`,
  placeholder formatting; a test that every `L10n` key referenced in source exists in the catalog.
- S3: cli-smoke cases for `plan`, `--lang pt-BR`, and `--json` byte-identical across `--lang`.
- S4: `AppModel` tests through `AppEnvironment` fakes (existing pattern); bucket-view row derivation
  lives in Core and is tested there, so views decide nothing.
- S5: `make-icon.sh` produces every iconset size; bundle check that `CFBundleIconFile` resolves.
- Machine note: build + test is 10–20 minutes here; edits are batched per cycle and every gate runs
  through `scripts/preflight.sh` before a push.

## 9. Open decisions for the operator

1. Simulator devices under **Delete** (recreatable; loses app data) or under **Stays on this Mac**?
   Proposed: Delete, with the data-loss sentence as its cost to undo.
2. Translations for `ja` and `zh-Hans` ship marked `needs_review` until a native speaker reviews them.
   Acceptable?
3. Park / Run-externally execution in the GUI deferred to a follow-up spec (§6.4). Acceptable?

## 10. Carried into the S3/S4 plans (from the S1 and S2 reviews)

- Stop rendering `ScanSummary.verifiedSavingsBytes` (GUI Overview, `scan` text): it uses the category-level experimental
  flag and counts the runtime park as verified. Render `SavingsSummary` instead; mark the legacy field as legacy.
- `--json` stays English: localize at render time only, keep ids/English in `Codable` models; byte-identity tests across
  locales for `permissions`, `doctor` and the savings object.
- Format numbers and byte counts with `Locale(identifier: L10n.locale)`, not the machine locale (today `--lang zh-Hans-HK`
  still prints `10,37 GB` from a pt-BR machine).
- Tests that assert English text call `L10n.configure(override: "en", environment: [:], preferred: [])` first.
- Bound positional indices in the runtime guard (`%3$@` with one argument); align its counting of a repeated positional
  index with the checker.
- Consider generated typed accessors (`L10n.Savings.upTo(_:)`) or call-site argument counting in `check`; warn on unused keys.
- Measure the generated table's compile time at ~200 keys (`-Xfrontend -warn-long-expression-type-checking=200`).
- SwiftUI: `Text(verbatim: L10n.tr(...))`; seed the app's locale from `Bundle.main.preferredLocalizations`.
