#!/bin/bash
# CLAUDE.md and AGENTS.md are the same document addressed to two tools. They have drifted three
# times: `.Codex/` with a capital C, the Definition-of-Done pointer in rule 10 (a safety rule), and
# the `XCodeVaultHelperCore` target missing from both Layout paragraphs. Each was found by a human
# noticing, which is not a control.
#
# This compares the two after normalising the differences that are SUPPOSED to exist — the tool
# names and config directories — and fails if anything else differs. It takes no position on
# whether the duplication should exist: if it is removed, delete this script with it.
set -u
cd "$(dirname "$0")/.."
python3 - <<'PY'
import io, sys, difflib

def read(p):
    try:
        return io.open(p, encoding="utf-8").read().splitlines()
    except OSError as e:
        print(f"doc-mirror: cannot read {p}: {e}", file=sys.stderr)
        sys.exit(2)

# The intended differences, and only these.
SWAPS = [(".codex/", ".claude/"), ("Codex", "Claude Code"), ("AGENTS.md", "CLAUDE.md")]

def norm(lines):
    out = []
    for l in lines:
        for a, b in SWAPS:
            l = l.replace(a, b)
        out.append(l.rstrip())
    return out

a, b = read("CLAUDE.md"), read("AGENTS.md")
if not a or not b:
    print("doc-mirror: one of the documents is empty", file=sys.stderr)
    sys.exit(2)

diff = list(difflib.unified_diff(norm(a), norm(b), "CLAUDE.md", "AGENTS.md", lineterm="", n=1))
if diff:
    print("doc-mirror: CLAUDE.md and AGENTS.md have drifted.", file=sys.stderr)
    print("Every difference below is unintended — the tool-name and directory swaps are", file=sys.stderr)
    print("already normalised away. Fix the file that is wrong, not this script.\n", file=sys.stderr)
    print("\n".join(diff), file=sys.stderr)
    sys.exit(1)
print("doc-mirror: ok")
PY
