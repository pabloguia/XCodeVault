#!/usr/bin/env bash
# Tests for scripts/l10n/l10n.swift: every refusal `check` makes is triggered once, and the happy path passes.
# Runs against a scratch catalog; touches nothing in the repository.
set -u
cd "$(dirname "$0")/.."
bin=.build/l10n/l10n
if [ ! -x "$bin" ] || [ scripts/l10n/l10n.swift -nt "$bin" ]; then
    mkdir -p .build/l10n
    swiftc -O scripts/l10n/l10n.swift -o "$bin" || { echo "test-l10n: cannot build the tool" >&2; exit 1; }
fi
tool=(.build/l10n/l10n)
work=$(mktemp -d -t xcv-l10n-test)
trap 'rm -rf "$work"' EXIT
fail=0
pass=0

catalog() {  # $1: JSON body of "strings"
    printf '{"sourceLanguage":"en","version":"1.0","strings":{%s}}' "$1" >"$work/c.xcstrings"
}
good='"a.b":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Up to %@"}},"ja":{"stringUnit":{"state":"needs_review","value":"最大 %@"}}}},
"n.c":{"localizations":{"en":{"variations":{"plural":{"one":{"stringUnit":{"state":"translated","value":"%lld file"}},"other":{"stringUnit":{"state":"translated","value":"%lld files"}}}}},"ja":{"variations":{"plural":{"other":{"stringUnit":{"state":"needs_review","value":"%lld 個"}}}}}}}'
mkdir -p "$work/src"
printf 'let x = L10n.tr("a.b", "1 GB")\nlet y = L10n.plural("n.c", count: 2)\n' >"$work/src/Use.swift"

expect() {  # $1 description, $2 expected exit (0 or nonzero), rest: command
    local desc=$1 want=$2; shift 2
    "$@" >"$work/out" 2>&1; local got=$?
    if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" != 0 ] && [ "$got" != 0 ]; }; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: $desc (exit $got)"; sed 's/^/    /' "$work/out"
    fi
}
check() { "${tool[@]}" check "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja --sources "$work/src"; }

catalog "$good"
expect "gen succeeds" 0 "${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja
expect "check passes on a fresh table" 0 check
grep -q 'static let test = L10nCatalog' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: generated name"; }
grep -q '"最大 %@"' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: unicode kept literally"; }
grep -q 'swift-format-ignore-file' "$work/T.generated.swift" || { fail=$((fail + 1)); echo "FAIL: format ignore header"; }

echo '// edited' >>"$work/T.generated.swift"
expect "check refuses a stale table" 1 check

catalog "${good/,\"ja\":\{\"stringUnit\":\{\"state\":\"needs_review\",\"value\":\"最大 %@\"\}\}/}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses a missing locale" 1 check

catalog "${good/最大 %@/最大}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses a placeholder mismatch" 1 check

catalog "${good/\"value\":\"最大 %@\"/\"value\":\"\"}"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
expect "check refuses an empty value" 1 check

catalog "$good"
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
printf 'let z = L10n.tr("not.in.catalog")\n' >>"$work/src/Use.swift"
expect "check refuses an unknown key in sources" 1 check

printf 'let x = L10n.tr("a.b", "1 GB")\nlet y = L10n.plural("n.c", count: 2)\n' >"$work/src/Use.swift"

# Placeholders are compared in order (spec §4.6); catalog shapes the tool does not compile are refused.
shape() {  # $1 description, $2 expected exit, $3 one extra entry (JSON) added to the good catalog
    catalog "$good,$3"
    "${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja >/dev/null 2>&1
    expect "$1" "$2" check
}
entry() {  # $1 key, $2 en value, $3 ja value
    printf '"%s":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"%s"}},"ja":{"stringUnit":{"state":"needs_review","value":"%s"}}}}' "$1" "$2" "$3"
}
shape "check refuses reordered placeholders" 1 "$(entry r.o '%@ of %lld' '%lld の %@')"
shape "check accepts a positional reorder" 0 "$(entry r.p '%1$@ of %2$lld' '%2$lld の %1$@')"
shape "check refuses positional mixed with non-positional" 1 "$(entry r.m '%1$@ of %lld' '%1$@ の %lld')"
shape "check refuses %#@ (substitution syntax)" 1 "$(entry r.s '%#@x@' '%#@x@')"
shape "check refuses an unsupported specifier" 1 "$(entry r.u '%@ at 50%z' '%@ で 50%z')"
shape "check accepts %% beside a specifier" 0 "$(entry r.q '100%% of %@' '%@ の 100%%')"
shape "check refuses substitutions" 1 '"r.t":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"%@ files"},"substitutions":{"n":{"argNum":1,"formatSpecifier":"lld"}}},"ja":{"stringUnit":{"state":"needs_review","value":"%@ 個"}}}}'
shape "check refuses a device variation" 1 '"r.d":{"localizations":{"en":{"variations":{"device":{"mac":{"stringUnit":{"state":"translated","value":"Mac"}}}}},"ja":{"variations":{"device":{"mac":{"stringUnit":{"state":"needs_review","value":"Mac"}}}}}}}'
shape "check refuses a plural form that reorders" 1 '"r.n":{"localizations":{"en":{"variations":{"plural":{"one":{"stringUnit":{"state":"translated","value":"%lld file in %@"}},"other":{"stringUnit":{"state":"translated","value":"%lld files in %@"}}}}},"ja":{"variations":{"plural":{"other":{"stringUnit":{"state":"needs_review","value":"%@ に %lld 個"}}}}}}}'

# l10n.sh reads the locale list from L10n.swift; a list it cannot read is reported, not a silent death.
mkdir -p "$work/repo/scripts" "$work/repo/Sources/XCodeVaultCore/Localization"
cp scripts/l10n.sh "$work/repo/scripts/"
unreadable() {  # $1 description, $2 the declaration as printf format
    printf "$2" >"$work/repo/Sources/XCodeVaultCore/Localization/L10n.swift"
    bash "$work/repo/scripts/l10n.sh" check >"$work/out" 2>&1; local got=$?
    if [ "$got" = 2 ] && grep -q 'cannot read L10n.supportedLocales' "$work/out"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: l10n.sh reports $1 (exit $got)"; sed 's/^/    /' "$work/out"
    fi
}
unreadable "a list on the next line" 'public static let supportedLocales =\n    ["en", "ja"]\n'
unreadable "a list split over lines" 'public static let supportedLocales = [\n    "en",\n]\n'

printf 'let x = L10n.tr("a.b", "1 GB")\n' >"$work/src/Use.swift"
catalog "$good"
expect "add seeds a new locale" 0 "${tool[@]}" add "$work/c.xcstrings" es
grep -q '"es"' "$work/c.xcstrings" || { fail=$((fail + 1)); echo "FAIL: add wrote es"; }
"${tool[@]}" gen "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja,es >/dev/null 2>&1
expect "a seeded locale passes check" 0 "${tool[@]}" check "$work/c.xcstrings" "$work/T.generated.swift" test --locales en,ja,es --sources "$work/src"

echo "test-l10n: $pass passed, $fail failed"
[ "$fail" = 0 ]
