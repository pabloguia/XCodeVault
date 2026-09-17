#!/bin/bash
# E12 — does developer data survive on a case-sensitive APFS volume?
#
# Motivation: VolumeQualification warns "Case-sensitive APFS: Xcode projects that rely on
# case-insensitive paths may break." That warning was written from first principles, never tested.
# The user's actual destination drive is Case-sensitive APFS, so the warning gates a real decision:
# if build output or dependency source breaks there, the drive is unusable for those categories and
# the product should say so instead of shrugging.
#
# What is and is not being tested. macOS ships case-INsensitive APFS by default, so the interesting
# combination is the product's own: source stays on the internal case-insensitive volume while
# XCodeVault relocates build products elsewhere. Two surfaces are exercised:
#   A. SwiftPM `--scratch-path` on the case-sensitive volume. This also puts dependency *source*
#      (`checkouts/`, `repositories/`) there, which is the riskier half — a package with
#      case-inconsistent internal references breaks when its source is case-sensitive, not when
#      its output is.
#   B. `xcodebuild -derivedDataPath` on the case-sensitive volume, source left on the internal one.
#
# Runs entirely on a disposable `hdiutil` sparse image. No sudo, and the user's real drive is never
# touched. Note the image mounts `noowners` by default — an incidental demonstration of F5, and the
# reason `volumes` reports it `unsuitable`; irrelevant to the case-sensitivity question itself.
set -u
source "$(dirname "$0")/common.sh"

# Mounted at a private path, never /Volumes/<name>: if anything were already mounted at
# /Volumes/XCVE12 the image would land at "/Volumes/XCVE12 1" and every write below — plus both
# cleanup detaches — would hit that FOREIGN volume instead. The script header promises the
# user's drive is never touched; a name is not enough to promise it.
IMG=${XCV_E12_IMAGE:-/private/tmp/xcv-e12}
VOL=${XCV_E12_MOUNT:-/private/tmp/xcv-e12-mnt}
SCRATCH=${XCV_E12_SCRATCH:-/private/tmp/xcv-e12-scratch}

# The header above promises the user's drive is never touched, and then reads three paths from
# the environment that cleanup() feeds to `rm -rf`, `hdiutil detach` and `rmdir`. Make the promise
# true instead of assuming it.
for v in "$IMG" "$VOL" "$SCRATCH"; do
  case "$v" in /private/tmp/xcv-e12*) ;; *) echo "refusing: '$v' is outside /private/tmp/xcv-e12*" >&2; exit 1;; esac
done
out="$XCV_EVIDENCE_DIR/e12-case-sensitivity-$(xcv_env_slug).txt"

cleanup() {
  hdiutil detach "$VOL" -quiet 2>/dev/null || true
  rmdir "$VOL" 2>/dev/null || true
  rm -f "$IMG.sparseimage"
  rm -rf "$SCRATCH"
}
# `cleanup` above stays REPEATABLE on purpose: the body calls it twice by design, once to clear
# leftovers before setup and once as teardown. An idempotence guard belongs on the trap handler, not
# on cleanup itself — putting it on cleanup would turn the teardown call into a no-op.
FINISHED=0
on_exit() {
  [ "$FINISHED" = "1" ] && return 0
  FINISHED=1
  cleanup
  # Redaction used to happen in the pipeline; it happens here, over whatever the run produced —
  # including a partial transcript from an interrupted run, which says what happened where a missing
  # one says nothing.
  if [ -f "$out.raw" ]; then
    xcv_redact < "$out.raw" > "$out" 2>/dev/null && rm -f "$out.raw" 2>/dev/null
  fi
}

progress() { echo "$*" >&3 2>/dev/null; }

# The body is a FUNCTION called with a redirect, not a brace group in a pipeline.
#
# Measured 2026-09-17 with scripts/harness-trap-bench.sh: a brace group in a pipeline is a subshell,
# and a trap did not run there on any interruption — Ctrl-C or SIGTERM, and whichever side of the
# `{` the trap was written on. The comment this replaces said "without this, Ctrl-C during the build
# leaves the image attached", and the trap it described could not do that. A function call with a
# redirect does not fork, so the shell holding the trap is the shell receiving the signal.
#
# With SIGTERM the handler is deferred until the current foreground command finishes, so an
# interrupt during the xcodebuild below waits for that build. Ctrl-C is prompt, because the signal
# reaches the foreground child too.
e12_main() {
  echo "# Experiment: E12 — developer data on case-sensitive APFS"
  echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "# Arch: $(uname -m)"
  echo "# Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "# Script: scripts/experiments/e12-case-sensitivity.sh @ $(git -C "$XCV_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "# Runner: $(id -un); sudo: not used — hdiutil needs no privileges for a sparse image"
  echo

  xcv_run "internal volume is case-insensitive (the baseline this is measured against)" \
    sh -c "diskutil info / | grep -i 'File System Personality' | sed 's/^ *//'"

  progress "== setup: disposable case-sensitive APFS image"
  echo "## setup — disposable case-sensitive APFS image"
  cleanup
  xcv_run "create" hdiutil create -size 6g -fs "Case-sensitive APFS" -volname XCVE12 -type SPARSE "$IMG"
  mkdir -p "$VOL"
  xcv_run "attach at a private mount point" hdiutil attach "$IMG.sparseimage" -nobrowse -mountpoint "$VOL"
  xcv_run "confirm we are on the image we just made, not somebody else's volume" \
    sh -c "diskutil info '$VOL' | grep -i 'Volume Name' | sed 's/^ *//'"
  # Asserted, not merely recorded: xcv_run never aborts and there is no `set -e`, so a failed
  # attach would otherwise send every write below to a plain directory on the INTERNAL disk and
  # the evidence would claim case-sensitive results measured on a case-insensitive volume.
  if ! diskutil info "$VOL" 2>/dev/null | grep -qi "Case-sensitive APFS"; then
    echo "ABORT: $VOL is not a mounted case-sensitive APFS volume — refusing to record results" >&2
    exit 1
  fi
  xcv_run "what we got" sh -c "diskutil info $VOL | grep -Ei 'File System Personality|Owners|Mount Point' | sed 's/^ *//'"

  echo "## control — prove the two volumes really differ, rather than assuming it"
  xcv_run "two names differing only in case, on the case-sensitive volume" \
    sh -c "mkdir -p $VOL/casecheck && printf 'lower\n' > $VOL/casecheck/probe.txt && printf 'upper\n' > $VOL/casecheck/PROBE.txt && ls $VOL/casecheck/"
  xcv_run "the same two names on the internal case-insensitive volume" \
    sh -c "d=\$(mktemp -d); printf 'lower\n' > \$d/probe.txt; printf 'upper\n' > \$d/PROBE.txt; ls \$d; echo '--- surviving content ---'; cat \$d/probe.txt; rm -rf \$d"

  echo "## case A — SwiftPM: build output AND dependency source on the case-sensitive volume"
  xcv_run "swift build --scratch-path" sh -c "cd '$XCV_ROOT' && swift build --scratch-path $VOL/spm-build 2>&1 | tail -4"
  xcv_run "dependency source was cloned there (this is the risky half)" sh -c "ls $VOL/spm-build/checkouts/ $VOL/spm-build/repositories/ 2>&1"
  xcv_run "the produced binary runs" sh -c "$VOL/spm-build/debug/xcodevaultctl --version"

  echo "## case B — xcodebuild: source on the internal volume, DerivedData on the case-sensitive one"
  mkdir -p "$SCRATCH/Sources/E12Probe"
  cat > "$SCRATCH/project.yml" <<'YAML'
name: E12Probe
options:
  bundleIdPrefix: com.xcodevault.e12probe
targets:
  E12Probe:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [Sources/E12Probe]
    info:
      path: Sources/E12Probe/Info.plist
      properties:
        UILaunchScreen: {}
YAML
  cat > "$SCRATCH/Sources/E12Probe/App.swift" <<'SWIFT'
import SwiftUI
@main struct E12ProbeApp: App {
  var body: some Scene { WindowGroup { Text("E12 probe") } }
}
SWIFT
  progress "== case B: xcodebuild -derivedDataPath on the case-sensitive volume"
  xcv_run "xcodegen" sh -c "cd '$SCRATCH' && xcodegen generate 2>&1 | tail -1"
  xcv_run "xcodebuild -derivedDataPath" \
    sh -c "cd '$SCRATCH' && xcodebuild build -project E12Probe.xcodeproj -scheme E12Probe -destination 'generic/platform=iOS Simulator' -derivedDataPath $VOL/DerivedData 2>&1 | tail -4"
  xcv_run "the .app was produced on the case-sensitive volume" sh -c "ls -d $VOL/DerivedData/Build/Products/Debug-iphonesimulator/E12Probe.app"

  xcv_run "bytes written to the case-sensitive volume" du -sh "$VOL/spm-build" "$VOL/DerivedData"

  progress "== teardown"
  echo "## teardown"
  cleanup
  xcv_run "image detached and removed" sh -c "ls -d $VOL 2>&1 || echo 'volume gone'; ls -l $IMG.sparseimage 2>&1 || echo 'image gone'"
}

exec 3>&2                      # console handle, kept because stdout is about to become a file
trap 'on_exit' EXIT INT TERM HUP

e12_main > "$out.raw" 2>&1
E12_RC=$?

on_exit
[ -f "$out" ] || echo "!! no transcript was produced" >&2
if [ -f "$out" ]; then
  grep -E '^(## |\*\* |!!)' "$out" | head -30
fi
echo "wrote $out"
exit "$E12_RC"
