#!/bin/bash
# Refuses a release bundle that carries what must not ship (ADR-0010):
#   - the privileged helper or its launchd plist (bundle-app.sh lists why it stays out);
#   - any Mach-O file but the two we build;
#   - a home-directory path other than the CI runner's, or anything shaped like an e-mail address;
#   - a symbolic link, which this scan would not follow.
#
# It names the file and counts what it found, and never prints the match: on CI its output is a public log,
# and printing what it found would publish what it exists to keep private.
#
#   scripts/release-artifact-scan.sh path/to/XCodeVault.app
#
# Run by the release workflow on the unsigned bundle, before the signing job is reached, and again on the
# signed one. Run on a bundle built on a developer's Mac it fails, as it should: the build paths name the home.
set -u -o pipefail
APP="${1:?usage: release-artifact-scan.sh path/to/XCodeVault.app}"
[ -d "$APP/Contents" ] || { echo "release-artifact-scan: $APP is not a bundle" >&2; exit 2; }
fail=0
refuse() { echo "release-artifact-scan: $1" >&2; fail=1; }

[ -e "$APP/Contents/MacOS/xcodevault-helper" ] && refuse "the privileged helper is in the bundle"
[ -e "$APP/Contents/Library/LaunchDaemons" ] && refuse "a LaunchDaemons folder is in the bundle"
links=$(find "$APP" -type l | wc -l | tr -d ' ')
[ "$links" = 0 ] || refuse "the bundle holds $links symbolic link(s)"

while IFS= read -r -d '' f; do
    rel="${f#"$APP"/}"
    if file -b "$f" | /usr/bin/grep -q 'Mach-O'; then
        case "$rel" in
            Contents/MacOS/XCodeVault | Contents/MacOS/xcodevaultctl) ;;
            *) refuse "unexpected Mach-O file: $rel" ;;
        esac
    fi
    # Every printable run of the whole file. Not `strings -a`: on macOS 26.7 it found none of the 206 /Users/
    # paths in a debug xcodevaultctl's symbol table, which `tr` finds (measured 2026-10-02).
    # A path under /Users/runner is the CI runner's home and names nobody; any other /Users/<name> is a person's.
    text=$(LC_ALL=C tr -c '[:print:]' '\n' <"$f")
    homes=$(printf '%s\n' "$text" | /usr/bin/grep -oE '/Users/[^/[:space:]]+' | /usr/bin/grep -vcE '^/Users/(runner|Shared)$')
    [ "$homes" = 0 ] || refuse "$rel names a home directory other than the runner's ($homes occurrence(s))"
    mails=$(printf '%s\n' "$text" | /usr/bin/grep -cE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')
    [ "$mails" = 0 ] || refuse "$rel carries $mails line(s) shaped like an e-mail address"
done < <(find "$APP" -type f -print0)

[ "$fail" = 0 ] && echo "release-artifact-scan: ok ($APP)"
exit "$fail"
