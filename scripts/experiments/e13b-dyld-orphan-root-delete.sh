#!/bin/bash
# E13b — can root delete the orphaned dyld shared cache that a restart does not reclaim?
#
#   E13 (2026-09-16) measured the orphan surviving a reboot byte-identical, so the startup GC that
#   reclaims the stranded runtime Inbox does not cover Caches/dyld/<build>/inc/. That leaves exactly
#   one open question on F10, and it is this one.
#
# A REFUSAL IS THE INTERESTING RESULT, not a failed run.
#   If root is blocked here, this becomes the SECOND path where root gets EPERM with no BSD file
#   flag and no rootless.conf entry — the stranded Inbox being the first. That is OS behaviour worth
#   reporting to Apple, and it settles what `doctor` may say. A success is the duller outcome: it
#   means doctor can offer a command that works, and nothing about the OS was learned.
#
#   Exit codes carry that distinction, because a caller cannot read prose:
#     0  the question was asked and answered (root refused, or root succeeded)
#     2  refused before starting — bad arguments, not root, no SUDO_USER
#     3  a guard vetoed: something says this may not be an orphan. Nothing was touched.
#     4  the question could not be asked properly — an instrument failed, or the build diagnostic
#        could not be preserved. Nothing was deleted.
#
# WHY IT MEASURES errno AND NOT rm.
#   The remediation doctor prints uses `rm -f`, and -f suppresses the very thing this experiment is
#   for. EPERM (1) vs EACCES (13) is the discriminator this repo has used since F16: EPERM is a
#   policy refusal, EACCES is ordinary permissions. `rm` collapses both into one message. Each
#   unlink here goes through os.unlink and reports the raw errno. Same syscall, honest instrument.
#
# THE ORDER OF DELETION IS THE EXPERIMENT DESIGN.
#   Files are deleted smallest first, so the first thing touched is normally the ZERO-BYTE
#   update_dyld_sim_shared_cache-stdout.txt. If policy refuses THERE, the answer arrives having
#   destroyed nothing. That claim is only true for a refusal on the first file, so phase 3 prints a
#   manifest of everything it did unlink before stopping — a refusal on file 3 means files 1 and 2
#   are gone, and the verdict has to say so. There is NO ROLLBACK past the first successful unlink.
#
# THIS SCRIPT DELETES DATA. Read it before running it. What bounds the blast radius:
#   - it never elevates itself: run it as root or it refuses and prints the command for you to run;
#   - it takes ONE directory, canonicalises it, and accepts only a path whose components under the
#     dyld root are exactly <build>/<leaf> or <build>/inc/<leaf> — counted, not glob-matched;
#   - it refuses a symlink argument outright rather than following it;
#   - it refuses unless every liveness witness that COULD run agrees the runtime is gone, and a
#     witness whose instrument failed vetoes rather than reporting "absent" (see below);
#   - it re-checks the target's dev:inode immediately before the first unlink, because minutes of
#     `du` and `lsof` pass between validation and deletion;
#   - it refuses if the directory holds a single file it does not recognise, or any subdirectory —
#     surprises are reported, not deleted;
#   - without --delete it only inspects, AS ROOT, which is the only rehearsal worth having;
#   - it never touches a device, never boots anything, never mounts anything. The only simulator
#     commands it runs are `simctl runtime list` and `simctl list devices`, both read-only.
#
# WITNESSES, AND WHAT EACH IS WORTH.
#   Path shape does NOT establish orphanhood. The installed iOS cache satisfies every argument check
#   above; only the witness chain stops it. So each witness reports what it actually measured:
#
#     1. simctl runtime list, as the invoking user (HOME forced to theirs — see below)
#     2. simctl runtime list, as root with root's own HOME; a disagreement with (1) is itself a veto
#     3. an available device claiming that runtime
#     4. runtime bundles inside the Xcodes on this machine — the one simctl cannot provide
#     5. the disk-image catalogue, images.plist
#
#   A first version of witness 4 was worse than useless and shipped that way for an hour on
#   2026-09-16. It searched `-maxdepth 6` from <Xcode>/Contents/Developer/Platforms, while the
#   historical bundle path (Platforms/X.platform/Library/Developer/CoreSimulator/Profiles/Runtimes/
#   Y.simruntime) sits at depth 7 — so it could not have fired even where bundles exist. Worse, on
#   finding nothing it printed "no Xcode here bundles <rid>", an affirmative pass in the language of
#   a result. Measured on this machine: there are ZERO .simruntime bundles under the selected Xcode,
#   because Xcode 26.x ships runtimes as disk images instead. So the witness now reports how many
#   Developer directories it searched and how many bundles of ANY kind it found, and it says plainly
#   when it had nothing to discriminate with. It vetoes when it could not search at all; it does not
#   veto on an honest zero, because zero is the true answer on modern Xcode and a witness that
#   always vetoes makes the experiment unrunnable. On a machine with no bundled runtimes this
#   witness is NOT evidence, and it says so instead of voting.
#
# WHY HOME IS FORCED ON BOTH simctl CALLS.
#   simctl's device set lives at $HOME/Library/Developer/CoreSimulator. `sudo -u` without -H keeps
#   the caller's HOME, and stock macOS sudoers carries `env_keep += "HOME"`, so both calls can end
#   up reading the same store — and then the split-view veto cannot detect the thing it exists for.
#   That is the wrong-context rehearsal this repo has already shipped once (handoff, lesson 3), and
#   the first draft of this script reproduced it while its own header claimed to have designed
#   against it. Both calls now set HOME explicitly, from dscl, and print which one they used.
#
# Usage — INSPECT FIRST (deletes nothing):
#   sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand
#
# Then, if the report looks right:
#   sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand --delete
#
#   Find <orphan-dir> with `xcodevaultctl doctor`, or read the E13 capture under evidence/.
#
# NOT EXERCISED. As of 2026-09-16 only the argument chain above the root check has been run, as a
#   non-root user. Everything from the root check onward — the witnesses, the contents allowlist,
#   the unlink loop, the accounting — has never executed. Inspect mode exists so the first root run
#   exercises the witnesses without deleting anything. Treat its first output as data about this
#   script as much as about the OS.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DYLD_ROOT="/Library/Developer/CoreSimulator/Caches/dyld"

TARGET_IN="${1:-}"
shift 2>/dev/null || true
GATED=0
DO_DELETE=0
for a in "$@"; do
  case "$a" in
    --i-understand) GATED=1;;
    --delete) DO_DELETE=1;;
    *) echo "REFUSING: unknown argument: $a" >&2; exit 2;;
  esac
done

usage() {
  echo "usage: sudo $0 <orphan-dir> --i-understand [--delete]" >&2
  echo "  <orphan-dir> lives under $DYLD_ROOT/<build>[/inc]/" >&2
  echo "  without --delete the script only inspects, as root." >&2
}
[ -n "$TARGET_IN" ] || { usage; exit 2; }
[ "$GATED" = "1" ] || { usage; exit 2; }

# --- the argument, judged after resolution, never as text ---------------------------------------
# A textual refusal is not sound against .. or a symlink; that exact hole was found in e14b on
# 2026-09-15, where /Volumes/<vault>/../../Users/<you>/Library/Developer/CoreSimulator passed it.
if [ -L "$TARGET_IN" ]; then
  echo "REFUSING: $TARGET_IN is a symlink. Pass the real directory." >&2; exit 2
fi
# `--` and -P: without them an argument of "-P" or "-" is read by cd as an option or as $OLDPWD and
# resolves somewhere else entirely. Both were caught downstream by the prefix strip, which is
# containment by luck rather than by design.
TARGET=$(cd -P -- "$TARGET_IN" 2>/dev/null && pwd -P) || {
  echo "REFUSING: $TARGET_IN does not exist or is not a reachable directory." >&2; exit 2; }
case "$TARGET" in *\'*) echo "REFUSING: quote in the path." >&2; exit 2;; esac

REL="${TARGET#"$DYLD_ROOT"/}"
if [ "$REL" = "$TARGET" ]; then
  echo "REFUSING: $TARGET is not under $DYLD_ROOT." >&2; exit 2
fi

# Components, counted. The first version used glob depth (*/inc/*/* etc), which accepted
# <build>/<anything>/<rid> and <inc>/<rid> as well — a weaker rule than the header claimed, and a
# header that overstates its own guard is how a reviewer stops trusting the rest of the file.
OLD_IFS="$IFS"; IFS='/'; read -r -a PARTS <<< "$REL"; IFS="$OLD_IFS"
BUILD_DIR=""; LEAF=""
case "${#PARTS[@]}" in
  2) BUILD_DIR="${PARTS[0]}"; LEAF="${PARTS[1]}";;
  3) if [ "${PARTS[1]}" != "inc" ]; then
       echo "REFUSING: $TARGET has three components but the middle one is not 'inc'." >&2; exit 2
     fi
     BUILD_DIR="${PARTS[0]}"; LEAF="${PARTS[2]}";;
  *) echo "REFUSING: $TARGET is not <build>/<leaf> or <build>/inc/<leaf> under the cache root." >&2
     exit 2;;
esac
[ -n "$BUILD_DIR" ] && [ -n "$LEAF" ] || { echo "REFUSING: empty path component." >&2; exit 2; }
case "$LEAF" in
  com.apple.CoreSimulator.SimRuntime.*) ;;
  *) echo "REFUSING: $LEAF does not name a simulator runtime." >&2; exit 2;;
esac
case "$LEAF" in
  *$'\n'*) echo "REFUSING: newline in the directory name." >&2; exit 2;;
esac

# A cache under a host build that is NOT the running one is a different object from an orphan under
# the current build, and this script's witnesses do not speak to it. Measured 2026-09-16: a macOS
# update from 25G83 to 25G229 removed the entire dyld/25G83/ tree, 9.4 GB including the orphan E13
# had been tracking. So a stale-build directory is normally reclaimed by the update itself, and one
# that survives is a NEW finding deserving its own experiment rather than this one's unlink loop.
#
# The first version of this script printed "Host build dir: 25G83 (this machine: 25G229)" in its
# header and did nothing with it, then walked all five witnesses against a directory that no longer
# existed. Computing a discriminator and not branching on it is not a check.
RUNNING_BUILD=$(sw_vers -buildVersion 2>/dev/null)
if [ -z "$RUNNING_BUILD" ]; then
  echo "REFUSING: could not read this machine's build version." >&2; exit 2
fi
if [ "$BUILD_DIR" != "$RUNNING_BUILD" ]; then
  echo "REFUSING: $TARGET sits under host build $BUILD_DIR, but this machine runs $RUNNING_BUILD." >&2
  echo "  That is not the orphan case this experiment measures. A whole stale-build tree is" >&2
  echo "  normally removed by the macOS update that supersedes it (measured 2026-09-16)." >&2
  echo "  If this one survived an update, that is a finding — record it; do not unlink it here." >&2
  exit 2
fi

# The identity phase 3 re-checks before the first unlink. Minutes of du and lsof pass between here
# and there, and the racer that matters is not a local attacker (every directory on the chain is
# root-owned and not group-writable) but root's own CoreSimulatorService, which can make an orphan
# live inside that window.
TARGET_ID=$(stat -f '%d:%i' "$TARGET" 2>/dev/null)
[ -n "$TARGET_ID" ] || { echo "REFUSING: could not stat $TARGET." >&2; exit 2; }

# The identifier without its trailing build, which is how simctl and Xcode name it.
RID_FULL="$LEAF"
RID="${LEAF%.*}"
case "$RID" in
  com.apple.CoreSimulator.SimRuntime.*) ;;
  *) RID="$LEAF";;   # this entry carries no build suffix
esac

# --- root, but never by our own hand ------------------------------------------------------------
# Deliberately AFTER the argument checks. Every guard above is pure path reasoning that needs no
# privilege, so putting the uid test first would have made the entire refusal chain impossible to
# exercise without sudo — and a guard nobody can run is a guard nobody has checked. This ordering
# also gives the better message when both are wrong.
#
# This script does not call sudo on itself and never asks for a password. If it is not already root
# it says what to run and stops. Escalating from inside a script is how a reviewer loses the chance
# to see what was about to run as root.
if [ "$(id -u)" != "0" ]; then
  echo "The argument checks passed. E13b has to run as root, and it will not elevate itself." >&2
  echo "Read the script first, then run:" >&2
  if [ "$DO_DELETE" = "1" ]; then
    echo "  sudo $0 $TARGET --i-understand --delete" >&2
  else
    echo "  sudo $0 $TARGET --i-understand" >&2
  fi
  exit 2
fi

# SUDO_USER is load-bearing twice: the simctl cross-check has to run as the human whose simulator
# installation this machine actually uses, and the evidence file has to end up owned by them rather
# than by root inside their own git tree. It is an environment variable, so it is validated rather
# than trusted: `sudo -u '#0'` is the uid form and would run the "as the user" witness as root.
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  echo "REFUSING: no SUDO_USER, so this is a bare root shell." >&2
  echo "  Two guards depend on knowing the real user: the simctl cross-check would ask root about a" >&2
  echo "  simulator installation root does not own, and the evidence would be left root-owned in" >&2
  echo "  your git tree. Run it with sudo from your own shell instead." >&2
  exit 2
fi
case "$REAL_USER" in
  \#*|-*|*/*|*' '*) echo "REFUSING: implausible SUDO_USER: $REAL_USER" >&2; exit 2;;
esac
if ! id "$REAL_USER" >/dev/null 2>&1; then
  echo "REFUSING: SUDO_USER=$REAL_USER is not a user on this machine." >&2; exit 2
fi
if [ "$(id -u "$REAL_USER" 2>/dev/null)" = "0" ]; then
  echo "REFUSING: SUDO_USER=$REAL_USER resolves to uid 0." >&2; exit 2
fi

# <user> -> home directory, or empty.
#
# Neither `awk '{print $2}'` nor a sed strip can parse this. dscl returns a multi-VALUE attribute,
# space separated, and root genuinely has two: "NFSHomeDirectory: /var/root /private/var/root".
# The text form cannot tell that from one home containing a space. Measured: the sed version set
# HOME for witness 2 to the literal string "/var/root /private/var/root". It happened not to matter,
# because `simctl runtime list` reads system-wide state rather than $HOME — which is worse, not
# better: the split-view cross-check ran with a broken HOME and reported agreement.
home_of() {
  dscl -plist . -read "/Users/$1" NFSHomeDirectory 2>/dev/null \
    | plutil -extract 'dsAttrTypeStandard:NFSHomeDirectory.0' raw -o - - 2>/dev/null
}
USER_HOME=$(home_of "$REAL_USER")
ROOT_HOME=$(home_of root); [ -n "$ROOT_HOME" ] || ROOT_HOME=/var/root
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "REFUSING: could not resolve a home directory for $REAL_USER." >&2
  echo "  Witness 1 reads \$HOME/Library/Developer/CoreSimulator; without it that witness would" >&2
  echo "  silently read the wrong store and report 'absent'." >&2
  exit 2
fi

OUT="$XCV_EVIDENCE_DIR/e13b-dyld-orphan-root-delete-$(xcv_env_slug).txt"
STDERR_COPY="$XCV_EVIDENCE_DIR/e13b-update-dyld-stderr-$(xcv_env_slug).txt"
xcv_rotate_out "$OUT" || exit 2

# The body runs inside a pipeline, so its variables die with the subshell. One small file per fact.
STATE=$(mktemp -d -t xcv-e13b-state) || exit 2
echo 4 > "$STATE/outcome"   # pessimistic: "could not ask" until something says otherwise

# Whatever happens, the evidence ends up owned by the human rather than by root.
hand_back() {
  for f in "$OUT" "$STDERR_COPY"; do
    [ -e "$f" ] && chown "$REAL_USER" "$f" 2>/dev/null
  done
  return 0
}
trap 'hand_back' EXIT INT TERM HUP

# --- instruments --------------------------------------------------------------------------------

# -H so HOME is the target user's, not whatever the caller had. See the header.
as_user() { sudo -H -u "$REAL_USER" "$@"; }

# Raw errno, because rm -f hides the answer this experiment exists to collect.
unlink_errno() {
  /usr/bin/python3 - "$1" <<'PY'
import os, sys, errno
try:
    os.unlink(sys.argv[1]); print("UNLINKED"); sys.exit(0)
except OSError as e:
    print("REFUSED errno=%d %s (%s)" % (e.errno, errno.errorcode.get(e.errno, "?"), e.strerror))
    sys.exit(10)
PY
}
rmdir_errno() {
  /usr/bin/python3 - "$1" <<'PY'
import os, sys, errno
try:
    os.rmdir(sys.argv[1]); print("RMDIR OK"); sys.exit(0)
except OSError as e:
    print("REFUSED errno=%d %s (%s)" % (e.errno, errno.errorcode.get(e.errno, "?"), e.strerror))
    sys.exit(10)
PY
}

# Every Developer directory worth searching for bundled runtimes.
developer_dirs() {
  { ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null
    ls -d "$USER_HOME"/Applications/Xcode*.app/Contents/Developer 2>/dev/null
    xcode-select -p 2>/dev/null
  } | sort -u
}

# Substring test without a pipeline, so a match cannot be confused with a grep exit code.
mentions() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

{
  xcv_header "E13b — root deletion of an orphaned dyld shared cache (gates F10; follows E13)"
  echo "# Target:         $TARGET"
  echo "# Runtime id:     $RID   (leaf: $RID_FULL)"
  echo "# Host build dir: $BUILD_DIR   (this machine: $(sw_vers -buildVersion))"
  echo "# Invoked by:     $REAL_USER (home $USER_HOME), elevated to uid $(id -u)"
  echo "# Mode:           $([ "$DO_DELETE" = 1 ] && echo 'DELETE (destructive)' || echo 'inspect only')"
  echo "# Question:       does root get EPERM here, as it did on the stranded runtime Inbox?"
  echo

  # ---------------------------------------------------------------------------------------------
  echo "== phase 1 — is this runtime really gone? =="
  echo "# Any witness vetoes. A witness whose INSTRUMENT failed also vetoes: 'the command errored"
  echo "# and its error text did not contain the runtime id' is not the same fact as 'absent'."
  echo

  VETO=0

  echo "## witness 1 — simctl runtime list, as $REAL_USER (HOME=$USER_HOME)"
  RT_USER=$(as_user xcrun simctl runtime list 2>&1); RT_USER_RC=$?
  echo "$RT_USER"
  echo "[exit=$RT_USER_RC]"
  if [ "$RT_USER_RC" != "0" ]; then
    echo "!! VETO: the instrument failed. Not reading this as 'absent'."
    VETO=1
  elif mentions "$RT_USER" "$RID"; then
    echo "!! VETO: $RID appears in the invoking user's runtime list."
    VETO=1
  else
    echo "-> ran clean, and $RID is absent"
  fi
  echo

  echo "## witness 2 — simctl runtime list, as root (HOME=$ROOT_HOME)"
  RT_ROOT=$(HOME="$ROOT_HOME" xcrun simctl runtime list 2>&1); RT_ROOT_RC=$?
  echo "[exit=$RT_ROOT_RC]"
  if [ "$RT_ROOT_RC" != "0" ]; then
    echo "$RT_ROOT"
    echo "!! VETO: the instrument failed as root."
    VETO=1
  else
    if [ "$RT_ROOT" = "$RT_USER" ]; then
      echo "-> identical to witness 1"
    else
      echo "$RT_ROOT"
      echo "!! the two views DIFFER. That alone is a finding, and it means neither can be trusted"
      echo "   as a statement about the machine. Not deleting anything on a split view."
      VETO=1
    fi
    if mentions "$RT_ROOT" "$RID"; then
      echo "!! VETO: $RID appears in root's runtime list."
      VETO=1
    fi
  fi
  echo

  echo "## witness 3 — an available device is a witness for its runtime"
  DEV=$(as_user xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
rid = sys.argv[1]
try: d = json.load(sys.stdin)["devices"]
except Exception: print("UNREADABLE"); raise SystemExit
hits = [x["name"] for k, v in d.items() if rid in k for x in v if x.get("isAvailable")]
print(chr(10).join(hits) if hits else "none")' "$RID")
  echo "   available devices on $RID: ${DEV:-<empty>}"
  case "$DEV" in
    none) echo "-> none";;
    ""|UNREADABLE) echo "!! VETO: could not read the device list; refusing to guess."; VETO=1;;
    *) echo "!! VETO: a device still claims this runtime."; VETO=1;;
  esac
  echo

  echo "## witness 4 — runtime bundles inside the Xcodes on this machine"
  echo "# The witness simctl cannot provide: a runtime bundled in an older Xcode is invisible to it."
  DEVDIRS=$(developer_dirs)
  NDEV=$(printf '%s\n' "$DEVDIRS" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "   Developer directories searched: ${NDEV:-0}"
  printf '%s\n' "$DEVDIRS" | sed '/^$/d' | sed 's/^/     /'
  BUNDLES=""
  if [ "${NDEV:-0}" -gt 0 ]; then
    while IFS= read -r dev; do
      [ -n "$dev" ] && [ -d "$dev" ] || continue
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        bid=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$p/Contents/Info.plist" 2>/dev/null)
        [ -n "$bid" ] && BUNDLES="$BUNDLES$bid"$'\n'
      done < <(find "$dev" -maxdepth 9 -name '*.simruntime' 2>/dev/null)
    done < <(printf '%s\n' "$DEVDIRS")
  fi
  NB=$(printf '%s' "$BUNDLES" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "   runtime bundles of ANY kind found: ${NB:-0}"
  if [ "${NDEV:-0}" -eq 0 ]; then
    echo "!! VETO: no Developer directory to search. The witness could not run, which is not the"
    echo "   same as finding nothing."
    VETO=1
  elif [ "${NB:-0}" -eq 0 ]; then
    echo "-- INCONCLUSIVE, and deliberately not a vote either way. Zero bundles is the TRUE answer"
    echo "   on Xcode 26.x, which ships runtimes as disk images (witness 5) rather than as bundles."
    echo "   On such a machine this witness has nothing to discriminate with. It does not get to say"
    echo "   'no Xcode bundles this runtime' — it did not look at any bundle. If you are on a machine"
    echo "   with an older Xcode that DOES bundle runtimes, a zero here means the search is broken"
    echo "   and you should stop."
  else
    printf '%s' "$BUNDLES" | sed '/^$/d' | sed 's/^/     /'
    if mentions "$BUNDLES" "$RID"; then
      echo "!! VETO: an Xcode on this machine ships $RID. This cache is LIVE."
      VETO=1
    else
      echo "-> searched ${NB} bundle(s); none is $RID"
    fi
  fi
  echo

  echo "## witness 5 — the disk-image catalogue"
  IMAGES_PLIST=/Library/Developer/CoreSimulator/Images/images.plist
  if [ -f "$IMAGES_PLIST" ]; then
    IMG=$(/usr/bin/plutil -p "$IMAGES_PLIST" 2>&1); IMG_RC=$?
    if [ "$IMG_RC" != "0" ]; then
      echo "!! VETO: could not read images.plist (exit $IMG_RC)."
      VETO=1
    elif mentions "$IMG" "$RID"; then
      echo "!! VETO: images.plist still lists $RID."
      VETO=1
    else
      echo "-> read clean, and images.plist does not mention $RID"
    fi
  else
    echo "-- no images.plist on this machine; witness 5 had nothing to read."
  fi
  echo

  if [ "$VETO" != "0" ]; then
    echo "== VERDICT: REFUSING TO DELETE =="
    echo "A witness vetoed. Nothing was touched."
    echo "That is the script working, not failing."
    echo 3 > "$STATE/outcome"
    exit 0
  fi
  echo "-> no witness vetoed. Note what that does and does not mean: witness 4 may have been"
  echo "   inconclusive above, in which case four witnesses voted, not five."
  echo

  # ---------------------------------------------------------------------------------------------
  echo "== phase 2 — what is actually in there? surprises are reported, not deleted =="
  echo
  xcv_run "contents" ls -lO@ "$TARGET"
  xcv_run "ACLs" ls -lde "$TARGET"
  xcv_run "extended attributes" xattr -l "$TARGET"
  xcv_run "size" du -shx "$TARGET"

  # The target existed when the arguments were validated. Phases 1 and 2 have run commands since,
  # and on 2026-09-16 the directory was already gone by the time phase 2 started — so every `ls`
  # below failed, the loop that follows never iterated, and the guard printed "every entry is a
  # known cache artifact" over a read of nothing. An allowlist that cannot distinguish "checked N
  # entries, all known" from "read zero entries" is not an allowlist.
  if [ ! -d "$TARGET" ]; then
    echo "!! VETO: $TARGET is gone since the arguments were validated. Nothing to inspect."
    echo 3 > "$STATE/outcome"
    exit 0
  fi
  ENTRY_COUNT=$(ls -A "$TARGET" 2>/dev/null | wc -l | tr -d ' ')
  echo "## entries read: ${ENTRY_COUNT:-0}"
  if [ "${ENTRY_COUNT:-0}" -eq 0 ]; then
    echo "!! VETO: read zero entries. Either the directory is empty or it could not be read, and"
    echo "   this guard cannot tell those apart — so it does not get to report a pass."
    echo 3 > "$STATE/outcome"
    exit 0
  fi

  UNEXPECTED=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -d "$TARGET/$entry" ]; then
      echo "!! unexpected SUBDIRECTORY: $entry"
      UNEXPECTED=1
      continue
    fi
    case "$entry" in
      dyld_sim_shared_cache_*|update_dyld_sim_shared_cache-*|*.atlas) ;;
      *) echo "!! unexpected file: $entry"; UNEXPECTED=1;;
    esac
  done < <(ls -A "$TARGET" 2>/dev/null)

  if [ "$UNEXPECTED" != "0" ]; then
    echo
    echo "== VERDICT: REFUSING TO DELETE =="
    echo "The directory holds something this script does not recognise. rmdir refuses on surprises"
    echo "for the same reason, and so does this."
    echo 3 > "$STATE/outcome"
    exit 0
  fi
  echo "-> all ${ENTRY_COUNT} entries are known cache artifacts."
  echo

  # stdout ONLY. The first version captured 2>&1, so on a missing path lsof's usage banner landed in
  # $LSOF, the variable was non-empty, and the script announced "something holds a handle inside the
  # target". It stopped the run, correctly, for a reason that was false — a veto firing on its own
  # error message is noise that happened to point the right way. Measured: lsof on a missing path
  # writes nothing to stdout and exits 1.
  LSOF_ERR=$(mktemp -t xcv-e13b-lsof) || { echo 4 > "$STATE/outcome"; exit 0; }
  LSOF=$(lsof +D "$TARGET" 2>"$LSOF_ERR" | head -20)
  echo "## open file handles (stdout)"
  echo "${LSOF:-<none>}"
  if [ -s "$LSOF_ERR" ]; then
    echo "## lsof stderr — instrument noise, NOT evidence of a handle"
    head -5 "$LSOF_ERR" | sed 's/^/   /'
  fi
  rm -f "$LSOF_ERR"
  if [ -n "$LSOF" ]; then
    echo "!! VETO: something holds a handle inside the target. lsof explained nothing on the Inbox,"
    echo "   but a live handle is a reason to stop rather than a curiosity to print."
    echo 3 > "$STATE/outcome"
    exit 0
  fi
  echo

  # The diagnostic doctor's own glob would destroy. Copied out BEFORE anything is unlinked.
  # -p: this file may end up attached to a bug report, and mtime/mode are part of it.
  if [ -f "$TARGET/update_dyld_sim_shared_cache-stderr.txt" ]; then
    xcv_run "the diagnostic, as it stands" ls -lO@ "$TARGET/update_dyld_sim_shared_cache-stderr.txt"
    if cp -p "$TARGET/update_dyld_sim_shared_cache-stderr.txt" "$STDERR_COPY" 2>/dev/null; then
      echo "## kept the build diagnostic: $STDERR_COPY"
      echo "   ($(wc -c < "$STDERR_COPY" | tr -d ' ') bytes)"
    else
      echo "!! could not copy the stderr diagnostic aside — NOT deleting without it."
      echo 4 > "$STATE/outcome"
      exit 0
    fi
  else
    echo "## no update_dyld_sim_shared_cache-stderr.txt here"
  fi
  echo

  xcv_run "BEFORE — whole dyld tree" du -shx "$DYLD_ROOT"
  xcv_run "BEFORE — free space on /" df -h /

  if [ "$DO_DELETE" != "1" ]; then
    echo "== INSPECT ONLY — nothing was deleted =="
    echo "Every guard passed. To run the actual probe, re-run the same command with --delete."
    echo "Smallest file first, so the first unlink attempted would be:"
    ls -S "$TARGET" 2>/dev/null | tail -1 | sed 's/^/   /'
    echo 0 > "$STATE/outcome"
    exit 0
  fi

  # ---------------------------------------------------------------------------------------------
  echo "== phase 3 — the probe: unlink smallest-first, recording errno per file =="
  echo "# Smallest first is deliberate. If policy refuses on the FIRST file, the answer arrives"
  echo "# having destroyed nothing; a refusal later means the earlier ones are gone, and the"
  echo "# manifest below says which. There is no rollback."
  echo

  # Minutes of du and lsof passed since the path was validated. Cheap re-check that it is still the
  # same object rather than a different one that arrived at the same name.
  NOW_ID=$(stat -f '%d:%i' "$TARGET" 2>/dev/null)
  echo "## target identity now: ${NOW_ID:-<unreadable>} (validated as: $TARGET_ID)"
  if [ -z "$NOW_ID" ] || [ "$NOW_ID" != "$TARGET_ID" ]; then
    echo "!! REFUSING: the directory at this path is not the one that passed the guards."
    echo 3 > "$STATE/outcome"
    exit 0
  fi
  echo

  REFUSED_AT=""
  FIRST_ERRNO=""
  UNLINKED=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    f="$TARGET/$entry"
    [ -f "$f" ] || continue
    sz=$(stat -f %z "$f" 2>/dev/null)
    echo "## unlink $entry (${sz:-?} bytes)"
    res=$(unlink_errno "$f"); rc=$?
    echo "   $res"
    if [ "$rc" != "0" ]; then
      REFUSED_AT="$entry"
      FIRST_ERRNO="$res"
      echo
      echo "-> stopping here. The question is answered, and nothing further needs to be destroyed"
      echo "   in order to answer it again."
      break
    fi
    UNLINKED="$UNLINKED  $entry (${sz:-?} bytes)"$'\n'
  done < <(ls -S "$TARGET" 2>/dev/null | tail -r)
  echo

  echo "## manifest — what this run actually destroyed"
  if [ -n "$UNLINKED" ]; then
    printf '%s' "$UNLINKED"
  else
    echo "  nothing"
  fi
  echo

  if [ -z "$REFUSED_AT" ]; then
    echo "## rmdir $TARGET"
    rmdir_errno "$TARGET"
    echo
  fi

  # ---------------------------------------------------------------------------------------------
  echo "== phase 4 — verify by asking the filesystem, not by trusting an exit code =="
  if [ -e "$TARGET" ]; then
    echo "-> $TARGET still exists"
    xcv_run "what survived" ls -lO "$TARGET"
  else
    echo "-> $TARGET is gone"
  fi
  echo
  xcv_run "AFTER — whole dyld tree" du -shx "$DYLD_ROOT"
  xcv_run "AFTER — free space on /" df -h /

  echo "== verdict =="
  if [ -n "$REFUSED_AT" ]; then
    echo "ROOT WAS REFUSED, at: $REFUSED_AT"
    echo "  $FIRST_ERRNO"
    if [ -n "$UNLINKED" ]; then
      echo "  NOTE: the refusal was not on the first file. The manifest above lists what is gone,"
      echo "  and it cannot be undone."
    fi
    echo
    echo "This is the interesting outcome. The errno is the discriminator:"
    echo "  EPERM  (1)  -> a POLICY refusal. Second known path where root is blocked with no BSD"
    echo "                 flag and no rootless.conf entry, the stranded runtime Inbox being the"
    echo "                 first (F1, F16). Worth a report to Apple, and doctor must NOT offer a"
    echo "                 root command for this path."
    echo "  EACCES (13) -> ordinary permissions, which would be surprising for uid 0 and would mean"
    echo "                 the guard chain above mis-identified what it was looking at."
    echo "Keep the stderr copy: it is the build diagnostic, and it survived."
  elif [ -e "$TARGET" ]; then
    echo "MIXED: files were unlinked but the directory remains. See the rmdir errno above."
  else
    echo "ROOT SUCCEEDED: the orphan is gone."
    echo "  The duller outcome, and it settles doctor's advice in the other direction: a root"
    echo "  command here is offerable. Nothing was learned about the OS itself."
    echo "  Compare the before/after totals above; the space reclaimed should match the du."
  fi
  echo 0 > "$STATE/outcome"
  echo
  echo "Record the result in F10, COMPATIBILITY_MATRIX and HYPOTHESES H11, and set the next probe."
} 2>&1 | xcv_redact | tee "$OUT"

RC=$(cat "$STATE/outcome" 2>/dev/null || echo 4)
rm -rf "$STATE"
echo
echo "Written to $OUT"
[ -f "$STDERR_COPY" ] && echo "Build diagnostic kept at $STDERR_COPY"
echo "exit $RC  (0 answered · 3 vetoed, nothing touched · 4 could not ask)"
exit "$RC"
