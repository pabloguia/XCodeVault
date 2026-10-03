# Localization

XCodeVault ships in English (base), Brazilian Portuguese, Spanish, Japanese and Simplified Chinese.

## How it works

- Text lives in String Catalogs: `Sources/<Module>/Localization/Localizable.xcstrings` (open in Xcode, or
  edit the JSON). Keys are stable identifiers such as `savings.bucket.parkExternally.title`.
- `scripts/l10n.sh gen` compiles each catalog into `<Module>Strings.generated.swift`, a static table built
  into the binary. There is no runtime resource bundle, so a stand-alone `xcodevaultctl` has every language.
- Code uses `L10n.tr("key", args…)` and `L10n.plural("key", count: n, args…)` with **literal** keys.
- Locale: `--lang <code>` (CLI) → `XCODEVAULT_LANG` → macOS language preferences → English. Tests that
  assert English text must call `L10n.configure(override: "en", environment: [:], preferred: [])` first: the
  process locale follows the machine's language.
- Never translated: `--json` output, journal entries, category ids, commands, flags, paths, and the typed
  `--i-confirm-…` flags.

## Glossary — keep these untranslated

XCodeVault, Xcode, Simulator, DerivedData, Archives, runtime (in commands), Full Disk Access (use Apple's
own localized name for the Settings pane in prose: pt-BR "Acesso Total ao Disco", es "Acceso total al
disco", ja "フルディスクアクセス", zh-Hans "完全磁盘访问权限").

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

Localized so far: the savings vocabulary (S2). The CLI help and output (S3) and the app (S4) move their text
into the catalog as they are rewritten. Doctor findings, warnings and error messages are still English-only;
each one moves when its text is next edited.
