#!/bin/bash
# E8 — Feature-detect what each installed Xcode's xcodebuild/simctl actually supports (gates H4). Read-only.
# Usage: scripts/experiments/e8-feature-detect.sh [/Applications/Xcode.app ...]
source "$(dirname "$0")/common.sh"
xcodes=("$@"); [ ${#xcodes[@]} -eq 0 ] && xcodes=(/Applications/Xcode*.app)
out="$XCV_EVIDENCE_DIR/e8-$(xcv_env_slug).txt"
{
  xcv_header "E8 xcodebuild/simctl capability detection (read-only)"
  for x in "${xcodes[@]}"; do
    xb="$x/Contents/Developer/usr/bin/xcodebuild"
    [ -x "$xb" ] || continue
    echo "==== $x ===="
    xcv_run "version" "$xb" -version
    xcv_run "usage lines mentioning platform/component flags" sh -c "'$xb' -help 2>&1 | grep -nE 'downloadPlatform|downloadAllPlatforms|importPlatform|exportPath|architectureVariant|buildVersion|downloadComponent|importComponent|deleteComponent|showComponent|checkForNewerComponents|runFirstLaunch|prepareDeviceSupport|derivedDataPath'"
    xcv_run "simctl runtime verbs" env DEVELOPER_DIR="$x/Contents/Developer" xcrun simctl runtime
    xcv_run "showComponent metalToolchain (Xcode 26+)" env DEVELOPER_DIR="$x/Contents/Developer" "$xb" -showComponent metalToolchain -json
  done
  xcv_run "Xcode Locations defaults (DerivedData / Archives / build style)" sh -c "for k in IDECustomDerivedDataLocation IDEBuildLocationStyle IDECustomBuildProductsPath IDECustomBuildIntermediatesPath IDEArchivePathOverride IDECustomDistributionArchivesLocation; do printf '%s = ' \$k; defaults read com.apple.dt.Xcode \$k 2>/dev/null || echo '<unset>'; done"
} 2>&1 | xcv_redact > "$out"
echo "wrote $out"
