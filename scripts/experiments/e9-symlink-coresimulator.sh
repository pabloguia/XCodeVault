#!/bin/bash
# E9 — does symlinking ~/Library/Developer/CoreSimulator break the Simulator, even when the
# target stays on the same internal disk? Gates H5 (docs/architecture/HYPOTHESES.md), reproduces
# or refutes Jeff Johnson's 2025-08-17 report (F3). Procedure: docs/process/RUNBOOK-E9-symlink-coresimulator.md
#
# Runs in phases because the claim under test (Files app: create folder / save / share) is a GUI
# interaction that sits between the scriptable steps. The GUI results are appended to the same
# evidence file as a manually written section.
#
#   phase1   steps 2-4  swap in the symlink, verify the device registry, create+boot a probe device
#   (manual)  step 5    Files-app interactive pass, recorded into the evidence file by the operator
#   phase2   steps 6-8  build/run/write-test cycle, probe cleanup, physical-device read-only check
#   restore  steps 9-10 remove the symlink, restore the real directory, validate against baseline
#
# This experiment needs no root. common.sh's xcv_header is deliberately not used: it probes with
# `sudo -n true`, and this run was explicitly required to never invoke sudo at all.
set -u
source "$(dirname "$0")/common.sh"

REAL="$HOME/CoreSimulator-real"
LINK="$HOME/Library/Developer/CoreSimulator"
PROBE_NAME="xcv-e9-probe"
SCRATCH="${XCV_E9_SCRATCH:-/private/tmp/xcv-e9-scratch}"
STATE="/private/tmp/xcv-e9-state"
out="$XCV_EVIDENCE_DIR/e9-symlink-coresimulator-$(xcv_env_slug).txt"

e9_header() {
  echo "# Experiment: $1"
  echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "# Arch: $(uname -m)"
  echo "# Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "# xcode-select: $(xcode-select -p)"
  echo "# Runner: $(id -un) (uid $(id -u)); sudo: not used — this experiment requires no root"
  echo
}

phase1() {
  # Preconditions are re-checked here, not assumed: a second swap layered on top of a stale one
  # would make the restore ambiguous about which directory is the real content.
  if [ -L "$LINK" ]; then echo "ABORT: $LINK is already a symlink — a prior run was not cleaned up" >&2; exit 1; fi
  if [ -e "$REAL" ]; then echo "ABORT: $REAL already exists — a prior run was not cleaned up" >&2; exit 1; fi
  {
    e9_header "E9 phase 1: symlink ~/Library/Developer/CoreSimulator to a same-disk target"
    xcv_run "baseline devices (before swap)" xcrun simctl list devices
    xcv_run "baseline runtimes (before swap)" xcrun simctl runtime list
    xcv_run "baseline: real directory, size, inode" sh -c "ls -ld '$LINK'; du -sh '$LINK'; stat -f 'inode=%i' '$LINK'"

    echo "## step 2 — swap (rename + symlink, same volume: instantaneous, no copy, no extra space)"
    xcv_run "mv CoreSimulator -> CoreSimulator-real" mv "$LINK" "$REAL"
    xcv_run "ln -s CoreSimulator-real -> CoreSimulator" ln -s "$REAL" "$LINK"
    xcv_run "verify the swap" sh -c "ls -ld '$LINK'; readlink '$LINK'; stat -f 'target inode=%i' '$LINK/'"

    echo "## step 3 — does CoreSimulatorService still see the same devices through the symlink?"
    xcv_run "devices through the symlink (service not restarted)" xcrun simctl list devices
    xcv_run "restart CoreSimulatorService (forces a cold path resolution)" \
      sh -c "pkill -9 -f com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null; sleep 3; true"
    xcv_run "devices after service restart" xcrun simctl list devices
    xcv_run "runtimes after service restart" xcrun simctl runtime list

    echo "## step 4 — simctl-level sanity pass on a throwaway device (never the user's real ones)"
    rt=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(next(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name","")))')
    echo "runtime: $rt"
    dt=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devicetypes"]; print(next(x["identifier"] for x in d if x["name"]=="iPhone 17 Pro"))')
    echo "device type: $dt"
    xcv_run "create probe device" xcrun simctl create "$PROBE_NAME" "$dt" "$rt"
    udid=$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for v in d.values() for x in v if x["name"]=="'"$PROBE_NAME"'"))')
    echo "probe udid: $udid"; echo "$udid" > "$STATE"
    xcv_run "boot probe device" xcrun simctl boot "$udid"
    # bootstatus -b can hang after the device has actually booted (E8-iOS finding, HYPOTHESES H4);
    # poll the device list directly instead of trusting bootstatus to terminate.
    xcv_run "wait for Booted (polling simctl list, not bootstatus)" \
      sh -c "for i in \$(seq 1 60); do xcrun simctl list devices | grep -q '$udid.*Booted' && { echo \"booted after \${i}0% of budget (\$((i*5))s)\"; break; }; sleep 5; done"
    xcv_run "probe device state" sh -c "xcrun simctl list devices | grep '$udid'"
    xcv_run "screenshot through the symlinked path" xcrun simctl io "$udid" screenshot /tmp/xcv-e9-screenshot-1.png
    xcv_run "screenshot file produced?" sh -c "ls -l /tmp/xcv-e9-screenshot-1.png 2>&1"
    xcv_run "device data dir resolves through the symlink" sh -c "ls -d '$LINK/Devices/$udid/data' 2>&1"
  } 2>&1 | xcv_redact | tee -a "$out"
  echo "wrote $out"
}

phase2() {
  udid=$(cat "$STATE")
  {
    echo; echo "############################################################"
    e9_header "E9 phase 2: build/run/write cycle + probe cleanup (symlink still in place)"
    xcv_run "symlink still in place?" sh -c "ls -ld '$LINK'; readlink '$LINK'"

    echo "## step 6 — build, install, launch and write a file, all through the symlinked path"
    rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/Sources/E9Probe"
    cat > "$SCRATCH/project.yml" <<'YAML'
name: E9Probe
options:
  bundleIdPrefix: com.xcodevault.e9probe
targets:
  E9Probe:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [Sources/E9Probe]
    info:
      path: Sources/E9Probe/Info.plist
      properties:
        UILaunchScreen: {}
YAML
    cat > "$SCRATCH/Sources/E9Probe/App.swift" <<'SWIFT'
import SwiftUI
@main struct E9ProbeApp: App {
  var body: some Scene { WindowGroup {
    Text("E9 probe").onAppear {
      let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("e9-write-test.txt")
      try? "e9 write ok".write(to: url, atomically: true, encoding: .utf8)
    }
  } }
}
SWIFT
    xcv_run "xcodegen generate" sh -c "cd '$SCRATCH' && xcodegen generate 2>&1 | tail -3"
    xcv_run "xcodebuild build" sh -c "cd '$SCRATCH' && xcodebuild build -project E9Probe.xcodeproj -scheme E9Probe -destination 'id=$udid' -derivedDataPath '$SCRATCH/dd' 2>&1 | tail -12"
    xcv_run "install" xcrun simctl install "$udid" "$SCRATCH/dd/Build/Products/Debug-iphonesimulator/E9Probe.app"
    xcv_run "launch" xcrun simctl launch "$udid" com.xcodevault.e9probe.E9Probe
    sleep 5
    container=$(xcrun simctl get_app_container "$udid" com.xcodevault.e9probe.E9Probe data 2>&1)
    echo "container: $container"
    xcv_run "app actually wrote through the symlink?" \
      sh -c "ls -l '$container/Documents/' 2>&1; echo '--- content ---'; cat '$container/Documents/e9-write-test.txt' 2>&1; echo"
    xcv_run "app still running (did not crash)?" sh -c "xcrun simctl spawn '$udid' launchctl list 2>/dev/null | grep -c e9probe"

    echo "## step 8 — FB12363725 opportunistic read-only check (only CoreSimulator is symlinked,"
    echo "##          NOT ~/Library/Developer — the wider swap is forbidden by CLAUDE.md rule 7)"
    # Existence is checked first on purpose: `[ -L ]` is false for a missing path, so testing
    # only for the symlink would report "real directory" for a path that is not there at all
    # (which is the case on Xcode 26.5 here — DeveloperDiskImages is simply absent).
    xcv_run "DeveloperDiskImages must never be a symlink (CLAUDE.md rule 7)" \
      sh -c "ls -ld '$HOME/Library/Developer/DeveloperDiskImages' 2>&1; \
        if [ -L '$HOME/Library/Developer/DeveloperDiskImages' ]; then echo 'SYMLINK — RULE 7 VIOLATION'; \
        elif [ -d '$HOME/Library/Developer/DeveloperDiskImages' ]; then echo 'real directory (as required)'; \
        else echo 'absent — path does not exist on this Xcode; nothing was symlinked'; fi"
    xcv_run "physical devices still available?" sh -c "xcrun devicectl list devices 2>&1 | tail -5"

    echo "## step 7 — probe cleanup"
    xcv_run "shutdown probe" xcrun simctl shutdown "$udid"
    xcv_run "delete probe" xcrun simctl delete "$udid"
    rm -rf "$SCRATCH"
    xcv_run "scratch project removed" sh -c "ls -d '$SCRATCH' 2>&1 || echo 'removed'"
  } 2>&1 | xcv_redact | tee -a "$out"
  echo "wrote $out"
}

restore() {
  # Mandatory, pass or fail. Never leave $LINK as a symlink at the end of a session.
  {
    echo; echo "############################################################"
    e9_header "E9 step 9-10: restore + validation against the pre-experiment baseline"
    xcv_run "quit Simulator.app" sh -c "osascript -e 'quit app \"Simulator\"' 2>/dev/null; sleep 2; true"
    xcv_run "state before restore" sh -c "ls -ld '$LINK'; readlink '$LINK' 2>&1"
    xcv_run "remove the symlink" rm "$LINK"
    xcv_run "move the real directory back" mv "$REAL" "$LINK"
    xcv_run "confirm it is a real directory again" \
      sh -c "ls -ld '$LINK'; if [ -L '$LINK' ]; then echo 'STILL A SYMLINK — FAILED'; else echo 'confirmed: real directory, not a symlink'; fi; [ -e '$REAL' ] && echo 'WARNING: $REAL still exists' || echo 'CoreSimulator-real gone (good)'"
    xcv_run "restart CoreSimulatorService" \
      sh -c "pkill -9 -f com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null; sleep 3; true"

    echo "## step 10 — validation: must match the pre-experiment baseline exactly"
    xcv_run "devices" xcrun simctl list devices
    xcv_run "runtimes" xcrun simctl runtime list
    xcv_run "unavailable device count (expect 0)" sh -c "xcrun simctl list devices | grep -ci unavailable"
    xcv_run "size unchanged (expect ~9.1G)" du -sh "$LINK"
    xcv_run "doctor" sh -c "cd '$XCV_ROOT' && .build/debug/xcodevaultctl doctor 2>&1 | tail -25"
  } 2>&1 | xcv_redact | tee -a "$out"
  echo "wrote $out"
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  restore) restore ;;
  *) echo "usage: $0 {phase1|phase2|restore}" >&2; exit 2 ;;
esac
