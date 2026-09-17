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

# Escape a literal string for use on the left-hand side of a sed s### expression. The `#`
# delimiter is included because these substitutions use it, and a volume label may legitimately
# contain one. A dot in a username (john.doe) is the realistic case; an unescaped `#` would
# break the expression outright.
xcv_re_escape() { printf '%s' "$1" | sed 's/[][\.*^$#\/]/\\&/g'; }

# The directory scanned for volumes and the UUID lookup are indirected so the tests can drive
# xcv_redact against a fixture tree instead of whatever happens to be plugged into the machine
# running them. The defaults are the real ones: detection is what you get when nobody configures
# anything, which is the property that matters.
XCV_VOLUMES_DIR="${XCV_VOLUMES_DIR:-/Volumes}"
xcv_volume_uuid() { diskutil info "$1" 2>/dev/null | sed -n 's/^ *Volume UUID: *//p' | head -1; }

# The identity to redact, as two lines: short name, then home directory. Split out for the same
# reason as the two above — every one of the defects listed against xcv_redact below was a defect
# in *this* resolution, and none of them was reachable by a test while it was inlined.
xcv_identity() {
    local u h
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then u="$SUDO_USER"; else u=$(id -un); fi
    h=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
    [ -n "$h" ] && [ -d "$h" ] || h="$HOME"
    printf '%s\n%s\n' "$u" "$h"
}

# Redact the invoking user's home directory and short name in evidence output, along with the
# labels and UUIDs of any mounted volumes and any folders named in XCV_PRIVATE_DIRS.
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
#
# Extended 2026-09-17 (ADR-0005). Evidence files are now published, so the volume label, the
# volume UUID and private folder names are no longer tidiness — they are the publication surface.
#
# Volumes are DETECTED, not configured. A redactor that has to be remembered is one that leaks the
# single time it is forgotten, and every future evidence file is public. Every mount under
# /Volumes is somebody's drive: its label and UUID are redacted. This does not touch the findings
# that name a runtime volume, because CoreSimulator mounts those under
# /Library/Developer/CoreSimulator/Volumes, not /Volumes — E1 and E8 are unaffected.
#
# The boot volume is redacted too, as <bootvolume> rather than <vault>: it is not a vault, but its
# name is just as personal, and the `/Volumes/<bootname>` finding survives the substitution intact.
#
# **The limit of detection, stated plainly.** It can only see what is mounted when it runs. A
# volume that was attached during the experiment but unplugged before the transcript is filtered
# is not detected, and a stale mention of a volume that is no longer attached passes through
# untouched. So this fails closed for mounted volumes and open for everything else. Filter the
# transcript while the volume is still attached; for an experiment that ends by ejecting it, that
# means redacting before the eject, not after.
#
# Two escape hatches, both whitespace-separated lists of single tokens:
#   XCV_REDACT_KEEP   volume labels to leave alone. Needed when a label is also an ordinary word —
#                     a drive named "Backup" would otherwise redact the word backup everywhere —
#                     or when the label is deliberately part of the finding.
#   XCV_PRIVATE_DIRS  folder basenames to redact as <private-dir>.
xcv_redact() {
    local u h esc vol label uuid lesc lb rb k ident
    ident=$(xcv_identity)
    u=${ident%%$'\n'*}
    h=${ident#*$'\n'}
    esc=$(xcv_re_escape "$h")

    # The home is a path PREFIX, not a word. Unanchored, `/Users/dev` rewrites `/Users/devops`
    # into `~ops` — the same "substitution broader than the thing it hides" defect that was found
    # and fixed for the account name on the next line, and left in place one line above it.
    # Anchored to a following non-word character or to end of line.
    local -a args=(-l -e "s#$esc\([^[:alnum:]_]\)#~\1#g" -e "s#$esc\$#~#g")
    # [[:<:]] / [[:>:]] are BSD sed word boundaries: redact the name, not every word containing it.
    [ "$u" = "root" ] || args+=(-e "s#[[:<:]]$(xcv_re_escape "$u")[[:>:]]#<user>#g")

    # Both lists are whitespace-separated single tokens. `read -ra` splits on IFS without pathname
    # expansion — an unquoted `for` over the raw variable would glob against the working directory —
    # and comparing tokens exactly stops a KEEP entry of "My Vault" from also keeping a volume
    # called "My". A label containing a space cannot be expressed in either list.
    local -a keeps=() priv=()
    [ -n "${XCV_REDACT_KEEP:-}" ] && read -ra keeps <<< "$XCV_REDACT_KEEP"
    [ -n "${XCV_PRIVATE_DIRS:-}" ] && read -ra priv <<< "$XCV_PRIVATE_DIRS"

    for vol in "$XCV_VOLUMES_DIR"/*; do
        # An unmatched glob leaves the pattern itself; a dangling mount point is not a volume.
        [ -e "$vol" ] || continue
        label=${vol##*/}
        [ -n "$label" ] || continue

        # The UUID rule is emitted BEFORE XCV_REDACT_KEEP is consulted. KEEP exists because a label
        # can be an ordinary English word; a volume UUID never is, and it is precisely the
        # identifier the docs tell you to use in place of the name. Opting a label out must not
        # silently opt out the hardware identifier standing behind it.
        uuid=$(xcv_volume_uuid "$vol")
        [ -n "$uuid" ] && args+=(-e "s#$(xcv_re_escape "$uuid")#<vault-uuid>#g")

        # `${#a[@]}` rather than expanding directly: macOS ships bash 3.2, where "${a[@]}" on an
        # empty array is an unbound-variable error under `set -u`.
        if [ ${#keeps[@]} -gt 0 ]; then
            for k in "${keeps[@]}"; do [ "$k" = "$label" ] && continue 2; done
        fi
        lesc=$(xcv_re_escape "$label")

        # The boot volume is redacted in its `/Volumes/` form ONLY, and never as a bare label.
        # Its name is an ordinary path component: on a machine whose boot volume is called `MacOS`,
        # a bare-label rule rewrites every `Contents/MacOS/` in every bundle path — including the
        # binary paths that ARE the finding in E14a, E14b and E13b. Word boundaries do not save it,
        # because `/` is not a word character. Redacting a name is not worth destroying evidence.
        if [ -L "$vol" ] && [ "$(readlink "$vol")" = "/" ]; then
            args+=(-e "s#/Volumes/$lesc#/Volumes/<bootvolume>#g")
            continue
        fi

        # A word boundary only fires where the label's own edge is a word character: [[:<:]] needs
        # one to its right, [[:>:]] one to its left. A label like `Backup.` or `-Drive` has a
        # non-word edge, so the boundary there matches nothing and the whole bare-label rule
        # silently does nothing. Emit each boundary only where it can fire; where it cannot, the
        # label's own punctuation is the delimiter and the rule over-redacts rather than leaking.
        case "$label" in [[:alnum:]_]*) lb='[[:<:]]' ;; *) lb='' ;; esac
        case "$label" in *[[:alnum:]_]) rb='[[:>:]]' ;; *) rb='' ;; esac
        args+=(-e "s#/Volumes/$lesc#/Volumes/<vault>#g" -e "s#$lb$lesc$rb#<vault>#g")
    done

    for label in ${priv[@]+"${priv[@]}"}; do
        [ -n "$label" ] || continue
        lesc=$(xcv_re_escape "$label")
        case "$label" in [[:alnum:]_]*) lb='[[:<:]]' ;; *) lb='' ;; esac
        case "$label" in *[[:alnum:]_]) rb='[[:>:]]' ;; *) rb='' ;; esac
        args+=(-e "s#$lb$lesc$rb#<private-dir>#g")
    done

    sed "${args[@]}"
}
