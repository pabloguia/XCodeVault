#!/bin/bash
# E21 — does `simctl runtime add` rebuild that runtime's dyld shared cache? (H11, H14)
#
# The lead (HYPOTHESES.md H14, E6b pre-registration): the watchOS 26.5 cache under
# /Library/Developer/CoreSimulator/Caches/dyld/<hostBuild>/ was born 2026-10-23 20:22–20:24 local,
# within minutes of E20 arm 3's `simctl runtime delete` + `simctl runtime add` of that runtime. That
# run did not watch the cache, so the timing is a lead, not a reading. This script watches it.
#
# Sequence (phase `run`), every step printed with its exit status:
#   1. guards: not root; no xcodebuild, launchd_sim or Simulator.app; the runtime named by --runtime is
#      listed and Ready; free space on the data volume >= image size + 4 GB.
#   2. snapshot: runtime list, and the cache tree (size, birth, mtime, newest write per entry).
#   3. clone the runtime's image into ~/.xcodevault-e21-scratch with `cp -c` (APFS clonefile; the
#      free-space delta is printed to show no copy was made). The image is only read.
#   4. `simctl runtime delete <UUID>` — the runtime and, per E20, its cache go.
#   5. control window, CONTROL_MIN minutes, no request of any kind: probe the cache every 30 s.
#   6. `simctl runtime add <clone>`, timed; then probe every 30 s for up to WATCH_MIN minutes, stopping
#      early once the runtime's cache exists and its size is unchanged for three probes.
#   7. end state: the runtime Ready with its build, the clone removed only then.
# A `log stream` for shared-cache messages runs from step 4 to the end; matching lines are appended.
#
# NOT read-only. It deletes and re-adds a real runtime in the default runtime store, which every
# simulator on the machine uses — run it only with the operator's go-ahead and the rigs idle. It never
# uses sudo, never deletes the internal image before the clone exists, and never removes the clone
# unless the runtime is back and Ready. If the add fails, the clone stays and the exact re-add command
# is printed.
#
# Phases:
#   inspect                               read-only: guards and snapshot, nothing changed
#   run --runtime <UUID> --i-understand   the sequence above
set -u
source "$(dirname "$0")/common.sh"

PHASE=${1:-}; shift || true
RUNTIME=""; OK=0
CONTROL_MIN=${XCV_E21_CONTROL_MIN:-5}
WATCH_MIN=${XCV_E21_WATCH_MIN:-30}
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME=${2:-}; shift 2 ;;
    --i-understand) OK=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$PHASE" in inspect|run) ;; *) echo "usage: $0 inspect | run --runtime <UUID> --i-understand" >&2; exit 2 ;; esac
if [ "$(id -u)" = 0 ]; then
  echo "REFUSING: run as yourself. simctl as root addresses root's device set." >&2; exit 2
fi
if [ "$PHASE" = run ] && { [ -z "$RUNTIME" ] || [ "$OK" != 1 ]; }; then
  echo "REFUSING: run needs --runtime <UUID> and --i-understand." >&2; exit 2
fi

CACHE=/Library/Developer/CoreSimulator/Caches/dyld
IMAGES=/Library/Developer/CoreSimulator/Images
SCRATCH="$HOME/.xcodevault-e21-scratch"
OUT="$XCV_EVIDENCE_DIR/e21-dyld-rebuild-$PHASE-$(xcv_env_slug).txt"
xcv_rotate_out "$OUT" || exit 2
LOGTMP=$(mktemp -t xcv-e21-log)
LOGPID=""
cleanup() { [ -n "$LOGPID" ] && kill "$LOGPID" 2>/dev/null; rm -f "$LOGTMP"; }
trap cleanup EXIT

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
busy() { pgrep -x xcodebuild >/dev/null || pgrep -x launchd_sim >/dev/null || pgrep -x Simulator >/dev/null; }
busy_list() { pgrep -xl xcodebuild; pgrep -xl launchd_sim; pgrep -xl Simulator; }
free_kb() { df -k /System/Volumes/Data | awk 'NR==2{print $4}'; }

# Every entry under the cache, two levels down: size, birth, mtime, and the newest file write inside.
# A directory's own mtime freezes once its entries exist while the build keeps writing (E13).
tree() {
  local d newest
  for d in "$CACHE"/*/ "$CACHE"/*/*/ "$CACHE"/*/inc/*/; do
    [ -d "$d" ] || continue
    newest=$(find "$d" -type f -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1)
    printf '   %s  %s  born=%s  mtime=%s  newest=%s\n' "$(du -sh "$d" 2>/dev/null | cut -f1)" "${d#$CACHE/}" \
      "$(stat -f %SB -t %FT%T "$d")" "$(stat -f %Sm -t %FT%T "$d")" \
      "${newest:+$(date -r "$newest" +%FT%T)}"
  done | sort -u
}

# The runtime's own cache directory, found by its platform-and-version slug (as named by simdiskimaged:
# com.apple.CoreSimulator.SimRuntime.<platform>-<major>-<minor>.<build>). Empty if absent.
SLUG=""
cache_dir() { [ -n "$SLUG" ] || return 0; find "$CACHE" -maxdepth 3 -type d -name "*.$SLUG" 2>/dev/null | sort | head -1; }
cache_kb() { local d; d=$(cache_dir); [ -n "$d" ] && du -sk "$d" 2>/dev/null | cut -f1; }

probe() {
  local d; d=$(cache_dir)
  printf '   %s  cache=%s  size_kb=%s  busy=%s\n' "$(now)" "${d:-absent}" "$(cache_kb || true)" \
    "$(busy && busy_list | tr '\n' ' ' || echo none)"
}

{
  xcv_header "E21 — does simctl runtime add rebuild the runtime's dyld shared cache? (phase $PHASE)"
  echo "# Target runtime: ${RUNTIME:-<none named>}; control ${CONTROL_MIN} min; watch ${WATCH_MIN} min"
  echo
  xcv_run "runtime list" xcrun simctl runtime list
  echo "## busy check"
  if busy; then busy_list | sed 's/^/   /'; echo "   BUSY"; else echo "   idle (no xcodebuild, launchd_sim, Simulator)"; fi
  echo
  echo "## cache tree before"; tree; echo
  echo "## free on data volume: $(( $(free_kb) / 1024 )) MB"; echo
} 2>&1 | xcv_redact > "$OUT"

if [ "$PHASE" = inspect ]; then echo "inspect written to $OUT"; exit 0; fi

say() { echo "$*" | xcv_redact >> "$OUT"; }
refuse() { say "REFUSED: $*"; echo "REFUSED: $*" >&2; exit 3; }

busy && refuse "a simulator or xcodebuild is running; the rigs must be idle"
line=$(xcrun simctl runtime list | /usr/bin/grep -F -- "$RUNTIME")
[ -n "$line" ] || refuse "runtime $RUNTIME is not listed"
case "$line" in *"(Ready)"*) ;; *) refuse "runtime $RUNTIME is not Ready: $line" ;; esac
IMG="$IMAGES/$RUNTIME.dmg"
[ -f "$IMG" ] || refuse "no image at $IMG"
# "watchOS 26.5 (23T570) - <UUID> (Ready)" -> watchOS-26-5.23T570
SLUG=$(echo "$line" | sed -nE 's/^([A-Za-z]+) ([0-9]+)\.([0-9]+)(\.[0-9]+)? \(([A-Z0-9a-z]+)\).*/\1-\2-\3.\5/p')
[ -n "$SLUG" ] || refuse "could not read platform/version/build from: $line"
img_kb=$(( $(stat -f %z "$IMG") / 1024 ))
[ "$(free_kb)" -ge $(( img_kb + 4 * 1024 * 1024 )) ] || refuse "less than image size + 4 GB free"
[ -e "$SCRATCH" ] && refuse "$SCRATCH exists from an earlier run; inspect it before removing it"
say "## target: $line"; say "   cache slug: $SLUG; cache dir now: $(cache_dir || true)"; say ""

mkdir "$SCRATCH" || refuse "cannot create $SCRATCH"
before=$(free_kb)
{ xcv_run "clone the image (APFS clonefile, read-only on the source)" cp -c "$IMG" "$SCRATCH/$RUNTIME.dmg"; } 2>&1 | xcv_redact >> "$OUT"
CLONE="$SCRATCH/$RUNTIME.dmg"
if [ ! -f "$CLONE" ] || [ "$(stat -f %z "$CLONE")" != "$(stat -f %z "$IMG")" ]; then
  refuse "clone missing or a different size; nothing deleted"
fi
say "   free-space delta for the clone: $(( (before - $(free_kb)) / 1024 )) MB (a copy would be ~$(( img_kb / 1024 )) MB)"; say ""

log stream --style compact --info --debug \
  --predicate 'eventMessage CONTAINS[c] "shared cache" OR eventMessage CONTAINS[c] "dyld_shared_cache" OR eventMessage CONTAINS[c] "DYLDSharedCache"' \
  > "$LOGTMP" 2>&1 &
LOGPID=$!

say "## delete at $(now)"
{ xcv_run "runtime delete" xcrun simctl runtime delete "$RUNTIME"; } 2>&1 | xcv_redact >> "$OUT"
for _ in $(seq 1 30); do xcrun simctl runtime list | /usr/bin/grep -qF -- "$RUNTIME" || break; sleep 2; done
say "   listed after delete: $(xcrun simctl runtime list | /usr/bin/grep -cF -- "$RUNTIME")"
say "## cache tree after delete"; tree | xcv_redact >> "$OUT"; say ""

say "## control window: ${CONTROL_MIN} min, no request"
for _ in $(seq 1 $(( CONTROL_MIN * 2 ))); do probe | xcv_redact >> "$OUT"; sleep 30; done
say ""

say "## add at $(now)"
t0=$(date +%s)
{ xcv_run "runtime add (from the clone, not --move)" xcrun simctl runtime add "$CLONE"; } 2>&1 | xcv_redact >> "$OUT"
say "   add took $(( $(date +%s) - t0 )) s"
newline=$(xcrun simctl runtime list | /usr/bin/grep -E "\(${SLUG##*.}\).*\(Ready\)")
if [ -z "$newline" ]; then
  say "!! the runtime is not back and Ready. The clone is KEPT. Re-add by hand:"
  say "   xcrun simctl runtime add '$CLONE'"
  { xcrun simctl runtime list; } 2>&1 | xcv_redact >> "$OUT"
  exit 4
fi
say "   back: $newline"; say ""

say "## watch: every 30 s up to ${WATCH_MIN} min, stop after 3 equal non-zero sizes"
last=""; same=0
for _ in $(seq 1 $(( WATCH_MIN * 2 ))); do
  probe | xcv_redact >> "$OUT"
  kb=$(cache_kb || true)
  if [ -n "$kb" ] && [ "$kb" != 0 ] && [ "$kb" = "$last" ]; then same=$((same + 1)); else same=0; fi
  last=$kb
  [ "$same" -ge 3 ] && break
  sleep 30
done
say ""
say "## cache tree at end"; tree | xcv_redact >> "$OUT"; say ""

kill "$LOGPID" 2>/dev/null; LOGPID=""
say "## log stream, shared-cache lines ($(wc -l < "$LOGTMP" | tr -d ' ') lines; first 200)"
head -200 "$LOGTMP" | xcv_redact >> "$OUT"; say ""

{ xcv_run "runtime list at end" xcrun simctl runtime list; } 2>&1 | xcv_redact >> "$OUT"
rm -f "$CLONE" && rmdir "$SCRATCH" && say "clone removed (runtime is back and Ready)"
say "# done $(now)"
echo "evidence: $OUT"
