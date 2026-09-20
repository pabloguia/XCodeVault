#!/bin/bash
# Convert SwiftPM's LLVM coverage into Sonar's Generic Test Coverage XML.
#
# **Why a converter at all.** SwiftPM writes an LLVM profile (`.profdata`). Sonar reads either Xcode's
# own coverage format or its language-agnostic Generic Test Coverage XML. SwiftPM emits neither, so
# something has to translate — and the translation is the part that can quietly produce nothing.
#
# **Why LCOV rather than the default `-format=text`.** That JSON is a list of *segments* —
# `[line, col, count, hasCount, isRegionEntry, isGapRegion]` — from which per-line coverage has to be
# reconstructed by walking regions and tracking nesting. LCOV states the answer directly, one
# `DA:<line>,<count>` per line, which is exactly what `lineToCover` wants. The conversion below is
# therefore a rename rather than an inference: there is no arithmetic in it that could be subtly
# wrong and still produce a plausible number.
#
# **Every failure here is fatal and loud.** An empty `<coverage/>` is valid XML that Sonar imports
# without complaint, and the result is a gate reading 0% — indistinguishable on the dashboard from
# "this project has no tests". That confusion is the whole of issue #34, so this refuses to write a
# report it cannot vouch for rather than emitting a plausible-looking empty one.
#
# Usage: scripts/coverage-to-sonar.sh [output.xml]
set -uo pipefail

OUT="${1:-coverage.xml}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Floors, in the spirit of sonar-verify.sh's MIN_NCLOC: a threshold nothing can fall below is not a
# threshold. A healthy run reports on dozens of files and thousands of covered lines; these sit well
# under that and far above the zero a broken converter produces.
MIN_FILES="${MIN_COVERAGE_FILES:-20}"
MIN_COVERED="${MIN_COVERED_LINES:-500}"

# `die` REMOVES the output. Without that `rm`, a run that refuses to vouch for a report still leaves
# it at the path the scanner reads: both floor failures were verified to exit 1, print "below the
# floor", and leave a complete coverage.xml on disk. The next thing to read that path — a re-run, a
# future workflow that scans in a separate job — would import a report this script explicitly
# declined to certify. The identical defect was fixed twice in the E6b experiment scripts, which is
# why it is caught here as a rule rather than patched per failure path.
die() { rm -f "$OUT"; echo "!! coverage-to-sonar: $*" >&2; exit 1; }

cd "$ROOT" || { echo "!! coverage-to-sonar: cannot cd to $ROOT" >&2; exit 1; }

# And up front, so that a kill the `die` path never sees — a Ctrl-C, a runner timeout — cannot leave
# a PREVIOUS run's report sitting where the scanner will find it and import it as this commit's.
rm -f "$OUT"

# 1 and 2. Where SwiftPM put things — asked, not guessed.
#
# The first version of this globbed `.build` with `find`, and found nothing: `.build/debug` is a
# SYMLINK to `.build/<triple>/debug`, and `find` does not follow symlinks. `find -L` would fix the
# symptom while leaving the guess in place, and it also returns each artifact twice (once through the
# link, once through the real path). SwiftPM already knows the answer and will keep knowing it when
# the triple changes — on this machine `x86_64-apple-macosx`, on an Apple-silicon CI runner
# `arm64-apple-macosx`, which is exactly the kind of difference a hardcoded path gets wrong in CI
# only.
BIN="$(swift build --show-bin-path 2>/dev/null)"
[ -n "$BIN" ] && [ -d "$BIN" ] || die "swift build --show-bin-path gave no usable directory (got: '${BIN:-}'). Is this a SwiftPM package?"

# The profile. `swift test --enable-code-coverage` writes it; without it there is nothing to convert,
# and the caller must hear that rather than receive an empty report.
PROFDATA="$BIN/codecov/default.profdata"
[ -f "$PROFDATA" ] || die "no profile at $PROFDATA — run \`swift test --enable-code-coverage\` first."

# The binary the profile describes. Coverage counters are keyed to the instrumented binary's symbols,
# so llvm-cov needs both halves. Observed, not assumed: rebuilding the package without
# `--enable-code-coverage` and re-running this produced
#   warning: profile data may be out of date - object is newer
#   error: failed to load coverage: ... no coverage data found
# and a non-zero exit — which is why the export's stderr is kept below rather than discarded.
BUNDLE="$(find "$BIN" -maxdepth 1 -name '*.xctest' -type d 2>/dev/null | head -1)"
[ -n "$BUNDLE" ] || die "no .xctest bundle in $BIN — the test binary was not built."
BINARY="$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .xctest)"
[ -x "$BINARY" ] || die "no executable at $BINARY"

# 3. Export to a file rather than a pipe: in a pipeline llvm-cov's exit status is masked by the
#    converter's, so a failed export would arrive as "no files found" instead of as itself.
LCOV="$(mktemp -t xcv-lcov)"
ERRLOG="$(mktemp -t xcv-lcov-err)"
SUMMARY="$(mktemp -t xcv-cov-summary)"
PYERR="$(mktemp -t xcv-cov-pyerr)"
trap 'rm -f "$LCOV" "$ERRLOG" "$SUMMARY" "$PYERR"' EXIT
# stderr is KEPT, not sent to /dev/null. llvm-cov's characteristic failure is a profile written by a
# different toolchain version ("unsupported instrumentation profile format version"), and discarding
# that line leaves the operator with "export failed" and nowhere to go — a diagnosis thrown away at
# the exact moment it is the only thing worth having.
xcrun llvm-cov export -instr-profile "$PROFDATA" "$BINARY" -format=lcov >"$LCOV" 2>"$ERRLOG" \
    || die "llvm-cov export failed for $BINARY:
$(head -5 "$ERRLOG")"
# A belt-and-braces check for an export that succeeds and yields nothing. A mismatched profile does
# NOT reach here — that exits non-zero above, as the observation in step 2 records — so no cause is
# named: this reports the symptom and hands over whatever llvm-cov said, rather than inventing an
# explanation for a case that has not been seen.
[ -s "$LCOV" ] || die "llvm-cov exited 0 but produced no output for $BINARY.$([ -s "$ERRLOG" ] && printf '\n   %s' "$(head -5 "$ERRLOG")")"

# 4. Translate. Paths arrive absolute and differ between a developer's machine and a CI runner, so
#    they are re-anchored on the `Sources/` marker rather than on any particular checkout root.
# Run OUTSIDE a command substitution, writing to files.
#
# `summary="$(python3 - ... <<'PY' ... PY )"` parses on bash 5 and FAILS on bash 3.2 — which is
# /bin/bash on macOS, including the CI runner this job now uses. Inside `$( )` bash 3.2 scans for the
# closing paren in a way that an apostrophe in the heredoc body derails, so adding the word
# "script's" to a Python docstring broke the whole file with "unexpected EOF while looking for
# matching `''" pointing at a line forty below the real cause. Keeping the heredoc out of `$( )`
# removes the hazard rather than tiptoeing around the punctuation.
#
# The second reason is stderr: Python's `sys.exit("message")` writes to stderr, so the previous
# `die "conversion failed: $summary"` interpolated stdout and printed the failure with no message at
# all — the one branch that exists to explain what went wrong, explaining nothing.
python3 - "$LCOV" "$OUT" "$ROOT" >"$SUMMARY" 2>"$PYERR" <<'PY'
import os, sys, xml.etree.ElementTree as ET

lcov_path, out_path, root = sys.argv[1], sys.argv[2], sys.argv[3]

REAL_ROOT = os.path.realpath(root)


def repo_relative(path):
    """Map an absolute source path to a repo-relative one, or None if it is not ours.

    Strictly containment-based. An earlier version fell back to splitting the path on a `/Sources/`
    marker whenever it did not start with the root, and a reviewer demonstrated three ways that
    attributes other code to this project:

      * `/Users/p/Sibling/Sources/Lib/A.swift` -> `Sources/Lib/A.swift`. A `.package(path: "../Sibling")`
        dependency is compiled IN PLACE, never under `.build/`, so it walks straight past the
        `.build` guard that was supposed to be what stopped exactly this.
      * `/Users/p/XCodeVault-fork/Sources/Core/A.swift` -> `Sources/Core/A.swift`, from a sibling
        checkout.
      * with the repo under a directory literally named `Sources`, the split picks the wrong marker
        and yields a path Sonar silently drops rather than one it rejects.

    The fallback existed to survive a checkout root that differs between this machine and a CI
    runner. It bought nothing: `root` is derived from this script's own location, so it IS the
    checkout root wherever the script runs.

    Both sides are realpath'd because a checkout beneath a symlinked parent (`/tmp` -> `/private/tmp`
    on macOS) makes a plain prefix test reject paths that are genuinely inside the repo.
    """
    real = os.path.realpath(path)
    if not real.startswith(REAL_ROOT + os.sep):
        return None
    rel = real[len(REAL_ROOT) + 1:]
    # Dependencies fetched by URL are checked out under .build/, which IS inside the root.
    if rel.startswith(".build" + os.sep):
        return None
    # Only `sonar.sources`. Coverage reported against a file Sonar indexed as a test is dropped by
    # the server with a warning — a silent partial import, which is the shape being designed out.
    return rel if rel.startswith("Sources" + os.sep) else None

files, current, skipped = {}, None, 0
with open(lcov_path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("SF:"):
            current = repo_relative(line[3:])
            if current is None:
                skipped += 1
        elif line == "end_of_record":
            current = None
        elif line.startswith("DA:") and current is not None:
            number, _, count = line[3:].partition(",")
            try:
                n, c = int(number), int(float(count))
            except ValueError:
                continue
            # The entry is created HERE, on the first real line, not on `SF:`. A source file with an
            # SF record and no DA records — one holding only declarations — used to produce a
            # childless `<file/>` element, which counts toward the MIN_FILES floor while contributing
            # nothing, and whose acceptance by Sonar's importer nobody has checked. A floor padded by
            # empty entries is weaker than the number suggests, on exactly the failure path it exists
            # to catch.
            entry = files.setdefault(current, {})
            # A line can appear more than once (inlining, generic specialisations). Any execution
            # counts, so take the max: overwriting would let a later zero erase a covered line.
            entry[n] = max(entry.get(n, 0), c)

if not files:
    sys.exit("no source file under Sources/ appears in the coverage data (%d paths skipped as "
             "out-of-tree). Nothing would have been imported." % skipped)

root_el = ET.Element("coverage", version="1")
covered = total = 0
for path in sorted(files):
    file_el = ET.SubElement(root_el, "file", path=path)
    for n in sorted(files[path]):
        hit = files[path][n] > 0
        ET.SubElement(file_el, "lineToCover", lineNumber=str(n), covered="true" if hit else "false")
        total += 1
        covered += 1 if hit else 0

ET.ElementTree(root_el).write(out_path, encoding="utf-8", xml_declaration=True)
print("%d %d %d" % (len(files), covered, total))
PY
pyrc=$?
[ "$pyrc" = 0 ] || die "the LCOV-to-XML conversion failed:
   $(head -5 "$PYERR")"

read -r n_files n_covered n_total < "$SUMMARY"
case "${n_files:-}${n_covered:-}${n_total:-}" in
    '' | *[!0-9]*) die "could not read the conversion summary (got: '$(cat "$SUMMARY")')." ;;
esac

# 5. The floors. Steps 1-4 all succeed on a report covering three files, and that is exactly what a
#    half-linked test binary or a stale profile produces — so the size of the result is checked too.
[ "$n_files" -ge "$MIN_FILES" ] \
    || die "only $n_files source file(s) in the report, below the floor of $MIN_FILES. That is what a stale profile or a partly-linked test binary looks like: it converts cleanly and measures almost nothing."
[ "$n_covered" -ge "$MIN_COVERED" ] \
    || die "only $n_covered covered line(s), below the floor of $MIN_COVERED. The profile did not attach to the run; importing this would report near-zero coverage as if it were a testing problem."

printf 'coverage-to-sonar: wrote %s — %d files, %d/%d lines covered (%.1f%%)\n' \
    "$OUT" "$n_files" "$n_covered" "$n_total" \
    "$(python3 -c "print(100.0*$n_covered/$n_total if $n_total else 0.0)")"
