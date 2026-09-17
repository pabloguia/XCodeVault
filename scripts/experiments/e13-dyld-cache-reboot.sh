#!/bin/bash
# E13 — is an orphaned dyld shared cache reaped at startup?
#
# Motivation: F10 found 2.3 GiB under Caches/dyld/<hostBuild>/inc/<runtimeIdentifier> belonging to a
# runtime that is no longer installed. The open question is not whether it is garbage — nothing can
# rebuild a cache for an absent runtime — but whether the system already collects it, because that
# decides what `doctor` should tell the user to do.
#
# Why this probe and not a sudo one. The closest analogue in this repo is the stranded runtime Inbox
# .dmg (FINDINGS, 2026-09-06): root deletion was refused three times with Operation not permitted,
# and a REBOOT reclaimed the file — the reaper is a startup GC. Reasoning from "no BSD flags +
# absent from rootless.conf" to "root can delete it" has already been wrong once here, on a path
# with exactly those properties.
#
# RESULT, 2026-09-16 (this machine, macOS 26.6.2 / 25G83): the orphan SURVIVED. Captured at 10:00,
# rebooted at 10:12, captured again at 15:58 — the whole cache tree byte-identical, including the
# newest write inside the orphan. Branch two below. The startup reaper does not cover inc/.
#   evidence/e13-dyld-reboot-20260916T100005.txt  (before)
#   evidence/e13-dyld-reboot-20260916T155821.txt  (after)
#
# An earlier version of this header claimed the orphan "was created after the machine's last boot,
# so it has survived simulator boots but never a restart". That was true when written on 2026-09-09
# and false by the time the probe ran: the orphan is from Sep 7 and the machine had booted on Sep 15,
# so it had already outlived one restart before this experiment bracketed a second. Left recorded
# rather than deleted — the premise is the kind that goes stale silently, and a reader who re-runs
# this on another machine should re-derive it from their own capture rather than from this comment.
#
# Still worth running elsewhere: one machine, one host build, one orphan.
#
# READ-ONLY. No sudo, no deletion, nothing mounted or unmounted. Run it, restart, run it again, diff.
set -u

STAMP=$(date +%Y%m%dT%H%M%S)
OUT=${XCV_E13_OUT:-docs/research/evidence/e13-dyld-reboot-$STAMP.txt}
ROOT=/Library/Developer/CoreSimulator/Caches/dyld

# The header the other experiments print via common.sh, inlined: common.sh runs `sudo -n true` to
# report privilege state, and this experiment promises no sudo at all — including a probe of it.
#
# common.sh is nonetheless *sourced* below, for xcv_redact alone. Sourcing runs no command: only
# xcv_header probes sudo, and this script never calls it. Evidence is published (ADR-0005), and
# this was one of two experiments writing into the evidence directory unredacted.
source "$(dirname "$0")/common.sh"
{
  echo "E13 — dyld cache startup-reap probe"
  echo "date:        $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "macOS:       $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "arch:        $(uname -m)"
  echo "xcode:       $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "boottime:    $(sysctl -n kern.boottime)"
  echo "uptime:      $(uptime)"
  echo "repo:        $(git -C "$(dirname "$0")/../.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo
  echo "== installed runtimes (simctl runtime list) =="
  xcrun simctl runtime list 2>&1 || echo "(simctl failed)"
  echo
  echo "== cache tree =="
  if [ ! -d "$ROOT" ]; then
    echo "(no $ROOT — nothing to probe)"
  else
    for build in "$ROOT"/*; do
      [ -d "$build" ] || continue
      echo "-- $build"
      ls -lO "$build" 2>&1
      for sub in "$build"/*; do
        [ -d "$sub" ] || continue
        echo "   $(basename "$sub"): $(du -shx "$sub" 2>/dev/null | cut -f1)  mtime=$(stat -f '%Sm' "$sub")  birth=$(stat -f '%SB' "$sub")"
        if [ "$(basename "$sub")" = "inc" ]; then
          for pending in "$sub"/*; do
            [ -d "$pending" ] || continue
            echo "     inc/$(basename "$pending"): $(du -shx "$pending" 2>/dev/null | cut -f1)  mtime=$(stat -f '%Sm' "$pending")  birth=$(stat -f '%SB' "$pending")"
            # Newest write anywhere inside: the directory's own mtime freezes while a build is still
            # writing into its files, so it alone cannot distinguish "abandoned" from "in progress".
            newest=$(find "$pending" -type f -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1)
            echo "       newest file write: ${newest:-none}"
            ls -lO "$pending" 2>&1 | sed 's/^/       /'
          done
        fi
      done
    done
  fi
  echo
  echo "== totals =="
  echo "cache tree:     $(du -shx "$ROOT" 2>/dev/null | cut -f1 || echo n/a)"
  echo "internal free:  $(df -h / | tail -1 | awk '{print $4}')"
  echo
  echo "== how to read this =="
  echo "Run before restarting, restart, run again, then diff the two files."
  echo "  gone after the restart      -> the startup reaper covers inc/. F10 becomes 'transient"
  echo "                                 until restart' and doctor should say only 'restart', no sudo."
  echo "  still there, same size      -> the Inbox reaper does not cover this path. Only now is the"
  echo "                                 root-deletion probe (E13b) worth running."
  echo "  still there but smaller, or -> CoreSimulator is treating it as a resumable build. That"
  echo "  newest file write moved        falsifies the 'interrupted, abandoned' reading in F10 and"
  echo "                                 argues for widening doctor's one-hour in-flight guard."
} | xcv_redact | tee "$OUT"

echo
echo "Written to $OUT"
