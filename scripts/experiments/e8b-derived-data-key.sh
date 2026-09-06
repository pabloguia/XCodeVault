#!/bin/bash
# E8b — Does xcodebuild honour the 2016-era IDECustomDerivedDataLocation default on this Xcode?
# Reversible write-test: sets the key to a scratch dir, runs -showBuildSettings on the E2 fixture,
# then deletes the key (or restores the previous value). Refuses to run while Xcode.app is open.
source "$(dirname "$0")/common.sh"
FIXTURE="$XCV_ROOT/fixtures/E2Fixture"
SCRATCH="${XCV_E8B_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/xcv-e8b.XXXX")}"
out="$XCV_EVIDENCE_DIR/e8b-$(xcv_env_slug).txt"
if pgrep -x Xcode >/dev/null; then echo "Xcode.app is running — quit it first (the IDE caches defaults)"; exit 1; fi
prev=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null)
restore() { if [ -n "$prev" ]; then defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation "$prev"; else defaults delete com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null; fi; rm -rf "$SCRATCH"; }
trap restore EXIT
{
  xcv_header "E8b IDECustomDerivedDataLocation honoured by xcodebuild? (reversible write-test)"
  echo "previous value: ${prev:-<unset>}"
  xcv_run "baseline: where does a build land with the key unset?" sh -c "cd '$FIXTURE' && xcodebuild build -scheme E2Fixture -destination platform=macOS -quiet 2>&1 | grep -vE 'DVTProvisioning|^$' | tail -3; ls -d ~/Library/Developer/Xcode/DerivedData/E2Fixture-* 2>/dev/null"
  xcv_run "set key" defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation "$SCRATCH/DD"
  xcv_run "read back" defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation
  xcv_run "build with the key set" sh -c "cd '$FIXTURE' && xcodebuild build -scheme E2Fixture -destination platform=macOS -quiet 2>&1 | grep -vE 'DVTProvisioning|^$' | tail -3"
  xcv_run "what xcodebuild created under the custom location" find "$SCRATCH/DD" -maxdepth 4 -name 'Products' -o -maxdepth 4 -name '*.framework' -o -maxdepth 1 -mindepth 1
  xcv_run "-derivedDataPath still overrides the default" sh -c "cd '$FIXTURE' && xcodebuild build -scheme E2Fixture -destination platform=macOS -derivedDataPath '$SCRATCH/Explicit' -quiet 2>&1 | grep -vE 'DVTProvisioning|^$' | tail -2; find '$SCRATCH/Explicit' -maxdepth 2 -mindepth 1"
} 2>&1 | xcv_redact > "$out"
echo "wrote $out"; grep -E 'OBJROOT|BUILD_DIR|previous' "$out"
