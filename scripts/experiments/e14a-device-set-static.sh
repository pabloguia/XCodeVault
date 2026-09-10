#!/bin/bash
# E14a — Alternate CoreSimulator device set: read-only reconnaissance.
#
# Answers, WITHOUT mutating any state:
#   1. What does `simctl` document about `--set`?
#   2. Does the Xcode 26 IDE have a code path that opens a device set at a *custom* path,
#      and what input selects it?  (static analysis of IDEiOSSupportCore)
#   3. What is actually inside ~/Library/Developer/CoreSimulator/Devices — i.e. how much of
#      the device set is durable user data and how much is regenerable cache/log/asset?
#
# It runs only: xcrun simctl help, defaults read, du, ls, strings, otool, nm, file.
# It creates nothing, deletes nothing, and never uses sudo.
#
# The mutating half (does a device set on an external volume actually work?) is E14b,
# scripts/experiments/e14b-device-set-external.sh — read it before running it.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT="$XCV_EVIDENCE_DIR/e14a-device-set-static-$(xcv_env_slug).txt"
IDEIOS="/Applications/Xcode.app/Contents/PlugIns/IDEiOSSupportCore.framework/Versions/A/IDEiOSSupportCore"
SIMAPP="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
CORESIM="/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"
DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"

{
  xcv_header "E14a — alternate device set, read-only reconnaissance"

  echo "## 1. simctl's own documentation of --set"
  xcv_run "simctl help (usage line)" bash -c "xcrun simctl help 2>&1 | head -2"
  xcv_run "simctl help create (runtime id may be a PATH)" bash -c "xcrun simctl help create 2>&1"
  xcv_run "simctl help clone (destination device set)" bash -c "xcrun simctl help clone 2>&1"
  xcv_run "man simctl?" bash -c "man -w simctl 2>&1 || echo 'no man page'"

  echo "## 2. Who reads a custom device set path?"
  xcv_run "Simulator.app: device-set keys and API" bash -c \
    "strings -a '$SIMAPP' | grep -iE '^(DeviceSetPath|TestingDeviceSetPath|CurrentDeviceUDID)$|deviceSetWithPath|buildDeviceSet' | sort -u"
  xcv_run "CoreSimulator.framework: any CORESIMULATOR_* env var?" bash -c \
    "strings -a '$CORESIM' | grep -oE 'CORESIMULATOR_[A-Z_]+' | sort -u; echo '(none listed above = no such env var in the framework)'"
  xcv_run "CoreSimulator.framework: SIMULATOR_* env vars present, for contrast" bash -c \
    "strings -a '$CORESIM' | grep -E '^SIMULATOR_[A-Z_]+$' | sort -u | head -20"
  xcv_run "simctl binary: env vars it honours" bash -c \
    "strings -a /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl | grep -E 'SIMCTL_|CORESIMULATOR_|deviceSetWithPath|defaultDeviceSetWithError' | sort -u"
  xcv_run "Which Xcode binaries mention DVTSimulatorSetLocation" bash -c \
    "cd /Applications/Xcode.app/Contents && find . -maxdepth 12 -type f -perm -u+x -size +50k 2>/dev/null | while read -r f; do strings -a \"\$f\" 2>/dev/null | grep -q DVTSimulatorSetLocation && echo \"\$f\"; done"

  echo "## 3. Static proof of the IDE's custom-device-set code path"
  echo "\$ python3 <cfstring/selref annotator> $IDEIOS DVTSimulatorSetLocation"
  python3 - "$IDEIOS" DVTSimulatorSetLocation <<'PYEOF' 2>&1
import subprocess, re, sys
F, NEEDLE = sys.argv[1], sys.argv[2]

def raw(seg, s):
    out = subprocess.run(["otool", "-s", seg, s, F], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]{16})\t((?:[0-9a-f]{2} ?)+)$", line.rstrip())
        if m:
            rows[int(m.group(1), 16)] = bytes(int(x, 16) for x in m.group(2).split())
    if not rows:
        return None, None
    return min(rows), b"".join(rows[a] for a in sorted(rows))

strsecs = {}
for seg, s in [("__TEXT", "__objc_methname"), ("__TEXT", "__cstring"), ("__TEXT", "__objc_classname")]:
    b, d = raw(seg, s)
    if b is not None:
        strsecs[s] = (b, d)

def getstr(a):
    for s, (b, d) in strsecs.items():
        if b <= a < b + len(d):
            return d[a - b:d.index(b"\0", a - b)].decode("utf8", "replace")
    return None

ptrsecs = {}
for seg, s in [("__DATA", "__objc_selrefs"), ("__DATA_CONST", "__objc_selrefs"),
               ("__DATA", "__cfstring"), ("__DATA_CONST", "__cfstring")]:
    b, d = raw(seg, s)
    if b is not None:
        ptrsecs[(seg, s)] = (b, d)

def resolve(a):
    for (seg, s), (b, d) in ptrsecs.items():
        if b <= a < b + len(d):
            off = a - b
            if s == "__cfstring":
                p = int.from_bytes(d[off + 16:off + 24], "little") & 0xFFFFFFFFF
                return '@"%s"' % getstr(p)
            p = int.from_bytes(d[off:off + 8], "little") & 0xFFFFFFFFF
            return "sel:" + str(getstr(p))
    t = getstr(a)
    return 'cstr:"%s"' % t if t else None

b, d = strsecs["__cstring"]
cstr = b + d.find(b"\0" + NEEDLE.encode() + b"\0") + 1
target = None
for (seg, s), (bb, dd) in ptrsecs.items():
    if s != "__cfstring":
        continue
    for off in range(0, len(dd) - 31, 32):
        if (int.from_bytes(dd[off + 16:off + 24], "little") & 0xFFFFFFFFF) == cstr:
            target = bb + off
print("cstring @0x%x   CFString @%s" % (cstr, hex(target) if target else "none"))

asm = subprocess.run(["otool", "-tV", F], capture_output=True, text=True).stdout.splitlines()
parsed = []
for l in asm:
    m = re.match(r"^([0-9a-f]{16})\t(.*)$", l)
    parsed.append((int(m.group(1), 16) if m else None, m.group(2) if m else None, l))
addrs = [p[0] for p in parsed if p[0] is not None]
nx = {addrs[k]: addrs[k + 1] for k in range(len(addrs) - 1)}
hits = []
for i, (a, t, r) in enumerate(parsed):
    if a is None:
        continue
    m = re.search(r"(-?0x[0-9a-f]+)\(%rip\)", t)
    if m and nx.get(a) and nx[a] + int(m.group(1), 16) in (cstr, target):
        hits.append(i)
for h in hits:
    j = h
    while j > 0 and not parsed[j][2].endswith(":"):
        j -= 1
    print("\nreferenced from: %s" % parsed[j][2])
    for k in range(max(0, h - 45), min(len(parsed), h + 190)):
        a, t, r = parsed[k]
        if a is None:
            continue
        m = re.search(r"(-?0x[0-9a-f]+)\(%rip\)", t)
        ann = ""
        if m and nx.get(a):
            v = resolve(nx[a] + int(m.group(1), 16))
            if v:
                ann = "   <<< " + v
        if ann:
            print("%08x  %-45s%s" % (a, t.split("##")[0].strip(), ann))
PYEOF
  echo "[exit=$?]"
  echo
  xcv_run "IDEiOSSupportCore log strings that bracket the branch" bash -c \
    "strings -a '$IDEIOS' | grep -E 'Creating/fetching (default|temporary) SimDeviceSet|deviceSetWithPath:error:\] returned nil|defaultDeviceSetWithError:\] returned nil'"

  echo "## 4. Is the key set on this machine? (read-only)"
  for k in DVTSimulatorSetLocation IDECustomDerivedDataLocation IDECustomDistributionArchivesLocation \
           IDECustomCompilationCacheLocation IDEBuildLocationStyle IDESharedBuildFolderName; do
    printf '%-42s ' "$k"
    defaults read com.apple.dt.Xcode "$k" 2>/dev/null || echo "(not set)"
  done
  echo
  printf '%-42s ' "com.apple.iphonesimulator DeviceSetPath"
  defaults read com.apple.iphonesimulator DeviceSetPath 2>/dev/null || echo "(not set)"
  echo
  xcv_run "Locations default keys that exist in Xcode 26.5 IDEFoundation" bash -c \
    "strings -a /Applications/Xcode.app/Contents/Frameworks/IDEFoundation.framework/Versions/A/IDEFoundation | grep -E '^IDE(Custom[A-Za-z]*(Location|Path)|BuildLocationStyle|SharedBuildFolderName)$' | sort -u"

  echo "## 5. What is actually in the device set"
  xcv_run "device set total" du -shx "$DEVICES"
  xcv_run "per device" bash -c "du -shx '$DEVICES'/*/ 2>/dev/null | sort -h"
  echo "## per-device composition (durable vs regenerable)"
  for d in "$DEVICES"/*/; do
    [ -f "$d/device.plist" ] || continue
    name=$(plutil -extract name raw "$d/device.plist" 2>/dev/null)
    echo "### $name  ($(basename "$d"))"
    for p in data/Containers \
             data/Library/Caches/com.apple.containermanagerd/Dead \
             data/Library/Caches \
             data/private/var/MobileAsset \
             data/var/db/diagnostics \
             data/var/db/uuidtext; do
      printf '  %-58s %s\n' "$p" "$(du -shx "$d$p" 2>/dev/null | cut -f1)"
    done
    echo
  done

  echo "## 6. Context: where the rest of the user-domain bytes are"
  xcv_run "~/Library/Developer" bash -c "du -shx ~/Library/Developer/* 2>/dev/null | sort -h"
  xcv_run "~/Library/Developer/Xcode" bash -c "du -shx ~/Library/Developer/Xcode/* 2>/dev/null | sort -h"
  xcv_run "free space" bash -c "df -h / /System/Volumes/Data 2>/dev/null"

  echo "## 7. FSKit availability on this host (H7)"
  xcv_run "FSKit framework + daemons" bash -c \
    "ls -d /System/Library/Frameworks/FSKit.framework 2>&1; ls /usr/libexec | grep -i fskit"
  xcv_run "mount(8) knows FSKit modules" bash -c "man 8 mount 2>/dev/null | col -b | grep -A2 -- '-F      Forces'"
} 2>&1 | xcv_redact > "$OUT"

echo "wrote $OUT"
