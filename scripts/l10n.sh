#!/usr/bin/env bash
# Localization driver (docs/process/LOCALIZATION.md).
#   scripts/l10n.sh gen            regenerate every compiled table
#   scripts/l10n.sh check          CI gate: stale tables, missing/empty/mismatched strings, unknown keys
#   scripts/l10n.sh add <locale>   seed a new locale (then add it to L10n.supportedLocales)
set -euo pipefail
cd "$(dirname "$0")/.."

# The one list of locales lives in L10n.swift; read it, never restate it. It must stay on one line: a list
# this cannot read reaches the message below instead of ending the script silently under `set -e`.
locales=$(grep -E '^\s*public static let supportedLocales = \[' Sources/XCodeVaultCore/Localization/L10n.swift \
    | sed -nE 's/.*\[(.*)\].*/\1/p' | sed -E 's/[" ]//g' || true)
[ -n "$locales" ] || { echo "l10n: cannot read L10n.supportedLocales" >&2; exit 2; }

# module catalog | generated table | static name
MODULES=(
    "Sources/XCodeVaultCore/Localization/Localizable.xcstrings|Sources/XCodeVaultCore/Localization/CoreStrings.generated.swift|core"
)

bin=.build/l10n/l10n
if [ ! -x "$bin" ] || [ scripts/l10n/l10n.swift -nt "$bin" ]; then
    mkdir -p .build/l10n
    swiftc -O scripts/l10n/l10n.swift -o "$bin" || { echo "l10n: cannot build the tool" >&2; exit 1; }
fi
tool=(.build/l10n/l10n)
case "${1:-}" in
gen)
    for m in "${MODULES[@]}"; do IFS='|' read -r c o n <<<"$m"; "${tool[@]}" gen "$c" "$o" "$n" --locales "$locales"; done ;;
check)
    rc=0
    for m in "${MODULES[@]}"; do
        IFS='|' read -r c o n <<<"$m"
        "${tool[@]}" check "$c" "$o" "$n" --locales "$locales" --sources Sources || rc=1
    done
    exit $rc ;;
add)
    [ -n "${2:-}" ] || { echo "usage: scripts/l10n.sh add <locale>" >&2; exit 2; }
    for m in "${MODULES[@]}"; do IFS='|' read -r c _ _ <<<"$m"; "${tool[@]}" add "$c" "$2"; done
    echo "l10n: now add \"$2\" to L10n.supportedLocales and a plural rule to L10n.pluralCategory, then run: scripts/l10n.sh gen" ;;
*)
    echo "usage: scripts/l10n.sh gen | check | add <locale>" >&2; exit 2 ;;
esac
