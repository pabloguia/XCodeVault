#!/bin/bash
# Shared helpers for the gating experiments in docs/architecture/EXPERIMENTS.md.
# Every evidence file starts with the environment header required by that doc.

XCV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XCV_EVIDENCE_DIR="$XCV_ROOT/docs/research/evidence"

xcv_env_slug() {
  local macos build arch xcode
  macos=$(sw_vers -productVersion)
  build=$(sw_vers -buildVersion)
  arch=$(uname -m)
  xcode=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')
  echo "macos${macos}-${build}-xcode${xcode}-${arch}"
}

xcv_header() {
  echo "# Experiment: $1"
  echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "# Arch: $(uname -m)"
  echo "# Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "# xcode-select: $(xcode-select -p)"
  echo "# Runner: $(id -un) (uid $(id -u)); sudo available: $(sudo -n true 2>/dev/null && echo yes || echo no)"
  echo
}

# xcv_run <label> <cmd...>  — prints the command, runs it, prints exit code. Never aborts.
xcv_run() {
  local label="$1"; shift
  echo "## $label"
  echo "\$ $*"
  "$@" 2>&1
  echo "[exit=$?]"
  echo
}

# Never clobber a prior run's evidence: rotate it aside, named by its own mtime. On 2026-09-15
# a re-run of E14b overwrote the previous attempt's file, and two docs went on citing a path
# whose contents had changed underneath them.
xcv_rotate_out() {
  local out="$1" stamp target n
  # -f, not -e: a directory or dangling symlink at $OUT is not something to rotate, and the
  # caller's `> "$OUT"` would behave badly anyway — say so rather than silently continuing.
  if [ -e "$out" ] && [ ! -f "$out" ]; then
    echo "REFUSING: $out exists and is not a regular file." >&2; return 1
  fi
  [ -f "$out" ] || return 0
  stamp=$(stat -f %Sm -t %Y%m%dT%H%M%S "$out")
  target="${out%.txt}-superseded-$stamp.txt"
  # Two runs whose evidence files share an mtime to the second would rotate onto the same name
  # and the first would be destroyed — the exact loss this helper exists to prevent.
  n=2
  while [ -e "$target" ]; do
    target="${out%.txt}-superseded-$stamp-$n.txt"
    n=$((n + 1))
    [ "$n" -gt 50 ] && { echo "REFUSING: cannot find a free rotation name for $out." >&2; return 1; }
  done
  if ! mv "$out" "$target"; then
    echo "REFUSING: could not rotate $out aside; not overwriting it." >&2; return 1
  fi
  echo "rotated previous evidence to $target" >&2
}

# Redact the invoking user's home directory and short name in evidence output.
#
# -l keeps sed line-buffered: without it an interrupted experiment loses everything still
# sitting in the buffer and leaves a 0-byte evidence file, which is the run that most needs one.
#
# Under `sudo` the naive version corrupted the file it was meant to protect. `id -un` is `root`
# there, so `s#root#<user>#g` rewrote every occurrence of the WORD root — "root-owned" became
# "<user>-owned", /var/root became /var/<user> — in exactly the experiments whose subject is root
# (E13b). Meanwhile `$HOME` was /var/root, so the user's real home was not redacted at all: the
# substitution was both destructive and ineffective. So: resolve the identity to redact from
# SUDO_USER *when actually running as root* (see the third defect below), and never substitute the
# name `root`, which is a subject in these experiments and not an identity to hide.
# Three further defects, found in review on the same day and all the same family as the one above —
# a substitution that is broader than the thing it means to hide:
#   - `awk '{print $2}'` truncated a home containing a space (/Users/two words -> /Users/two), and the
#     -d test below then fell back to $HOME, which under sudo is root's. The real home went unredacted:
#     exactly the failure the rewrite existed to end.
#   - the username substitution was unanchored, so a short name ate words. With u=dev, `devicectl`
#     became `<user>icectl`. `root` got a special case; dev, sim, core, test, admin, ci did not.
#   - SUDO_USER was trusted whether or not this was a sudo session, so an inherited value redacted
#     the wrong identity in an ordinary non-root run of e1/e2/e8.
xcv_redact() {
  local u h esc
  if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then u="$SUDO_USER"; else u=$(id -un); fi
  h=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [ -n "$h" ] && [ -d "$h" ] || h="$HOME"
  # The home goes into a regex, so its metacharacters have to stop being metacharacters. A dot in a
  # username (john.doe) is the realistic case; a # would break the expression outright.
  esc=$(printf '%s' "$h" | sed 's/[][\.*^$#\/]/\\&/g')
  if [ "$u" = "root" ]; then
    sed -l -e "s#$esc#~#g"
  else
    # [[:<:]] / [[:>:]] are BSD sed word boundaries: redact the name, not every word containing it.
    sed -l -e "s#$esc#~#g" -e "s#[[:<:]]$u[[:>:]]#<user>#g"
  fi
}
