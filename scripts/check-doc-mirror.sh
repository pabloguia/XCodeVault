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
SWAPS = [(".codex/", ".claude/"), (".agents/", ".claude/"), ("Codex", "Claude Code"), ("AGENTS.md", "CLAUDE.md")]

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

bad = False
diff = list(difflib.unified_diff(norm(a), norm(b), "CLAUDE.md", "AGENTS.md", lineterm="", n=1))
if diff:
    bad = True
    print("doc-mirror: CLAUDE.md and AGENTS.md have drifted.", file=sys.stderr)
    print("Every difference below is unintended — the tool-name and directory swaps are", file=sys.stderr)
    print("already normalised away. Fix the file that is wrong, not this script.\n", file=sys.stderr)
    print("\n".join(diff), file=sys.stderr)

# The normalisation above is a hole, and it was found on this script's first day: mapping
# `.codex/` onto `.claude/` is exactly what hides a pointer to a `.codex/` path that does not
# exist. AGENTS.md pointed at `.codex/skills/` — absent from the tree — and the diff said ok.
# So each document is also checked against the filesystem, before normalisation.
import os, re
PATH = re.compile(r"`(\.?[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]*)`")
for name, lines in (("CLAUDE.md", a), ("AGENTS.md", b)):
    for i, line in enumerate(lines, 1):
        for m in PATH.finditer(line):
            ref = m.group(1)
            if ref.endswith("/"):
                ref = ref[:-1]
            # Only judge paths this repository is supposed to contain.
            if not ref.startswith((".claude", ".codex", ".agents", "docs", "scripts", "Sources", "Tests", "fixtures", "packaging", "Resources", ".github")):
                continue
            if "<" in ref or "*" in ref:
                continue
            if not os.path.exists(ref):
                bad = True
                print(f"doc-mirror: {name}:{i} points at `{ref}`, which does not exist", file=sys.stderr)

if bad:
    sys.exit(1)
print("doc-mirror: ok")
PY
