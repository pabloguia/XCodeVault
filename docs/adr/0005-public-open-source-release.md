# ADR 0005: The repository is published publicly as open source

- Status: accepted
- Date: 2026-09-17
- Related hypotheses: none — this is a distribution and process decision, not a technical one

## Context

The project has run for two weeks with **no git remote at all**: 79 commits, nothing ever pushed.
`.github/workflows/ci.yml` has existed throughout and has therefore **never run once**.

That has a measurable cost, and this week supplied it rather than theorising it. Every claim in
`COMPATIBILITY_MATRIX.md` came from one machine, one macOS build, one Xcode, one physical USB
volume. On 2026-09-16 that machine updated from macOS 26.6.2 (25G83) to 26.7 (25G229) **in the
middle of a session**, and nothing noticed: a command aimed at a path measured that morning no
longer resolved that evening, and a figure measured inside a transient window was published to four
files before being corrected. The matrix's entire purpose is recording which combinations a claim
holds on, and it held exactly one combination — which had silently stopped being the one in use.

CI on a public repository answers this directly and permanently. The workflow already builds, runs
the 236 unit tests, lints with `swift-format`, smoke-tests the CLI read-only, and runs the two
read-only gating experiments (E1, E8) **on both `macos-15` and `macos-26`**, uploading their
evidence as artifacts. Nothing about it needs writing; it needs a remote to run on.

The repository is also, by its own `CLAUDE.md`, "an open-source macOS app". Publishing makes that
true rather than aspirational, and GitHub grants public repositories unmetered Actions minutes on
standard runners, which is what a two-OS matrix needs.

## Decision

**Publish the repository publicly, as open source.**

Three sub-decisions are deliberately left open here, because they are the owner's to make and are
recorded when made:

1. **Licence.** None is present. Without one the code is "source available", not open source, and
   nobody may legally use it. This must be chosen before the first push.
2. **Authorship in history.** All 79 commits carry a real name and a personal email address.
   Publishing publishes those. Rewriting them is possible only before the first push, and only by
   rewriting every commit.
3. **Volume and path identifiers in evidence.** The research evidence names the owner's home
   directory, account name, external volume label, that volume's UUID, and the personal folders on
   it. These are redacted before publication — see Consequences.

## Consequences

**What this makes easier.** CI becomes real: two macOS versions, on every push, with evidence
uploaded. The matrix stops being a single-machine document. External reproduction of any experiment
becomes possible, which is the only route by which `probable` findings such as H6 become `verified`
without this project buying hardware.

**What this makes harder, and permanently.** Publication is irreversible in practice: a public
repository is cloned, cached and indexed within minutes. Everything in the history — 79 commits of
evidence files, research notes and status journals — becomes public simultaneously, not just the
current tree. The redaction therefore has to be done *before* the first push, not after it.

**What we are explicitly not doing.** Not rewriting history to remove authorship unless the owner
asks; not publishing the owner's machine identifiers; not treating the privileged helper as
reviewed-for-public-consumption merely because it is now visible — `SECURITY_MODEL.md` and the
helper-security review process continue to govern it, and a public repository raises the stakes on
both rather than lowering them.

**A standing obligation this creates.** Every future evidence file is published. `xcv_redact` in
`scripts/experiments/common.sh` already rewrites the invoking user's home and account name, and was
made root-aware on 2026-09-16. It does **not** cover volume labels, volume UUIDs or folder names,
and that gap is now a publication concern rather than a tidiness one.

## Evidence

- `docs/architecture/COMPATIBILITY_MATRIX.md` — every entry before 2026-09-16 reads
  "macOS 26.6.2 (25G83)"; the re-baseline entries record the OS moving underneath them.
- `STATUS.md`, entries for 2026-09-16 and 2026-09-17 — the measured cost of single-machine claims,
  including a reclaim figure published from inside a transient window and corrected four files later.
- `.github/workflows/ci.yml` — the workflow that has never executed.
