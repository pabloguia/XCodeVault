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
bash scripts/helper-invariants.sh         # the privileged-helper invariants
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

`scripts/helper-invariants.sh` enforces the mechanical half of the helper rules — no process or
shell execution, no hand-rolled peer validation, no client-influenced deletion, a code-signing
requirement set before any connection is served, an authorization gate on every state-changing
verb — over the files as committed, and it runs in CI. The editor hooks under `.claude/hooks/` and
`.codex/hooks/` carry the same patterns and will catch a careless edit sooner, but they are a lint
on a proposed edit rather than a control: they see only the Edit and Write tools, they inspect the
new text rather than the resulting file, and they cannot tell a use of a forbidden API from a
comment mentioning one. Do not cite them as evidence that a change is safe. Neither check replaces
the human review.

## Running an experiment

The protocol is `docs/architecture/EXPERIMENTS.md`; the open questions it answers are
`docs/architecture/HYPOTHESES.md`. Briefly:

1. Pick an experiment. `scripts/experiments/` has the harness; `common.sh` supplies the environment
   header every evidence file must carry.
2. Run it. Evidence lands in `docs/research/evidence/`, named for the experiment and the
   macOS/Xcode/arch combination it was measured on.
3. Record the outcome in `COMPATIBILITY_MATRIX.md` and update the hypothesis status in
   `HYPOTHESES.md`. **A strategy is not "supported" because a copy succeeded** — the Definition of
   Done is in `docs/product/NON_GOALS_AND_SAFETY.md`, and until it is met the strategy is labelled
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

There are **two** redactors and they must stay in step: `scripts/experiments/common.sh`
(`xcv_redact`, for evidence files, tested by `scripts/experiments/test-common.sh`) and
`Sources/XCodeVaultCore/Support/Redaction.swift` (for `xcodevaultctl report`, tested by
`Tests/XCodeVaultCoreTests/RedactionTests.swift`). If you add a substitution, add it to both and
add a case to both suites — they have diverged before, and nothing compares them automatically. Every defect that
helper has shipped was invisible by inspection and obvious under a test.

## Reporting a compatibility result

Open an issue using the compatibility template. It asks for your macOS build, Xcode version and
architecture because those three are what the matrix is indexed by — a result without them cannot be
recorded.

## Security

Do not open a public issue for a vulnerability. See `SECURITY.md`.

## Licensing of contributions

XCodeVault is MIT licensed — see `LICENSE`. By opening a pull request you agree that your
contribution is licensed under those same MIT terms, and that you have the right to license it that
way.

This clause exists because `docs/adr/0005-public-open-source-release.md` chose MIT over Apache-2.0
knowing that Apache-2.0 §5 would have made inbound terms unambiguous without a CLA. That benefit was
given up deliberately; this paragraph is what replaces it, and it is cheaper to state now than to
retrofit by contacting every past contributor.

Do not paste code from another project into a pull request. If a change genuinely needs third-party
code, say so in the description with the source and its licence, so the entry can be added to
`THIRD-PARTY-LICENSES.md` before the change is merged.

## Configuration is mirrored three ways

`.claude/` is the Claude Code configuration. `.codex/` mirrors its agents (as `.toml`) and its hooks
(byte-identically) for Codex, and `.agents/skills/` is a third, byte-identical copy of
`.claude/skills/`. **An edit to any agent, skill or hook has to be made in every copy that has one.**
Nothing enforces that automatically.

One asymmetry is worth knowing about rather than discovering: the Claude agent definitions restrict
their own tools — `helper-security-reviewer` is given `Read`, `Grep`, `Glob` and three read-only git
verbs, so it is structurally incapable of editing the helper it reviews. The `.codex/*.toml` mirrors
carry the same instruction in prose ("You review; you never edit") but no equivalent restriction, so
under Codex the independence of a security review is a convention rather than a constraint. Treat a
Codex-run helper review accordingly.

## Two ways this repository has already lost work

Both happened here, to people who knew better. They are written down because the shape of each is
easy to walk into again.

**`git checkout -- <file>` restores the *committed* content and destroys everything uncommitted in
that file.** A session cleaning up after a mutation test restored one file and silently undid an
entire uncommitted refactor of the privileged helper — three hours after a commit that had
criticised exactly this pattern somewhere else. If you are undoing a deliberate edit, make the tree
clean and committed first, or work in a `git worktree`. Never reach for `git checkout --` as an undo
while other uncommitted work shares the file.

**A mutation can pass for the wrong reason.** A deletion rule was mutation-tested by breaking the one
file that already carried an exemption marker, so the comparison succeeded by accident. The shell
defect that made the rule inert in every *other* file only surfaced when someone else mutated a
different file. Choose the mutation subject so that the check must do real work to catch it — and
prefer a file you did not write the rule against.

## Never force-push `main`

History was rewritten once, before the first push, for the reason recorded in
`docs/adr/0005-public-open-source-release.md`: there was no remote, so there were no clones to break
and no collaborator to coordinate with. **That window closed at publication.** After the first push a
rewrite breaks every clone and is not available as a fix, however tempting. If you believe one is
necessary, open an issue and argue for it; do not do it.

## The redactor covers evidence files only

`scripts/experiments/common.sh` and `Sources/XCodeVaultCore/Support/Redaction.swift` filter evidence
output and `xcodevaultctl report`. **Source, tests, hook configuration and documentation are not
redacted on the way out** — and both identity leaks found before publication were in exactly those
places: a home directory hard-coded in `.codex/hooks.json`, and machine-specific paths in a test
comment. Never commit a personal path, home directory, volume label, device identifier or secret as
a fixture or a default. When a test needs a real path, build it at run time.

And when you do redact an evidence file, the hard part is not finding the identifying strings — it
is removing them without destroying the evidence. Afterwards, read at least two of the redacted files
end to end and confirm you can still tell what was measured. **An illegible evidence file is worse
than no evidence file, because it still looks like a record.**

_(These three rules were rehoused from `BOOTSTRAP_PROMPT.md` and
`docs/process/PROMPT-PUBLICATION-PREP.md` during the 2026-09-18 pre-publication review, before those
completed briefs were deleted. Each was the only copy.)_
