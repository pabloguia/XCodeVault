#!/bin/bash
# E1 (mount half) — run AS ROOT. Mounts a scratch APFS volume over a throwaway directory under
# /Library/Developer, proves read/write, unmounts, removes the directory. Never touches the real
# CoreSimulator path. Also (optionally) creates <mount>/XcodeVault owned by the invoking user, the
# same operation the privileged helper's createVaultDirectory verb performs.
# Usage (as root): e1b-mount-probe.sh <apfs-device e.g. disk9s1> <evidence-file> [<vault-mount> <uid> <gid>]
set -u
dev="$1"; out="$2"; vmount="${3:-}"; vuid="${4:-}"; vgid="${5:-}"
probe=/Library/Developer/xcv-probe
{
  echo "## E1 mount half (as $(id -un), uid $(id -u))"
  echo "\$ mkdir $probe"; mkdir "$probe"; echo "[exit=$?]"
  echo "\$ ls -ldO $probe"; ls -ldO "$probe"
  echo "\$ diskutil mount -mountPoint $probe $dev"; diskutil mount -mountPoint "$probe" "$dev"; echo "[exit=$?]"
  echo "\$ mount | grep xcv-probe"; mount | grep xcv-probe
  echo "\$ touch $probe/hello && ls -l $probe"; touch "$probe/hello" && ls -l "$probe"; echo "[exit=$?]"
  echo "\$ getattrlist mount status via xcodevaultctl volumes (is it a mount point?)"; ~/projects/XCodeVault/.build/debug/xcodevaultctl volumes 2>/dev/null | grep -A1 XCVPROBE | head -2
  echo "\$ diskutil unmount $probe"; diskutil unmount "$probe"; echo "[exit=$?]"
  echo "\$ ls -la $probe (should be empty local dir again)"; ls -la "$probe"
  echo "\$ rmdir $probe"; rmdir "$probe"; echo "[exit=$?]"
  if [ -n "$vmount" ]; then
    echo "## vault directory (helper verb equivalent)"
    echo "\$ mkdir -p $vmount/XcodeVault && chown $vuid:$vgid $vmount/XcodeVault"
    mkdir -p "$vmount/XcodeVault" && chown "$vuid:$vgid" "$vmount/XcodeVault"; echo "[exit=$?]"
    ls -ldO "$vmount/XcodeVault"
  fi
} >> "$out" 2>&1
