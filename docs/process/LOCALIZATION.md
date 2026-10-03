# Localization

XCodeVault ships in English (base), Brazilian Portuguese, Spanish, Japanese and Simplified Chinese.

## How it works

- One catalog, in Core: `Sources/XCodeVaultCore/Localization/Localizable.xcstrings` (open in Xcode, or edit
  the JSON), with keys namespaced by where they are shown — `savings.*` and `perm.*` (shared), `cli.*`, `app.*`
  (spec §4.6). Keys are stable identifiers such as `savings.bucket.parkExternally.title`, not English sentences.
- `scripts/l10n.sh gen` compiles it into `CoreStrings.generated.swift`, a static table built into the binary.
  There is no runtime resource bundle, so a stand-alone `xcodevaultctl` has every language. The catalog is
  kept sorted (`add` writes it that way); an editor that reorders it produces a large, harmless diff.
- Code uses `L10n.tr("key", args…)` and `L10n.plural("key", count: n, args…)` with **literal** keys.
- Locale: `--lang <code>` (CLI) → `XCODEVAULT_LANG` → macOS language preferences → English. Tests that
  assert English text must call `L10n.configure(override: "en", environment: [:], preferred: [])` first: the
  process locale follows the machine's language.
- Never translated: `--json` output, journal entries, category ids, commands, flags, paths, and the typed
  `--i-confirm-…` flags.

## Glossary

Product nouns and command words stay untranslated **where they are typed**: `vault init`, `runtime offload`,
`--lang`, `--json`, category ids. In prose the **concept** is translated — pt-BR "guardar", "disco-cofre"; ja
"退避" — because a sentence that mixes in an untranslated English verb reads as a bug to the user (spec §4.6).

Always untranslated: XCodeVault, Xcode, Simulator, DerivedData, Archives. Full Disk Access: use Apple's own
localized name for the Settings pane in prose — pt-BR "Acesso Total ao Disco", es "Acceso total al disco", ja
"フルディスクアクセス", zh-Hans "完全磁盘访问权限".

## Placeholders

`scripts/l10n.sh check` compares every translation's placeholders with English's **in order** (spec §4.6):

- The supported specifiers are `%@`, `%d`/`%i`/`%u`/`%x`/`%X` with `l`/`ll`, `%f`/`%e`/`%g`, `%s`, `%c`, with
  optional flags, width and precision. Write `%%` for a literal percent sign; any other `%` is refused, by
  `check` and at run time (the string is then shown in English, or unformatted).
- A language whose word order differs uses positional specifiers: English `"%1$@ of %2$lld"`, Japanese
  `"%2$lld の %1$@"`. Positional and non-positional specifiers are never mixed in one string, and a plain
  `"%lld の %@"` against English `"%@ of %lld"` is refused, because the arguments would arrive swapped.
- At run time a template is formatted only when it is safe: all specifiers non-positional and no more of
  them than arguments, or all positional with indices `1…n`, each index used with one conversion
  (repeating `%1$@` is fine) and `n` no greater than the arguments. `%3$@` with one argument is shown in
  English, or unformatted.
- Every plural form, `one` included, contains the count placeholder: English `"%lld file"`, not `"One file"`.
- Catalog features the tool does not compile are refused rather than ignored: `substitutions` (and their
  `%#@name@` syntax) and any `variations` other than `plural` (device variations).

## Tone

Plain, short, second person, no exclamation marks. Say what happens to the user's files and what it costs
to undo. "Experimental" is always translated and always shown where the English shows it (CLAUDE.md rule 10).

## Review state

Every non-English string ships as `needs_review` until a native speaker reviews it in the catalog and
changes its state to `translated`. `scripts/l10n.sh check` prints the remaining count per language.

| Language | Code | Reviewed by | State |
|---|---|---|---|
| English | `en` | — | base |
| Português (Brasil) | `pt-BR` | — | needs review |
| Español | `es` | — | needs review |
| 日本語 | `ja` | — | needs review |
| 简体中文 | `zh-Hans` | — | needs review |

## Adding a language

1. `scripts/l10n.sh add <code>` — seeds every string with an English copy marked `needs_review`. It compiles
   nothing into the app until `gen` is run; `scripts/test-l10n.sh` covers the tool itself.
2. Add `<code>` to `L10n.supportedLocales` in `Sources/XCodeVaultCore/Localization/L10n.swift`, add its CLDR
   integer plural rule to `L10n.pluralCategory`, and add it to `CFBundleLocalizations` in
   `Resources/App/Info.plist`.
3. Translate in the catalog, run `scripts/l10n.sh gen && scripts/l10n.sh check`, add a row to the table
   above, and test with `xcodevaultctl --lang <code> status`.

## Coverage

Localized (S2, S3): the savings vocabulary, the command abstracts and group names, the root help
discussion, the savings and `plan` output — the notes under each `plan` row included, since they are display
text — and the `status` footer. Still English in every language: the per-command discussions, the examples
(they are commands), and Core's own prose — doctor findings, vault checks, scan and volume warnings, the
`clean` and `externalize` plan and preflight messages, and error messages (all of it formats bytes with
`ByteCount.english`, so an English sentence never carries another language's number format) — and the older
output lines. `--json` and `report` are
always English.

The app (S4) takes its language once at launch — its resolved localization, then the user's preferences;
`XCODEVAULT_LANG` is the CLI's — and every string it shows is a catalog key (`AppTextCoverageTests` refuses a
string literal in a view). Category names and outcomes stay the catalog's English, and Core prose (findings,
warnings, vault details) is shown as given. The permission texts (`perm.*`) are shared: the app's Permissions
section and the `permissions` text output show them in the chosen language, while `PermissionsReport`, the
journal and the clean plan keep the English (`why(in:)`/`title(in:)` take a locale; the plain properties are the
record's English).

`scripts/l10n.sh check` prints `l10n: unused key <key>` for a catalog key no source references — a warning,
not a failure, since a key can be built at run time.
