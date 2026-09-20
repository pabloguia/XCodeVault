#!/bin/bash
# Assert MigrationEngine's public surface, as the *compiler* sees it.
#
# **Why this exists (issue #32).** `MigrationEngineSeamDisciplineTests` asserts the same properties
# by reading the source text, and six independent reviews walked past it six times: it read the
# wrong initialiser; its parameter splitter counted `->`'s `>` as a bracket; it scanned only the
# struct body; it searched the literal `"init("` so `init<T>(` was invisible; it sliced parameter
# lists out of raw text so one unbalanced `(` in a comment collapsed the list; and it missed a
# `public mutating func`. Each was closed, and the sixth review then produced
# `public static func withHooks(...)` and a non-mutating `withAfterCopy(_:)` — build-clean,
# lint-clean, passing all four tests.
#
# Enumerating member shapes does not terminate, so this asks the compiler instead. Be precise about
# what that buys, because the first version of this comment was not: the **extraction** is
# spelling-proof — `symbolgraph-extract` reports the API however it is written, so an attribute, a
# generic, an extension, a factory or a subscript cannot hide a member from it. The **rules below
# are still text patterns** over the rendered declarations, and a reviewer walked past them six ways
# within an hour of the gate being written. Claiming otherwise is the same overclaim that made the
# source-scanning test vacuous three times, restated about its replacement.
#
# What the extraction does buy is real and the text scanner cannot have it: `@MainActor public var`
# renders as `@MainActor var journal2: Int` here and is caught, where a line-anchored regex over
# source sees an attribute and stops.
#
# Measured against the six shapes a reviewer produced: a `typealias` sugaring the closure, a
# `public static var`, `-> ()` spelled instead of `-> Void`, a non-throwing closure, a protocol-typed
# observer, and a free function outside the type. All six are caught — the last two because rule 1
# runs module-wide rather than over one type's members.
#
# Still open, recorded rather than claimed closed (issue #32): a hook whose closure takes something
# other than `MigrationPlan` or `String`, and a protocol whose method is not named `afterCopy`/
# `afterRenameAside`. Both put a caller-supplied call one rename away from every pattern here. The
# rules are patterns; only the extraction is spelling-proof.
#
# Two rules, both about capability rather than style:
#   1. No public member may mention a fault-injection hook — a caller-supplied throwing closure the
#      engine runs mid-migration. These exist for tests and live behind an `internal` initialiser.
#   2. No public property may be `var`. Every seam is set through `init` and stays set (#27, #31);
#      a settable one is a shipped check that can be switched off after construction.
set -euo pipefail
cd "$(dirname "$0")/.."

TYPE="MigrationEngine"
MODULE="XCodeVaultCore"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Build first, always. `symbolgraph-extract` reads whatever is in `.build`, so running this against
# a stale module reports on code that is no longer here — in either direction. The first version of
# this script did exactly that and failed on a member that had already been removed from the source.
# The build is incremental and costs nothing when the tree is current.
swift build >/dev/null

ARCH="$(uname -m)"
MODULES=".build/debug/Modules"
[ -d "$MODULES" ] || { echo "!! $MODULES missing after a successful build — layout changed?"; exit 1; }

# Hoisted out of the argument list: a failing command substitution *there* does not abort under
# `set -e`, so a missing SDK would have passed `-sdk ""` and failed somewhere less informative.
SDK="$(xcrun --show-sdk-path)"

xcrun swift-symbolgraph-extract \
    -module-name "$MODULE" -target "${ARCH}-apple-macosx14.0" \
    -sdk "$SDK" -I "$MODULES" -output-dir "$OUT" >/dev/null

python3 - "$OUT/$MODULE.symbols.json" "$TYPE" <<'PY'
import json, sys, re

graph, type_name = sys.argv[1], sys.argv[2]
symbols = json.load(open(graph))["symbols"]
members = [s for s in symbols if s["pathComponents"][:1] == [type_name]]


def declaration(s):
    return "".join(f["spelling"] for f in s.get("declarationFragments", []))


# Positive control. An extraction that silently produced nothing, or that read some other module,
# would otherwise report a clean surface — the failure mode this whole issue is about. The six
# seams named here are `let` in the shipped type and are what rule 2 is protecting.
seams = {"runner", "journal", "verifier", "home", "isXcodeRunning", "volumeUUIDAt"}
found = {s["pathComponents"][-1] for s in members}
missing = seams - found
if missing:
    print(f"!! the symbol graph does not contain {type_name}'s seams: {sorted(missing)}")
    print("   Nothing below is checking anything. The extraction read the wrong module, or the type changed shape.")
    sys.exit(1)

failures = []
# Rule 1 runs over **every** public symbol, not just this type's members. A free function or another
# type's factory hands out an engine with a hook installed exactly as well as a member does, and
# narrowing the scan to `pathComponents[:1] == [type_name]` meant `public func
# makeInstrumentedEngine(afterCopy:)` — which carries both the literal label and the literal closure
# — was never even examined. Rule 2 stays scoped to the type, since it is about this type's seams.
for s in symbols:
    decl = declaration(s)
    public = s.get("accessLevel") == "public"
    name = ".".join(s["pathComponents"])
    is_member = s["pathComponents"][:1] == [type_name]

    # Rule 1 — a parenthesised throwing closure returning Void is the shape of both hooks. A
    # function that merely `throws` does not match: `copyAndVerify(_:)` reads
    # `throws -> MigrationOutcome`, with no parenthesised closure.
    # No mandatory closing paren, and `()` as well as `Void`. Requiring `\)` meant a
    # `public typealias Hook = @Sendable (MigrationPlan) throws -> Void` was not matched at its own
    # declaration, and an initialiser taking `hook: Hook?` then renders with no closure text at all —
    # two lines to defeat the whole rule. Spelling the return type `-> ()` did the same.
    # A third shape: any closure taking a `MigrationPlan`, throwing or not. A reviewer's
    # `checkpoint: (@Sendable (MigrationPlan) -> Void)?` installed a real hook and passed the first
    # two patterns — it is still a seam, because it can mutate captured state, block, or exit
    # mid-migration. `copyAndVerify(_ plan: MigrationPlan) throws -> MigrationOutcome` does not
    # collide: its rendering is `(_ plan: MigrationPlan)`, not the bare `(MigrationPlan)` of a
    # closure type.
    if public and (
        re.search(r"throws\s*->\s*(Void|\(\s*\))", decl)
        or re.search(r"\bafter(Copy|RenameAside)\b", decl)
        or re.search(r"\(MigrationPlan\)\s*(throws\s*)?->", decl)
    ):
        failures.append((name, "takes or exposes a fault-injection hook on the public API", decl))

    # Rule 2 — settable after construction, from outside this module.
    #
    # `var` as a token anywhere, not anchored at the start: `@MainActor public var journal2: Int`
    # reads `@MainActor var journal2: Int` here, and an anchored match missed it — the same blind
    # spot the text scanner has, reproduced in the check meant to be immune to it.
    #
    # `{ get }` means the compiler is telling us the setter is not public. `internal(set) public var`
    # reads `var journal3: Int { get }`, is not publicly settable, and flagging it was a false
    # positive — caught for the wrong reason. It is still settable *within* this module, which the
    # source-scanning test covers for ordinary spellings and not for this one; recorded in #32.
    # `swift.type.property` too: `public static var faultsEnabled` is a publicly settable switch on
    # the engine, and equality against `swift.property` alone skipped it. The source-scanning test
    # misses it as well — after `public ` comes `static `, which its regex does not expect.
    if is_member and public and s["kind"]["identifier"] in ("swift.property", "swift.type.property") and re.search(r"\bvar\b", decl):
        if not re.search(r"\{\s*get\s*\}\s*$", decl):
            failures.append((name, "is publicly settable; every seam must be `let`, set through `init`", decl))

if failures:
    print(f"!! {type_name}'s public surface regressed (issues #27, #31, #32):")
    for name, why, decl in failures:
        print(f"   {name}\n       {why}\n       {decl[:150]}")
    sys.exit(1)

print(f"public-surface: ok ({len(members)} public members of {type_name}, {len(seams)} seams verified present)")
PY
