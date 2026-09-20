#!/bin/bash
# Assert the public surface of the seam-bearing types, as the *compiler* sees it.
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
# Three rules, all about capability rather than style:
#   1. No public member may mention a fault-injection hook — a caller-supplied throwing closure the
#      engine runs mid-migration. These exist for tests and live behind an `internal` initialiser.
#   2. No public property may be `var`. Every seam is set through `init` and stays set (#27, #31);
#      a settable one is a shipped check that can be switched off after construction.
set -euo pipefail
cd "$(dirname "$0")/.."

TYPES="MigrationEngine VaultVerifier CleanPlanner CleanExecutor"
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

python3 - "$OUT/$MODULE.symbols.json" $TYPES <<'PY'
import json, sys, re

graph, type_names = sys.argv[1], sys.argv[2:]
symbols = json.load(open(graph))["symbols"]
members = [s for s in symbols if s["pathComponents"][:1] and s["pathComponents"][0] in type_names]


def declaration(s):
    return "".join(f["spelling"] for f in s.get("declarationFragments", []))


# Positive control, per type. An extraction that silently produced nothing, or that read some other
# module, would otherwise report a clean surface — the failure mode this whole gate is about.
#
# Keyed by type, not flattened into one set. A union answers "does this name exist on *any* of these
# types", and `CleanPlanner`'s only seam is `home`, which two of its siblings also have — so it could
# vanish from the module entirely and this still reported ok. A reviewer deleted it from a synthetic
# graph and got `ok (9 members across 4 types, 9 seams verified present)`: the count came from argv,
# not from what was found. That is the silent-empty failure the control exists to prevent,
# reintroduced for one of four types by the change that added the other three.
seams = {
    "MigrationEngine": {"runner", "journal", "verifier", "home", "isXcodeRunning", "volumeUUIDAt"},
    "VaultVerifier": {"registry", "mountedVolumes", "isMountPoint"},
    "CleanPlanner": {"home"},
    "CleanExecutor": {"journal", "home", "useTrash", "isXcodeRunning", "runner"},
}
absent = []
for owner, want in seams.items():
    have = {s["pathComponents"][-1] for s in members if s["pathComponents"][0] == owner}
    if want - have:
        absent.append(f"{owner}: {sorted(want - have)}")
if absent:
    print("!! the symbol graph does not contain these seams:")
    for a in absent:
        print(f"   {a}")
    print("   Nothing below is checking anything. The extraction read the wrong module, or a type changed shape.")
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
    is_member = bool(s["pathComponents"][:1]) and s["pathComponents"][0] in type_names

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

# Rule 3 — the shipped default of a safety seam must be the real check.
#
# `symbolgraph-extract` renders default arguments verbatim, which pins something no behavioural test
# on this machine can. Changing `CleanExecutor.init`'s `isXcodeRunning` default to `{ false }` —
# which in production disables the refusal that stops a delete while Xcode is open — survives all
# 439 tests, because with Xcode closed the stub and the real check are indistinguishable. Asserting
# the *declaration* costs nothing and cannot pass vacuously.
#
# `VaultRegistry.register`'s `volumeUUID` is the largest of these: it is the positive identity
# assertion that disconnect safety actually rests on, it is a parameter rather than a property so
# rule 2 cannot see it, and no test pins its default either.
DEFAULTS = [
    ("CleanExecutor", "init", "isXcodeRunning", "CleanExecutor.xcodeIsRunning"),
    ("MigrationEngine", "init", "isXcodeRunning", "CleanExecutor.xcodeIsRunning"),
    ("MigrationEngine", "init", "volumeUUIDAt", "MountStatus.volumeUUID(at:)"),
    ("VaultVerifier", "init", "isMountPoint", "MountStatus.isMountPoint($0)"),
    ("VaultRegistry", "register", "isMountPoint", "MountStatus.isMountPoint($0)"),
    ("VaultRegistry", "register", "volumeUUID", "MountStatus.volumeUUID(at: $0)"),
]
for owner, member, param, expected in DEFAULTS:
    seen = [
        s for s in symbols
        if s["pathComponents"][:1] == [owner] and s["pathComponents"][-1].startswith(member) and f"{param}:" in declaration(s)
    ]
    # Positive control per entry: a renamed parameter or member makes this rule silently check
    # nothing, which is the failure this file has had to be rescued from repeatedly.
    if not seen:
        failures.append((f"{owner}.{member}", f"declares no `{param}:` — this rule is now checking nothing and must be updated", ""))
        continue
    for s in seen:
        decl = declaration(s)
        # The `{ ... }` is optional: half of these defaults are a bare function reference
        # (`CleanExecutor.xcodeIsRunning`) and half are a closure wrapping a call
        # (`{ MountStatus.isMountPoint($0) }`). Requiring the call to sit immediately after `=`
        # failed on the second kind — which the gate reported as three regressions on a clean tree,
        # a false positive that would have taught the next reader to distrust it.
        if not re.search(rf"{re.escape(param)}\s*:[^=]*=\s*\{{?\s*{re.escape(expected)}", decl):
            actual = re.search(rf"{re.escape(param)}\s*:[^=]*=\s*([^,]+)", decl)
            failures.append((
                f"{owner}.{member}", f"`{param}` no longer defaults to `{expected}` — a safety check replaced at its wiring",
                (actual.group(0) if actual else decl)[:150]))

if failures:
    print("!! the public surface regressed (issues #27, #31, #32, #33):")
    for name, why, decl in failures:
        print(f"   {name}\n       {why}\n       {decl[:150]}")
    sys.exit(1)

print(f"public-surface: ok ({len(members)} members across {len(seams)} types; {sum(len(v) for v in seams.values())} seams and {len(DEFAULTS)} safety defaults verified)")
PY
