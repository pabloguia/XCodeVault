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

# Redact the current user's home directory in evidence output.
xcv_redact() { sed -e "s#$HOME#~#g" -e "s#$(id -un)#<user>#g"; }
