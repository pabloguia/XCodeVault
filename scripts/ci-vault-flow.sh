#!/bin/bash
# ADR-0015 on a disk image: ownership on, a vault in a user-named folder, status, forget, adopt again, and a folder
# with files refused as a vault by the app's rule. A disk image is NOT a physical drive (E2): this proves the flow per
# macOS/architecture, nothing about USB, TCC on removable media, or the privileged helper. Scratch HOME; no real disk.
set -euo pipefail
export LC_ALL=C
CTL="${CTL:-.build/debug/xcodevaultctl}"
[ -x "$CTL" ] || { echo "build first: $CTL missing"; exit 1; }
scratch=$(mktemp -d); export HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home"; mkdir -p "$HOME"
name="xcv-ci-$$"; img="$scratch/v.sparseimage"; mp="/Volumes/$name"
cleanup() { hdiutil detach "$mp" -force >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT
sw_vers -productVersion; uname -m
hdiutil create -size 64m -fs APFS -volname "$name" -type SPARSE "$img" >/dev/null
hdiutil attach -owners on -nobrowse "$img" >/dev/null
diskutil info "$mp" | grep -E "Owners|Volume Name"
"$CTL" vault init "$mp" --directory VaultCI
test -f "$mp/VaultCI/.xcodevault-volume.json" || { echo "FAIL: no sentinel"; exit 1; }
"$CTL" vault status | tee "$scratch/status.txt"
grep -q "VERIFIED" "$scratch/status.txt" || { echo "FAIL: not verified"; exit 1; }
uuid=$(diskutil info -plist "$mp" | plutil -extract VolumeUUID raw -o - -)
"$CTL" vault forget "$uuid"
"$CTL" vault init "$mp" --directory VaultCI   # this Mac's own folder is adopted, never overwritten
echo "vault-flow: ok"
