#!/bin/bash
# E8 (behavioural half) + E11 — export a runtime installer to the Runtime Library on an external
# volume while sampling internal free space every 5 s. Answers: does `-downloadPlatform -exportPath`
# stage on the internal volume, and how much? Kills xcodebuild if internal free space drops below
# the floor so a near-full Mac is never driven to zero.
# Usage: scripts/experiments/e11-staging-monitor.sh <platform iOS|watchOS|tvOS|visionOS> <library-dir> [floor-GB=1.5]
#        scripts/experiments/e11-staging-monitor.sh import <path-to-dmg> [floor-GB=1.5]
source "$(dirname "$0")/common.sh"
PLAT="$1"; LIB="$2"; FLOOR_KB=$(python3 -c "print(int(${3:-1.5}*1024*1024))")
CTL="$XCV_ROOT/.build/debug/xcodevaultctl"
MODE=export; if [ "$PLAT" = import ]; then MODE=import; DMG="$2"; LIB=$(dirname "$DMG"); PLAT="import-$(basename "$DMG" .dmg)"; fi
out="$XCV_EVIDENCE_DIR/e11-$PLAT-$(xcv_env_slug).txt"
{
  xcv_header "E8b/E11: runtime export of $PLAT to $LIB with internal staging monitor (floor $((FLOOR_KB/1024)) MB)"
  if [ "$MODE" = import ]; then xcv_run "preflight" "$CTL" runtime import "$DMG" --preflight; else xcv_run "preflight" "$CTL" runtime export "$PLAT" --to "$LIB" --preflight; fi
  start_free=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}'); start_lib=$(df -k "$LIB" | awk 'NR==2{print $4}')
  echo "internal free at start: $((start_free/1024)) MB; library volume free: $((start_lib/1024)) MB"
  if [ "$MODE" = import ]; then ( "$CTL" runtime import "$DMG" > /tmp/xcv-e11-export.log 2>&1; echo "import exit=$?" >> /tmp/xcv-e11-export.log ) &
  else ( "$CTL" runtime export "$PLAT" --to "$LIB" > /tmp/xcv-e11-export.log 2>&1; echo "export exit=$?" >> /tmp/xcv-e11-export.log ) & fi
  bg=$!
  min_free=$start_free; t=0; killed=0
  while kill -0 $bg 2>/dev/null; do
    sleep 5; t=$((t+5))
    free=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}'); lib=$(df -k "$LIB" | awk 'NR==2{print $4}')
    [ "$free" -lt "$min_free" ] && min_free=$free
    printf 't=%4ds internal_free=%7d MB (Δ %+6d MB)  library_free=%8d MB (Δ %+6d MB)  staging dirs: %s\n' "$t" $((free/1024)) $(( (free-start_free)/1024 )) $((lib/1024)) $(( (lib-start_lib)/1024 )) "$(ls -d /Library/Developer/CoreSimulator/Cryptex/Images/Inbox/* /Library/Developer/CoreSimulator/Images/Inbox/* ~/Library/Caches/com.apple.dt.Xcode/Downloads/* 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$free" -lt "$FLOOR_KB" ]; then echo "!! internal free below floor — killing xcodebuild"; pkill -f 'xcodebuild -(downloadPlatform|importPlatform)'; killed=1; fi
  done
  wait $bg
  echo "--- export log ---"; tail -20 /tmp/xcv-e11-export.log
  echo "peak internal consumption during export: $(( (start_free-min_free)/1024 )) MB; killed=$killed"
  xcv_run "library afterwards" sh -c "ls -la '$LIB'; '$CTL' runtime library --dir '$LIB'"
  xcv_run "runtime registry afterwards" sh -c "xcrun simctl runtime list; du -sk /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime"
  xcv_run "any stranded downloads?" sh -c "ls -la /Library/Developer/CoreSimulator/Cryptex/Images/Inbox /Library/Developer/CoreSimulator/Images/Inbox ~/Library/Caches/com.apple.dt.Xcode/Downloads 2>&1"
} 2>&1 | xcv_redact | tee "$out.tmp" | grep -E '^(t=|!!|peak|internal free|export exit|preflight|\$ |Error|[0-9,]+ [GM]B)' | awk 'NR%6==1 || !/^t=/'
mv "$out.tmp" "$out"; echo "wrote $out"
