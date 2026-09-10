#!/bin/bash
# E15 — Does the Xcode 26 toolchain honour a *custom device set* outside simctl?
#
#   Gates the "transparency" half of H12.  Deliberately uses an alternate set on the
#   INTERNAL disk, so it answers the IDE question without entangling it with H6/E14b.
#
#   Static evidence that motivates it (E14a, verified 2026-09-09 on Xcode 26.5):
#     -[DVTiPhoneSimulatorLocator startLocating] does
#         [[NSUserDefaults standardUserDefaults] dvt_filePathForKey:@"DVTSimulatorSetLocation"]
#     and branches: nil -> [SimServiceContext defaultDeviceSetWithError:]  ("Creating/fetching
#     default SimDeviceSet"); non-nil -> [SimServiceContext deviceSetWithPath:error:]
#     ("Creating/fetching temporary SimDeviceSet at: %@"), then
#     -[DVTiPhoneSimulatorLocator _startLocatingDevicesInDeviceSet:].
#     DVTiPhoneSimulatorLocator is the only simulator device locator in Xcode 26.5, and it is
#     what feeds the run-destination picker.  So the code path exists; what is UNTESTED is
#     whether the key is read from the domain each *client* uses.
#
# THIS SCRIPT MUTATES STATE (a user default + a scratch device set).  Not run by the
# research agent.  It writes `defaults write com.apple.dt.Xcode DVTSimulatorSetLocation`
# and restores the prior value (or deletes the key) on exit, including on ^C.
# It never touches ~/Library/Developer/CoreSimulator/Devices: every simctl call uses --set.
#
# Usage:  scripts/experiments/e15-ide-honours-device-set.sh --i-understand
#
# The three clients, and why each is a separate question:
#   A. simctl --set          — known to work; the control.
#   B. xcodebuild            — has NO --set flag.  Its NSUserDefaults "standard" domain for a
#                              non-bundled tool is not obviously com.apple.dt.Xcode, so the
#                              key may simply not be visible to it.  Tested here by
#                              `xcodebuild -showdestinations` before/after.
#   C. Xcode.app             — MANUAL.  Quit Xcode, set the key, relaunch, open the run
#                              destination menu, and confirm the probe device appears and the
#                              default set's devices do not.  Also check Window > Devices and
#                              Simulators, and the Previews canvas device picker.
#                              Then `defaults write com.apple.iphonesimulator DeviceSetPath`
#                              likewise, since Simulator.app reads its OWN key (E14a) and
#                              nothing in IDEiOSSupportCore passes the set through to it.
#
# What would FALSIFY the transparency claim:
#   - `xcodebuild -showdestinations` lists the DEFAULT set's simulators with the key set
#   - Xcode's picker lists the default set's simulators with the key set
#   - Xcode lists the custom set but Simulator.app opens the default one (split brain — the
#     WORST outcome, because it is silent; treat it as fatal for a v1 product story)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "${1:-}" = "--i-understand" ] || { echo "usage: $0 --i-understand" >&2; exit 2; }

OUT="$XCV_EVIDENCE_DIR/e15-ide-honours-device-set-$(xcv_env_slug).txt"
SET_PATH="$HOME/.xcodevault-e15-set"          # internal disk on purpose; see header
FIXTURE="${XCV_FIXTURE:-$XCV_ROOT/fixtures/E2Fixture}"
PRIOR=""
HAD_KEY=no
UDID=""

restore() {
  echo "## restore"
  if [ "$HAD_KEY" = yes ]; then
    defaults write com.apple.dt.Xcode DVTSimulatorSetLocation -string "$PRIOR"
    echo "restored DVTSimulatorSetLocation = $PRIOR"
  else
    defaults delete com.apple.dt.Xcode DVTSimulatorSetLocation 2>/dev/null
    echo "deleted DVTSimulatorSetLocation (was unset)"
  fi
  defaults read com.apple.dt.Xcode DVTSimulatorSetLocation 2>&1 | sed 's/^/  now: /'
  [ -n "$UDID" ] && xcrun simctl --set "$SET_PATH" delete "$UDID" 2>&1
  [ -f "$SET_PATH/.xcv-e15" ] && rm -rf "$SET_PATH" && echo "removed $SET_PATH"
}
trap restore EXIT INT TERM

{
  xcv_header "E15 — does xcodebuild / Xcode honour DVTSimulatorSetLocation?"

  if PRIOR=$(defaults read com.apple.dt.Xcode DVTSimulatorSetLocation 2>/dev/null); then
    HAD_KEY=yes
  fi
  echo "# prior value of DVTSimulatorSetLocation: ${PRIOR:-<unset>}"
  echo "# scratch device set: $SET_PATH"
  echo

  echo "## A. control — build a one-device set with simctl --set"
  mkdir -p "$SET_PATH" && : > "$SET_PATH/.xcv-e15"
  RUNTIME="${XCV_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]]; print(rs[0]["identifier"] if rs else "")')}"
  DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
  xcv_run "create XCV-E15-Probe" bash -c "xcrun simctl --set '$SET_PATH' create XCV-E15-Probe '$DEVTYPE' '$RUNTIME'"
  UDID=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
    'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"]=="XCV-E15-Probe"), ""))')
  echo "# probe UDID: ${UDID:-<none>}"
  [ -n "$UDID" ] || { echo "!! control failed; stop."; exit 1; }
  xcv_run "custom set contents" xcrun simctl --set "$SET_PATH" list devices
  xcv_run "default set still unchanged" bash -c "xcrun simctl list devices | grep -c XCV-E15-Probe; echo '(0 = probe is not in the default set, as intended)'"

  echo "## B. xcodebuild, key UNSET (baseline)"
  defaults delete com.apple.dt.Xcode DVTSimulatorSetLocation 2>/dev/null
  xcv_run "xcodebuild -showdestinations (baseline)" bash -c \
    "cd '$FIXTURE' && xcodebuild -showdestinations -scheme \"\$(xcodebuild -list -json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"workspace\"][\"schemes\"][0])')\" -derivedDataPath /tmp/xcv-e15-dd 2>&1 | grep -E 'platform:.*Simulator|XCV-E15-Probe' | head -30"

  echo "## C. xcodebuild, key SET"
  defaults write com.apple.dt.Xcode DVTSimulatorSetLocation -string "$SET_PATH"
  xcv_run "confirm key" defaults read com.apple.dt.Xcode DVTSimulatorSetLocation
  xcv_run "xcodebuild -showdestinations (key set)" bash -c \
    "cd '$FIXTURE' && xcodebuild -showdestinations -scheme \"\$(xcodebuild -list -json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"workspace\"][\"schemes\"][0])')\" -derivedDataPath /tmp/xcv-e15-dd 2>&1 | grep -E 'platform:.*Simulator|XCV-E15-Probe' | head -30"
  echo "# READ THIS: if the two lists above are identical, xcodebuild does NOT see the key."
  echo "# If C lists only XCV-E15-Probe, xcodebuild honours it and a CLI/CI story exists."

  echo "## D. also try the domain a non-bundled tool would actually use"
  defaults write xcodebuild DVTSimulatorSetLocation -string "$SET_PATH"
  xcv_run "xcodebuild -showdestinations (domain 'xcodebuild')" bash -c \
    "cd '$FIXTURE' && xcodebuild -showdestinations -scheme \"\$(xcodebuild -list -json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"workspace\"][\"schemes\"][0])')\" -derivedDataPath /tmp/xcv-e15-dd 2>&1 | grep -E 'platform:.*Simulator|XCV-E15-Probe' | head -30"
  defaults delete xcodebuild DVTSimulatorSetLocation 2>/dev/null

  echo "## E. Xcode.app — MANUAL, do not automate"
  cat <<'MANUAL'
  1. Quit Xcode completely.
  2. defaults write com.apple.dt.Xcode DVTSimulatorSetLocation -string "$HOME/.xcodevault-e15-set"
  3. Launch Xcode, open any iOS project, open the run-destination menu.
     Expected if honoured: only XCV-E15-Probe under iOS Simulator.
  4. Window > Devices and Simulators > Simulators — which set is listed?
  5. Open a SwiftUI preview — does the canvas device picker agree?
  6. Run the app.  Does Simulator.app show the probe device, or a device from the DEFAULT
     set?  Simulator.app reads its own `DeviceSetPath` default (E14a) and nothing in
     IDEiOSSupportCore hands the set path to it, so a split is the expected failure.
     If it splits, also set: defaults write com.apple.iphonesimulator DeviceSetPath -string <path>
  7. log stream --predicate 'eventMessage CONTAINS "SimDeviceSet"' while Xcode starts, and
     look for "Creating/fetching temporary SimDeviceSet at: <path>" vs
     "Creating/fetching default SimDeviceSet" — that single log line is the direct answer.
  8. Restore: defaults delete com.apple.dt.Xcode DVTSimulatorSetLocation
              defaults delete com.apple.iphonesimulator DeviceSetPath
MANUAL
} 2>&1 | xcv_redact > "$OUT"

echo "wrote $OUT"
