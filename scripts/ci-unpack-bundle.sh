#!/bin/bash
# Unpacks the build job's zip for the release workflow's `sign` job (ADR-0010), refusing anything but the one
# bundle. The zip's hash only proves it is what the build job uploaded; the build job made it, and the job
# that unpacks it is about to hold the signing key. So:
#   - every entry sits under XCodeVault.app/, none has a `..` component, none is a symbolic link;
#   - after extraction there is no link, and nothing but XCodeVault.app.
#
#   scripts/ci-unpack-bundle.sh path/to/XCodeVault-unsigned.zip DEST
#
# The listings are written to files and read whole. The first version piped them into `grep -q`, which exits
# at its first match; under `pipefail` the listing then died of SIGPIPE, the pipeline returned 141, and the
# refusal behind `&&` never ran. The helper-security review of 2026-10-02 measured that with a `..` entry
# ahead of 3000 others: not refused in 5 runs of 5. scripts/test-release-hygiene.sh keeps that case.
set -euo pipefail
ZIP="${1:?usage: ci-unpack-bundle.sh ZIP DEST}"
DEST="${2:?usage: ci-unpack-bundle.sh ZIP DEST}"
refuse() { echo "refusing: $1" >&2; exit 1; }
[ -f "$ZIP" ] || refuse "$ZIP is not a file"
[ ! -e "$DEST" ] || refuse "$DEST already exists"
work=$(mktemp -d -t xcv-unpack)
trap 'rm -rf "$work"' EXIT

zipinfo -1 "$ZIP" >"$work/names" || refuse "the zip cannot be listed"
zipinfo -l "$ZIP" >"$work/long" || refuse "the zip cannot be listed"
[ -s "$work/names" ] || refuse "the zip is empty"
if /usr/bin/grep -vqE '^XCodeVault\.app/' "$work/names"; then refuse "an entry is outside XCodeVault.app/"; fi
if /usr/bin/grep -qE '(^|/)\.\.(/|$)' "$work/names"; then refuse "an entry climbs out of the bundle"; fi
if /usr/bin/grep -qE '^l' "$work/long"; then refuse "the zip holds a symbolic link"; fi

mkdir -p "$DEST"
/usr/bin/ditto -x -k "$ZIP" "$DEST"
find "$DEST" -type l >"$work/links"
[ ! -s "$work/links" ] || refuse "a symbolic link was extracted"
[ "$(ls -A "$DEST")" = XCodeVault.app ] || refuse "the zip held more than the bundle"
echo "unpacked $(/usr/bin/grep -c . "$work/names") entries into $DEST"
