#!/bin/bash
# Signs, notarizes and staples a bundle built by the release workflow's `build` job, then packages, signs,
# notarizes and staples the DMG (ADR-0010). Run only by the `sign` job of .github/workflows/release.yml, which
# owns the temporary keychain and the API key file and deletes both whatever happens here.
#
# It builds nothing. The release workflow runs a copy of it, and of release-artifact-scan.sh, taken from the
# checkout before the build job's bundle is unpacked; so it finds the scan beside itself, not in a repository.
# It takes its inputs from the environment. The key files are never an argument, but the notary key ID and
# issuer ID are (`notarytool` reads them no other way); they identify the key and do not unlock it:
#   XCV_APP          the unsigned bundle (from the build job)
#   XCV_VERSION      the version being released, for the DMG's name
#   XCV_TEAM         the team ID the build was stamped with
#   XCV_IDENTITY     the SHA-1 hash of the signing identity (environment variable APPLE_SIGNING_IDENTITY)
#   XCV_KEYCHAIN     the temporary keychain holding that identity and nothing else
#   XCV_NOTARY_KEY   path to the App Store Connect API key (.p8)
#   XCV_NOTARY_KEY_ID, XCV_NOTARY_ISSUER
#   XCV_OUT          where the DMG and its .sha256 are written
#
# Local releases are scripts/release.sh's job, with the operator's own keychain; this is not run on a Mac.
set -euo pipefail
for v in XCV_APP XCV_VERSION XCV_TEAM XCV_IDENTITY XCV_KEYCHAIN XCV_NOTARY_KEY XCV_NOTARY_KEY_ID XCV_NOTARY_ISSUER XCV_OUT; do
    [ -n "${!v:-}" ] || { echo "refusing: $v is not set" >&2; exit 2; }
done
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$XCV_APP"
[[ "$XCV_TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "refusing: XCV_TEAM is not a team ID" >&2; exit 2; }
[[ "$XCV_IDENTITY" =~ ^[0-9A-F]{40}$ ]] || { echo "refusing: XCV_IDENTITY must be the identity's SHA-1 hash" >&2; exit 2; }

# 1. What is about to be signed carries nothing it must not (helper, stray Mach-O, a home path, an e-mail).
bash "$HERE/release-artifact-scan.sh" "$APP"

# 2. The keychain holds exactly one signing identity: the one named, a Developer ID Application of this team.
#    Never an Apple Development identity, whose name is the Apple ID e-mail.
ids=$(security find-identity -v -p codesigning "$XCV_KEYCHAIN" | /usr/bin/grep -E '^[[:space:]]+[0-9]+\)' || true)
[ "$(printf '%s\n' "$ids" | /usr/bin/grep -c .)" = 1 ] || { echo "refusing: the keychain must hold exactly one signing identity" >&2; exit 1; }
printf '%s\n' "$ids" | /usr/bin/grep -qE "^[[:space:]]+1\) $XCV_IDENTITY \"Developer ID Application: [^\"]+ \($XCV_TEAM\)\"$" \
    || { echo "refusing: the identity is not the Developer ID Application of team $XCV_TEAM named by APPLE_SIGNING_IDENTITY" >&2; exit 1; }

sign() { codesign --force --options runtime --timestamp --keychain "$XCV_KEYCHAIN" --sign "$XCV_IDENTITY" "$@"; }
notarize() {
    local out status id
    out=$(xcrun notarytool submit "$1" --key "$XCV_NOTARY_KEY" --key-id "$XCV_NOTARY_KEY_ID" \
        --issuer "$XCV_NOTARY_ISSUER" --wait --output-format json) || true
    status=$(printf '%s' "$out" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
    id=$(printf '%s' "$out" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
    echo "notarization of $(basename "$1"): ${status:-unknown} (submission ${id:-unknown})"
    if [ "$status" != "Accepted" ]; then
        # The log names what Apple rejected. It holds paths and hashes of the submission, nothing secret.
        [ -n "$id" ] && xcrun notarytool log "$id" --key "$XCV_NOTARY_KEY" --key-id "$XCV_NOTARY_KEY_ID" --issuer "$XCV_NOTARY_ISSUER" || true
        echo "refusing: notarization was not accepted" >&2
        exit 1
    fi
}
check_signed() {
    local info
    info=$(codesign -dvv "$1" 2>&1)
    printf '%s\n' "$info" | /usr/bin/grep -qx "TeamIdentifier=$XCV_TEAM" || { echo "refusing: $1 is not signed by team $XCV_TEAM" >&2; exit 1; }
    printf '%s\n' "$info" | /usr/bin/grep -qE '^Authority=Developer ID Application: ' || { echo "refusing: $1 is not signed with a Developer ID Application certificate" >&2; exit 1; }
    printf '%s\n' "$info" | /usr/bin/grep -qE '^Timestamp=' || { echo "refusing: $1 carries no secure timestamp" >&2; exit 1; }
}

# 3. Inside-out, as bundle-app.sh does: the CLI, then the app. No --deep, no library-validation opt-out.
sign --identifier com.xcodevault.xcodevaultctl "$APP/Contents/MacOS/xcodevaultctl"
sign "$APP"
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/xcodevaultctl"
codesign --verify --deep --strict --verbose=2 "$APP"
for f in "$APP/Contents/MacOS/xcodevaultctl" "$APP"; do
    check_signed "$f"
    codesign -dv "$f" 2>&1 | /usr/bin/grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' \
        || { echo "refusing: $f lacks the hardened runtime" >&2; exit 1; }
done

# 4. Notarize and staple the app first, so the copy inside the image carries its own ticket (release.sh, F7).
mkdir -p "$XCV_OUT"
ZIP="$XCV_OUT/XCodeVault-$XCV_VERSION-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Package, sign, notarize and staple the image.
DMG="$XCV_OUT/XCodeVault-$XCV_VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "XCodeVault" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --keychain "$XCV_KEYCHAIN" --sign "$XCV_IDENTITY" "$DMG"
check_signed "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 6. What a user's Gatekeeper will say, and the scan once more over what is actually shipped.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
bash "$HERE/release-artifact-scan.sh" "$APP"

(cd "$XCV_OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
cat "$DMG.sha256"
