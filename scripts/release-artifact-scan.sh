#!/bin/bash
# Refuses a release bundle that carries what must not ship (ADR-0010, ADR-0016):
#   - the privileged helper without its launchd plist, or the plist without the helper, or a LaunchDaemons folder
#     holding anything but that one plist, byte for byte the one given as EXPECTED_PLIST (the tracked
#     Resources/LaunchDaemons/com.xcodevault.helper.plist). A bundle with the helper and no EXPECTED_PLIST is refused,
#     and so is one without the helper when EXPECTED_PLIST is given: the release always carries it (ADR-0016);
#   - any Mach-O file but the three we build, any of the three that is not exactly arm64 + x86_64, and a bundle in
#     which the app, the CLI or (when it ships) the helper is missing or is not a Mach-O file;
#   - a home-directory path other than the CI runner's, or anything shaped like an e-mail address;
#   - a symbolic link, which this scan would not follow.
#
# It names the file and counts what it found, and never prints the match: on CI its output is a public log,
# and printing what it found would publish what it exists to keep private.
#
#   scripts/release-artifact-scan.sh path/to/XCodeVault.app [EXPECTED_PLIST]
#
# Run by the release workflow on the unsigned bundle, before the signing job is reached, and again on the
# signed one. Run on a bundle built on a developer's Mac it fails, as it should: the build paths name the home.
set -u -o pipefail
APP="${1:?usage: release-artifact-scan.sh path/to/XCodeVault.app [EXPECTED_PLIST]}"
EXPECTED_PLIST="${2:-}"
[ -d "$APP/Contents" ] || { echo "release-artifact-scan: $APP is not a bundle" >&2; exit 2; }
fail=0
refuse() { echo "release-artifact-scan: $1" >&2; fail=1; }

HELPER="$APP/Contents/MacOS/xcodevault-helper"
DAEMONS="$APP/Contents/Library/LaunchDaemons"
if [ -n "$EXPECTED_PLIST" ] && [ ! -e "$HELPER" ] && [ ! -e "$DAEMONS" ]; then
    refuse "an expected plist was given and the bundle carries no helper"
fi
if [ -e "$HELPER" ] || [ -e "$DAEMONS" ]; then
    [ -f "$HELPER" ] || refuse "a LaunchDaemons folder is in the bundle without the helper"
    if [ ! -d "$DAEMONS" ]; then
        refuse "the helper is in the bundle without its LaunchDaemons plist"
    else
        listing=$(ls -A "$DAEMONS")
        [ "$listing" = com.xcodevault.helper.plist ] || refuse "the LaunchDaemons folder holds something other than com.xcodevault.helper.plist"
        if [ -z "$EXPECTED_PLIST" ] || [ ! -f "$EXPECTED_PLIST" ]; then
            refuse "the bundle carries the helper and no expected plist was given to compare it with"
        elif ! cmp -s "$EXPECTED_PLIST" "$DAEMONS/com.xcodevault.helper.plist"; then
            refuse "the helper's launchd plist differs from the tracked one"
        fi
    fi
fi
links=$(find "$APP" -type l | wc -l | tr -d ' ')
[ "$links" = 0 ] || refuse "the bundle holds $links symbolic link(s)"

while IFS= read -r -d '' f; do
    rel="${f#"$APP"/}"
    if file -b "$f" | /usr/bin/grep 'Mach-O' >/dev/null; then
        case "$rel" in
            Contents/MacOS/XCodeVault | Contents/MacOS/xcodevaultctl | Contents/MacOS/xcodevault-helper) ;;
            *) refuse "unexpected Mach-O file: $rel" ;;
        esac
        # Universal, exactly: 0.3.0-rc.1 was built on an Apple silicon runner, shipped arm64 only, and could not run
        # on an Intel Mac (2026-10-17). Architecture names are not private, so this one says what it found.
        archs=$(lipo -archs "$f" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ') || archs="unreadable "
        [ "$archs" = "arm64 x86_64 " ] || refuse "$rel holds [${archs% }], not exactly [arm64 x86_64]"
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

# The loop above checks the Mach-O files it finds; it does not ask that the binaries be there, or be Mach-O. Without
# this, a bundle whose helper is a shell script, or whose app binary is missing, passed: the `sign` job runs only this
# scan, so it would have signed the script with Developer ID for launchd to run as root (helper-security review of
# ADR-0017, L1). The helper is required when the release carries it: an expected plist was given, or the file is there.
required=(XCodeVault xcodevaultctl)
{ [ -n "$EXPECTED_PLIST" ] || [ -e "$HELPER" ]; } && required+=(xcodevault-helper)
for n in "${required[@]}"; do
    f="$APP/Contents/MacOS/$n"
    { [ -f "$f" ] && file -b "$f" | /usr/bin/grep 'Mach-O' >/dev/null; } || refuse "Contents/MacOS/$n is missing or is not a Mach-O file"
done

[ "$fail" = 0 ] && echo "release-artifact-scan: ok ($APP)"
exit "$fail"
