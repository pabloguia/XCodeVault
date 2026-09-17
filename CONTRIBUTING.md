# Contributing to XCodeVault

The most valuable contribution to this project is **not code**. It is a run of an experiment on a
machine that is not the author's.

Every compatibility claim in `docs/architecture/COMPATIBILITY_MATRIX.md` was measured on a single
Mac, a single macOS build, a single Xcode and a single external volume. Several findings are marked
`probable` for exactly that reason, and no amount of code review upgrades them. A second machine
does. If you have a different architecture, a different macOS, an Apple silicon Mac, or a different
external drive, see "Running an experiment" below — that is the contribution this project is short
of.

## Build and test

```bash
swift build
swift test
bash scripts/experiments/test-common.sh   # the redaction helper
```

Requires macOS 14 or later and a recent Xcode. The package targets Swift 6.

## The commit gate

**Do not commit unless `swift build` and `swift test` both exit 0, checked directly.**

Check the real exit status, not a grep of the output. A test summary line saying "0 failures" can
coexist with a non-zero exit, and a build that fails prints text that still contains the word
`Compiling`. Note that in `zsh` — the default macOS shell — `${PIPESTATUS[0]}` is empty; the array
is `${pipestatus[1]}` there. The portable habit is to avoid the pipe entirely:

```bash
swift test > /tmp/test.log 2>&1; rc=$?; echo "exit=$rc"
```

The same trap exists in CI: a step written as `swift build | tail -20` reports `tail`'s status and
passes even when the build fails. Any step in `.github/workflows/ci.yml` that pipes must set
`set -o pipefail` first.

Formatting is `swift-format` with `.swift-format` (4-space indent, 160 columns).

## Safety rules that are not negotiable

Read `docs/product/NON_GOALS_AND_SAFETY.md` before touching anything that mounts, copies, deletes,
or runs as root. The short version, which `CLAUDE.md` also carries:

- SIP is never disabled, and never a prerequisite for a documented flow.
- `/System` is never modified.
- The privileged helper exposes an allowlisted API only — no arbitrary shell, no client-supplied
  paths, no generic `rm`/`mv`/`mount`.
- Source data is never deleted before a migration is verified and reversible.
- Archives and other non-regenerable artifacts are never auto-deleted.
- `~/Library/Developer/CoreSimulator` is **never** symlinked, at any risk level, including to a
  target on the same internal disk. The prior art does this; do not inherit it.

Two kinds of change require an independent review before merge, by someone who did not write it:

- anything under `Sources/XCodeVaultHelper`, `Sources/XCodeVaultHelperProtocol`, the XPC client
  code, the launchd plist or the signing scripts — a **helper security review**;
- anything that copies, moves, deletes, mounts or restores user data — a **migration safety
  review**.

The review prompts live in `.claude/agents/` and `.codex/agents/` and are worth reading even if you
run the review by hand: they are the checklist.

## Running an experiment

The protocol is `docs/architecture/EXPERIMENTS.md`; the open questions it answers are
`docs/architecture/HYPOTHESES.md`. Briefly:

1. Pick an experiment. `scripts/experiments/` has the harness; `common.sh` supplies the environment
   header every evidence file must carry.
2. Run it. Evidence lands in `docs/research/evidence/`, named for the experiment and the
   macOS/Xcode/arch combination it was measured on.
3. Record the outcome in `COMPATIBILITY_MATRIX.md` and update the hypothesis status in
   `HYPOTHESES.md`. **A strategy is not "supported" because a copy succeeded** — the Definition of
   Done is in `docs/process/EXECUTION_PHASES.md`, and until it is met the strategy is labelled
   experimental in code, CLI help, UI and docs alike.

Do not turn an unreproduced forum workaround into product behaviour. Reproduce it, record the
evidence, and cite it.

### Scripts that change your machine

Most experiments are read-only. Some are not, and those refuse to run without an explicit
acknowledgement flag:

```bash
scripts/experiments/e14b-control-internal-create.sh --i-understand
sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand --delete
```

`--i-understand` means what it says: these **create or destroy simulator devices, or delete files as
root**. Read the script's header before running it. Do not run one against a machine whose simulator
state you care about, and never against one that is running someone else's test suite — check
`pgrep -fl xcodebuild` first.

### Evidence is published

Every evidence file in this repository is public, so the harness redacts identifying strings on the
way out: the home directory, the account name, mounted volume labels and their UUIDs, and any folder
named in `XCV_PRIVATE_DIRS`. This is `xcv_redact` in `scripts/experiments/common.sh`, and it detects
volumes rather than being configured with them, because a redactor you have to remember is one that
leaks the single time you forget.

It deliberately does **not** redact CoreSimulator's own runtime and device identifiers, or Apple's
APFS partition-type GUID: those belong to nobody, and several findings depend on being able to read
them. If a volume label of yours is also an ordinary English word, `XCV_REDACT_KEEP` opts it out.

If you add a substitution, add a case to `scripts/experiments/test-common.sh`. Every defect that
helper has shipped was invisible by inspection and obvious under a test.

## Reporting a compatibility result

Open an issue using the compatibility template. It asks for your macOS build, Xcode version and
architecture because those three are what the matrix is indexed by — a result without them cannot be
recorded.

## Security

Do not open a public issue for a vulnerability. See `SECURITY.md`.
