# History rewrite, 2026-09-17

Before the first push, the entire history was rewritten to remove the owner's machine identifiers
from every commit. This note exists because the rewrite invalidated every commit SHA, and several
documents cite them.

## Why

Redacting the working tree does not redact the ancestors. A public repository is cloned, cached and
indexed within minutes, and everything in the history becomes public at the same moment as the tip
— so the redaction had to reach the whole history, and had to happen before the first push. See
`docs/adr/0005-public-open-source-release.md`.

This was the only moment at which the rewrite was free. There was no remote, so there were no
clones to break and no collaborator to coordinate with.

## What changed, and what did not

**Changed.** Every commit SHA, because every tree that contained one of the redacted strings
changed. 86 commits, all of them re-hashed.

**Not changed:**

- **Authorship.** Names, email addresses, author dates and committer dates are all preserved, by
  decision (ADR-0005, sub-decision 2).
- **Commit messages.** They describe the work, not the machine; none was edited.
- **The tip.** `HEAD^{tree}` after the rewrite is byte-identical to `HEAD^{tree}` before it. The
  filter was verified to be a no-op on the already-redacted tip, so it only ever touched ancestors.
- **Order and count.** No commit was dropped, squashed or reordered.

Two things survive in the history on purpose: the copyright holder's name in `LICENSE`, and the
same name in historical versions of `docs/process/PROMPT-PUBLICATION-PREP.md`. Neither is an
additional exposure — every one of the 86 commits carries that name in its author field, by
decision.

## Verification

Every blob reachable from the rewritten branch was scanned — 566 of 566, with a positive control
(a string known to be present, found in 392 of them, proving the scan was actually running). The
control matters: an earlier attempt at this check used `git grep` across all 86 revisions at once,
silently hit the argument-length limit, and reported zero occurrences of everything, including the
control.

The rewrite also had to be rehearsed twice on a throwaway clone before it was correct. The first
rehearsal destroyed the `LICENSE` copyright line and rewrote a test fixture into a tautology; the
second revealed a `sed` pattern written for one literal backslash against a file containing two,
and a runbook that greps for the first eight characters of a UUID, which the full-value rule could
not see.

## The SHA map

Nine commits were cited by SHA in `STATUS.md` and `docs/process/PROMPT-NEXT-SESSION.md`. Those
references have been updated in place. The mapping:

| before | after | subject |
|---|---|---|
| `d67c746` | `923208f` | Catalogue the regenerable data inside simulator devices |
| `955e993` | `1cdbc95` | Run the reboot probe, and stop telling people to restart |
| `b82010c` | `149300e` | Write the root-deletion probe, and make its witnesses admissible |
| `4839a8a` | `9eaf171` | The orphan is gone, and no probe of ours removed it |
| `62ab0bf` | `2bf6e77` | Correct the reclaim figure, and re-baseline the handoff |
| `5dfa462` | `3c23d72` | Rewrite e8c, and stop it sweeping devices the product refuses |
| `859791a` | `15eee32` | Re-baseline the read-only half of the matrix on macOS 26.7 |
| `bf21c25` | `8da354c` | Re-verify E2 and E12 on macOS 26.7 |
| `3a21954` | `eff78c1` | Stop parsing the journal for values that decide deletions |

**Ten evidence files also cite a pre-rewrite SHA, and those are deliberately left alone.** An
evidence file records what was measured and when; editing one after the fact to name a different
commit is rewriting the record of a measurement, which is a different and worse thing than
redacting a volume label out of it. A reader who finds `XCodeVault @ 23e0e8e` in an evidence header
should read it as "the pre-rewrite commit of that name", and can resolve it with the table above or
the backup below.

## The backup

The pre-rewrite history is preserved in two places, neither of which is published:

- `refs/original/refs/heads/master` inside this repository, written by `git filter-branch`.
- `~/projects/XCodeVault-pre-rewrite-2026-09-17.bundle`, outside the repository.

Both can be deleted once the first push has happened and the result looks right. Until then, the
rewrite is reversible:

```bash
git reset --hard refs/original/refs/heads/master
```
