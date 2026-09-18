#!/bin/bash
# CLAUDE.md and AGENTS.md are the same document addressed to two tools. They have drifted four
# times: `.Codex/` with a capital C, the Definition-of-Done pointer in rule 10 (a safety rule), the
# `XCodeVaultHelperCore` target missing from both Layout paragraphs, and two AGENTS.md pointers to
# `.codex/skills/`, a directory that does not exist. Each was found by a human noticing, which is
# not a control.
#
# This compares the two after normalising the differences that are SUPPOSED to exist — the tool
# names and config directories — and fails if anything else differs. It takes no position on
# whether the duplication should exist: if it is removed, delete this script with it.
#
# A differ alone catches only one of the four historical drifts. The other three each needed a
# check of a different shape, and all three were added after a mutation proved the differ blind to
# them (2026-09-17 review; the mutations are recorded in docs/process/REVIEW-2026-09-17.md):
#
#   1. DIRECTIONAL normalisation. Mapping `.codex/` onto `.claude/` in *both* documents is what hid
#      the dead `.codex/skills/` pointers, and it cuts the other way too: with a symmetric swap,
#      CLAUDE.md could be edited to point Claude at `.agents/skills/` and the diff stayed clean.
#      So AGENTS.md is normalised toward CLAUDE.md, never the reverse, and each document is then
#      asserted to carry only its own tool's directories.
#   2. EXISTENCE, including root files. The path regex used to require a `/`, so `STATUS.md` —
#      renamed in both files at once — was never evaluated.
#   3. REQUIRED POINTERS. A clause deleted from *both* documents is invisible to any differ, by
#      construction. That is drift #3 exactly. The only defence is a positive assertion that a
#      fixed list of tokens is present, so the list below is load-bearing: adding a target or a
#      control script means adding it here.
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

# The intended differences, and only these. Applied to AGENTS.md ONLY — see note 1 in the header.
SWAPS = [(".codex/", ".claude/"), (".agents/", ".claude/"), ("Codex", "Claude Code"), ("AGENTS.md", "CLAUDE.md")]

# Tokens every copy must contain, whichever tool it addresses. This is the only check that survives
# an edit made identically to both files. Keep it short: each entry must be something whose absence
# is a real defect, not a style preference.
REQUIRED = [
    "Sources/XCodeVaultCore",        # the single domain layer (ADR-0003)
    "Sources/XCodeVaultHelperCore",  # drift #3: deleted from both Layout paragraphs at once
    "Sources/XCodeVaultHelperProtocol",
    "Sources/XCodeVaultHelper",
    "scripts/helper-invariants.sh",  # a CI control; was absent from Layout while packaging was not
    "scripts/check-doc-mirror.sh",   # this script, for the same reason
    "STATUS.md",
    "docs/product/NON_GOALS_AND_SAFETY.md",
    "docs/process/SESSION-HANDOFF.md",
]

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
# Directional: AGENTS.md is normalised toward CLAUDE.md; CLAUDE.md is compared as written.
diff = list(difflib.unified_diff([l.rstrip() for l in a], norm(b), "CLAUDE.md", "AGENTS.md", lineterm="", n=1))
if diff:
    bad = True
    print("doc-mirror: CLAUDE.md and AGENTS.md have drifted.", file=sys.stderr)
    print("Every difference below is unintended — the tool-name and directory swaps are", file=sys.stderr)
    print("already normalised away. Fix the file that is wrong, not this script.\n", file=sys.stderr)
    print("\n".join(diff), file=sys.stderr)

# Each document may name only its own tool's configuration directories. Without this, the swap
# table itself becomes the hole: `.agents/` in CLAUDE.md normalises to `.claude/` and matches.
FOREIGN = {"CLAUDE.md": (".codex/", ".agents/"), "AGENTS.md": (".claude/",)}
for name, lines in (("CLAUDE.md", a), ("AGENTS.md", b)):
    for i, line in enumerate(lines, 1):
        for token in FOREIGN[name]:
            if token in line:
                bad = True
                print(f"doc-mirror: {name}:{i} names `{token}`, which belongs to the other tool's copy", file=sys.stderr)

# Each document is also checked against the filesystem, before normalisation: a pointer that does
# not resolve is a defect even when both copies agree on it.
import os, re
PATH = re.compile(r"`(\.?[A-Za-z0-9_./-]+)`")
ROOTS = (".claude", ".codex", ".agents", "docs", "scripts", "Sources", "Tests", "fixtures", "packaging", "Resources", ".github")
for name, lines in (("CLAUDE.md", a), ("AGENTS.md", b)):
    for i, line in enumerate(lines, 1):
        for m in PATH.finditer(line):
            ref = m.group(1).rstrip("/")
            if "<" in ref or "*" in ref:
                continue
            # Judge paths this repository is supposed to contain, plus root-level files — the
            # latter have no `/` and so escaped the original regex entirely.
            if not (ref.startswith(ROOTS) or ("/" not in ref and "." in ref and os.path.splitext(ref)[1] in (".md", ".swift", ".json", ".resolved"))):
                continue
            if not os.path.exists(ref):
                bad = True
                print(f"doc-mirror: {name}:{i} points at `{ref}`, which does not exist", file=sys.stderr)

# The positive assertion. Nothing above can see a clause removed from both copies at once.
for name, lines in (("CLAUDE.md", a), ("AGENTS.md", b)):
    text = "\n".join(lines)
    swapped = "\n".join(norm(lines)) if name == "AGENTS.md" else text
    for token in REQUIRED:
        if token not in text and token not in swapped:
            bad = True
            print(f"doc-mirror: {name} no longer mentions `{token}`", file=sys.stderr)

if bad:
    sys.exit(1)
print("doc-mirror: ok")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# The two documents are not the only thing mirrored. `.claude/skills/` is copied byte-for-byte into
# `.agents/skills/`, and `.claude/hooks/` into `.codex/hooks/`. That was an unstated convention
# until a byte-identical hook was found reading `$CLAUDE_PROJECT_DIR` under Codex, where it is
# unset — the cost of mirroring without a control. CONTRIBUTING.md now states the rule; this
# enforces it.
for pair in ".claude/skills:.agents/skills" ".claude/hooks:.codex/hooks"; do
    left=${pair%%:*}; right=${pair##*:}
    if [ ! -d "$left" ] || [ ! -d "$right" ]; then
        echo "doc-mirror: $left or $right is missing; the mirror cannot be checked" >&2
        exit 1
    fi
    if ! diff -r "$left" "$right" >/dev/null 2>&1; then
        echo "doc-mirror: $left and $right have diverged:" >&2
        diff -r "$left" "$right" >&2
        exit 1
    fi
done
echo "doc-mirror: config mirrors identical"
