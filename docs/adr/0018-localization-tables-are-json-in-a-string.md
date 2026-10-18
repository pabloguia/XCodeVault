# ADR 0018: The generated localization table is JSON in a raw string literal, decoded on first use

- Status: accepted (2026-10-18)
- Date: 2026-10-18
- Related: the localization spec (2026-10-03, §4), `docs/process/LOCALIZATION.md`, ADR-0017, STATUS ("the release build
  hangs on this Intel Mac", 2026-10-05).

## Context

`scripts/l10n.sh gen` compiled the String Catalog into `CoreStrings.generated.swift` as one Swift literal: a dictionary of
677 string entries and 19 plural entries, each a dictionary of locales (5,129 lines, 328 KB). The table is compiled in, not
a resource bundle, so a stand-alone `xcodevaultctl` has every language; that part stays.

Since 2026-10-05 a release build on this project's Intel Mac never finished: `swift build -c release` spun at 100% CPU
for about two hours in the whole-module compile of `XCodeVaultCore`, twice, and was stopped by hand. On 2026-10-17 the
same package built in release on the macos-15 runner in minutes (ADR-0017), which narrowed it to this Mac's build. Measured
on 2026-10-18, the generated file alone, compiled against a stub of `L10nCatalog` with this Mac's toolchain (Xcode's
Swift 6.3.2, x86_64):

| | dictionary literal | JSON string |
|---|---|---|
| `swiftc -typecheck` | 8.7 s | 4.3 s (most of it the driver and Foundation) |
| `swiftc -Onone -c` | 5.7 s | — |
| `swiftc -O -wmo -c` | **over 10 minutes at 100% CPU, stopped** | **0.85 s** |

So the literal is what the optimizer could not get through here. The two candidates STATUS named were this table and
`PlanBuilder`'s type checking; this measurement does not clear `PlanBuilder`, it shows the table is enough on its own.

## Decision

1. The generator writes the table as JSON (`{"strings": …, "plurals": …}`, pretty-printed, keys sorted) inside a raw
   multi-line string literal, and `L10nCatalog(json:)` decodes it the first time the table is read. To the compiler it
   is one string constant.
2. The literal's delimiter takes as many `#`s as it needs that the text can neither close it (`"""#`) nor start an escape
   in it (`\#`). JSON escapes quotes, so the first cannot occur today; a translation holding a backslash and a `#` makes
   the second occur, and the generator then uses `##`.
3. `init(json:)` traps if the text does not decode, rather than shipping an app with no strings. The text is the
   generator's, `scripts/l10n.sh check` (a CI gate) holds it equal to the catalog, and `L10nTests` decodes the shipped
   table whole.

## Consequences

- Equivalence was checked entry by entry: the old literal and the new JSON, compiled into one program, gave equal
  dictionaries (677 strings, 19 plurals).
- `scripts/test-l10n.sh` compiles a generated table holding `\#`, `"""#` and `\\#(` with the real `L10n.swift` and runs it:
  the value comes back exactly. Stuck at one `#` (mutation), it fails.
- Decoding costs one JSON parse of about 280 KB, once per process, when the first string is read.
- A diff of the generated file is still readable line by line; it is ordered by key, then locale alphabetically, not by
  `L10n.supportedLocales` as the literal was.
