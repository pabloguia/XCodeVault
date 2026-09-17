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

Three sub-decisions were left open when this ADR was first written, because they are the owner's
to make. All three were made on 2026-09-17 and are recorded here.

1. **Licence: MIT.** Without one the code was source-available, not open source, and nobody could
   legally use it. MIT is what `README.md` had been promising, is the norm for a macOS utility of
   this kind, and carries the least friction for a user. Apache-2.0 was considered for its explicit
   patent grant and its §5 inbound=outbound clause, which would make external contributions
   unambiguous without a CLA — a real benefit for a project whose main ask is external experiment
   runs. It was not chosen: the patent exposure here is negligible, since the mechanisms are Apple's
   (`simctl`, `ditto`, APFS), and Apache-2.0 adds a standing NOTICE obligation for no gain against
   that risk. The copyright line names the owner, which is consistent with sub-decision 2.

2. **Authorship in history: kept as it is.** All commits continue to carry the owner's real name and
   personal email address, and publishing publishes both, permanently and harvestably. The
   alternatives — an `@users.noreply.github.com` address, or a full pseudonym — were declined.
   Pseudonymising the commits would in any case have been undone by the MIT copyright line, which
   names the owner; the two decisions are coupled, and only a consistent pair would have achieved
   anything.

3. **Volume and path identifiers in evidence: redacted, and the history rewritten to match.** The
   tree is redacted (see Consequences). Because redacting the tree does not redact the ancestors,
   and because a public repository is cloned within minutes, history is rewritten before the first
   push. This is the only moment at which that rewrite is free: there is no remote, so there are no
   clones to break and no collaborator to coordinate with.

A fourth decision, not anticipated when this ADR was written: **the agent tooling under `.claude/`
and `.codex/` is published.** The three review agents and two hooks encode this project's review
discipline — the helper security review, the migration safety review, the experiment protocol — and
that is precisely what an incoming contributor needs in order to follow it. `.codex/hooks.json`
hard-coded the owner's home directory, which was a leak and also a plain bug: the hook could never
have fired for anybody else. It now resolves the repository root the way `.claude/settings.json`
already did.

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
`scripts/experiments/common.sh` rewrote the invoking user's home and account name, and was made
root-aware on 2026-09-16. It did **not** cover volume labels, volume UUIDs or folder names. That gap
was closed on 2026-09-17: volumes are now detected rather than configured, because a redactor that
has to be remembered is one that leaks the single time it is forgotten, and the helper has a test
suite (`scripts/experiments/test-common.sh`) which also pins what must *survive* redaction.

## What the redaction covered, and what it deliberately did not

The inventory in the publication brief was measured before the work started and was wrong in five
ways, each of which would have cost something if acted on literally. Recorded here because the
distinction it gets wrong — *personal* versus merely *specific* — is the one that recurs.

- **`mac-ssd-rescue` is not a personal folder.** The brief listed it as one, across 18 files. It is
  the prior-art tool whose on-disk layout `doctor` detects (`prior-tool:mac-ssd-rescue`), and it is
  load-bearing in `Doctor.swift`, `PRIOR_ART.md` and eight tests. Redacting it would have broken the
  product. The genuinely personal folders were `backup-ios` and `parallels`, in two files.
- **Almost none of the "30 files of device/volume UUIDs" were personal.** They are CoreSimulator
  runtime UUIDs, simulator device UDIDs and experiment probe UDIDs — generated by CoreSimulator,
  owned by nobody, and load-bearing: the E8 round-trip is the observation that one of them changes.
  Exactly one volume UUID was the owner's.
- **There were no disk serials.** The four files were `serial queue` and `PropertyListSerialization`.
- **There was an email address and a full name in the tree**, which the brief stated there were not.
  Both were in the brief itself.
- **Physical device identity was missing from the inventory entirely.** The E9 evidence listed the
  owner's paired iPhone and Apple Watch by name, hostname and CoreDevice identifier. Those are
  personal in a way a volume label is not; they are redacted, and the device *models* — which is
  what E9 turns on — are kept.

Two things were rewritten rather than substituted, because a placeholder would have turned a
measured fact into a claim about something that never existed: the two comments in `M2Tests` that
record how `resolvingSymlinksInPath` behaved on a machine with that volume mounted.

`41504653-0000-11AA-AA11-00306543ECAC` is Apple's APFS partition-type GUID. It identifies a
filesystem format, not anyone's hardware, and is untouched.

## What remains visible in the history

History was rewritten (sub-decision 3), so the personal strings do not survive in the ancestors.
Two things do:

- **Authorship**, by decision 2 — every commit still carries the owner's name and email.
- **Commit messages**, which were not rewritten. They describe the work, not the machine.

Nineteen commit SHAs are cited in the tree — eight in `STATUS.md`, one in a session prompt, and ten
in evidence files that record which commit a measurement was taken at. The rewrite invalidates all
of them. `STATUS.md` is a living journal and its references are updated; the evidence files are
records of a measurement and are **not** edited after the fact. The mapping from pre-rewrite to
post-rewrite commits is in `docs/process/HISTORY-REWRITE-2026-09-17.md`.

## Evidence

- `docs/architecture/COMPATIBILITY_MATRIX.md` — every entry before 2026-09-16 reads
  "macOS 26.6.2 (25G83)"; the re-baseline entries record the OS moving underneath them.
- `STATUS.md`, entries for 2026-09-16 and 2026-09-17 — the measured cost of single-machine claims,
  including a reclaim figure published from inside a transient window and corrected four files later.
- `.github/workflows/ci.yml` — the workflow that has never executed.
