# What a clean mutation actually tells you

Written 2026-09-14, after a review sequence in which three separate mutation runs came back green
and each time the correct conclusion was the opposite of the obvious one. The rule the project had
been working to — *mutate what you write; a guard that survives its own deletion is decoration* — is
right and stays. These are the ways it misleads.

## A clean mutation means "no test covers this difference" at least as often as "the code is equivalent"

The instinct on a green mutation run is that the mutated line does not matter. Usually it means the
tests do not distinguish the two behaviours, which is a statement about the tests.

Three instances, in order of how long each took to notice:

1. **Two guards mutated clean because they had no test at all.** A vault re-confirmation and a
   PLAN-line requirement were added to `resume`, and both survived deletion. Nothing covered either.
   Written, mutated, tests added, re-mutated: 4 and 1 assertions.
2. **A mutation that landed in a branch which independently accepts.** Routing `.restore` into the
   legacy `.none` arm of `abortDisposition` looked like it reproduced the restore regression. It did
   not: `.none` accepts `atOwnHome`, which is the same answer `.restore` gives, so the mutant was
   behaviourally identical on every input the tests use. The mutation has to reproduce *the defect*,
   not merely edit the line the defect was on.
3. **A mutation over a rule that is duplicated, with no test on a row where the copies disagree.**
   Reverting `forget` to re-derive "abort cannot act" instead of consuming `abortDisposition` passed,
   because every existing test sat on a row where both derivations return the same answer. Factoring
   was, to the test suite, indistinguishable from not factoring.

## `swift test` is not a mutation oracle in this repository

2026-09-18. A reviewer's entire first mutation pass had to be thrown out, and the tell was a
result that could not be true: `testOwnershipDecisionTruthTable`, a pure function over three
`Bool`/`uid_t` rows, failed three of them, and `mountStatus` on a nonexistent path returned
`.isNotMountPoint`, which the source cannot produce.

Measured on this machine (11 GiB free, 98% full): with a rebuild in flight, an **unmutated**
`swift test --filter HelperPrivilegedVerbTests` failed 2 runs in 5. Split into
`swift build --build-tests` followed by `swift test --skip-build`, it failed 0 in 22, and 0 in a
separate 6-run check.

So the protocol for every mutation in this repository is two commands, not one:

```
swift build --build-tests || echo "compile error — NOT a test kill"
swift test --skip-build --filter <suite>
```

The first line matters on its own: a mutant that does not compile is not a caught mutant, and the
split makes that unmissable instead of hiding it inside one exit code.

The wider point is that an impossible result is data. A pure function failing its own truth table
is not a finding about the code; it is a finding about the instrument. The reviewer noticed and
re-ran; the same run on a busier disk with a less suspicious reader produces a confident, wrong
report about a security guard.

## Verify the restore, not just the mutation

2026-09-18, the same afternoon as the note above, and a different failure of the same instrument.

A batch of four mutations ran as a shell loop: apply, test, restore from a copy taken at the
start. The second mutation's `python3 -c` hit a quoting error and raised, the loop kept going
without restoring, and the *next* iteration took its "gold" copy from the already-mutated tree.
Every restore after that restored the mutation. The run then reported a later mutation as KILLED
when the anchor had not even applied — the suite was red because of the leaked edit, and a red
suite reads identically to a caught mutant.

It surfaced only because the full gate run afterwards failed a test that had passed minutes
earlier. Nothing in the mutation harness itself noticed.

Two rules follow, and they cost one command each:

- **Prove the gold copy is clean before using it as a restore point.** Build and run the suite
  against it once, and require zero failures. A gold copy taken from a dirty tree poisons every
  result after it.
- **Verify the restore after every mutation, not at the end.** Re-run the suite on the restored
  tree and require zero failures before applying the next one. Then "KILLED" means the mutation
  did it, because the tree was provably green a moment earlier.

The general form: a mutation result is a *difference* between two states, and it is only evidence
if both states are known. This project's harness kept measuring the mutated state carefully and
assuming the clean one.

## Corollaries

- **`exit != 0` is not "the test caught it".** One mutant in this sequence did not compile, and the
  non-zero exit was read as a catch. Count assertion failures and compile errors separately; a
  broken experiment is not evidence.
- **An assertion failure is not a test failure either.** 2026-09-18: a helper change reported "four
  named tests each" for two mutations that had actually failed *one* test apiece, with four and six
  assertions inside it. The grep counted lines matching `' failed`, which picks up per-assertion
  `error:` lines and the suite footers. A reviewer re-measured and corrected it. The number that
  means something is distinct `Test Case '-[…]' failed` lines:
  `grep -oE "Test Case '-\[[^]]*\]' failed" log | sort -u | wc -l`. Note this was written *after*
  the corollary above, by someone who had read it and checked for exactly that failure mode — the
  measurement was wrong in a different place than the one being watched.
- **The rows worth mutating are where two code paths are supposed to agree.** That is where a
  duplicated rule hides, and a duplicated rule is what produces two functions that both refuse the
  same input, or one that accepts what the other would have handled.
- **Reading beats mutating for finding duplication.** In both cases here the duplication was visible
  in the source before any mutant was built — an `isExternalize` re-derivation sitting next to a
  `switch`, and later the same `guard let planned` in two functions. Ask "where is this decided
  twice?" first; it is cheaper.
- **Say when a branch is unpinned.** `abortDisposition`'s mount-point refusal survives its own
  removal because the fixtures cannot make a temp directory into a mount point. That is recorded in
  a comment at the branch rather than left for the next person's mutation run to rediscover.

## What did not change

Mutation is still the thing that caught a rule shipped with no test behind it, twice. The discipline
is not weaker for having these failure modes — it is that a green run is a question, not an answer.

## Pick the mutation subject so the check has to work

A deletion rule was tested by mutating the one file that already carried an exemption marker. The
comparison succeeded — by accident, because the exemption path was the path being exercised. The
shell defect that made the rule inert in every other file surfaced only when a different person
mutated a different file.

The rule this gives: **a mutation planted in the file you had in mind when you wrote the check is
the weakest possible test of it.** Plant it somewhere you were not thinking about. If the check has
per-file exemptions, mutate a file without one.

This is the same family as "a rule that is duplicated, with no test on a row where the copies
disagree", recorded above — both are cases where the sample chosen cannot falsify the claim.


## Five passes on one function, each of which hardened the wrong thing

Rehoused from `STATUS.md` (2026-09-14 entry) under issue #22, because it was the only surviving copy
of the sequence. The *residuals* of this work are in `KNOWN-ISSUES-AT-PUBLICATION.md` and the *why*
is in `MigrationEngine.swift`'s comments; what existed nowhere else is the shape of the failure —
that it took five review passes, and how each one was wrong.

The change: `resume` recovered its `categoryID` by splitting the journal's free-text `summary` on
spaces, with `?? "archives"` when that failed, and spent the result on deletion decisions. The
category, the vault volume and the direction are all fields on the PLAN line now, read as fields.

| pass | what the author thought had been done | what was true |
|---|---|---|
| 1 | removed the parser from a deletion path | removed it from the value that only *decides*; `aside`, which names the victim and reaches `removeItem`, was still read from the journal |
| 2 | added the vault and PLAN-line guards | both survived their own deletion — guards with no test |
| 3 | hardened `resume` | the same hole lived in `abort`, and `forget` (the author's own escape hatch) orphaned partial copies |
| 4 | made `abort` check the vault | broke every *restore*, whose partial copy is at the canonical home path by construction — and the refusal message said it was not this migration's copy when it was exactly that |
| 5 | factored the abort/forget rule into one function | the rule was factored for "a PLAN line exists" and re-derived for "it does not" — the same bug one level up, introduced by the pass that fixed it |

**The pattern, which is why this is here and not only in the changelog.** Every pass but the last
produced a fix that was *correct about the thing it named* and wrong about the thing it implied. The
recurring error is not carelessness; it is that a fix's scope is read from where the author was
looking rather than from where the value flows. Pass 1 fixed the decision and missed the deletion.
Pass 3 fixed one verb and missed its two siblings. Pass 5 factored a rule and then re-derived it
fifteen lines later for the other branch.

Three things that would have shortened it, worth trying before declaring a guard done:

- **Follow the value, not the function.** Ask where the parsed thing ends up, not which function
  parses it. Pass 1's miss was one `grep` away.
- **Enumerate the siblings.** `resume`, `abort` and `forget` all act on the same journal entry;
  fixing one and not asking about the other two is what pass 3 did.
- **Delete the guard and run the suite.** Passes 2's guards both survived their own deletion, which
  is the whole subject of this document: a guard nothing turns red for is not yet a guard.

Two data-loss paths were real and are closed. A line appended to the journal setting `aside` to the
destination would have had `resume` delete the vault copy, because a tree verifies as identical
against itself. And `abort` — the command the tool *tells* the user to run — deleted local data in
the ordinary disconnect case: crash during COPY, reboot, the volume loses the mount race, a plain
directory sits at the mount point, `lstat` succeeds, and the mount-point check does not fire because
the *volume* would be the mount point while the destination is several levels below it.

`migration forget --i-verified-both-copies-myself` exists because refusing is not free: a refused
`resume` left the operation `started`, which blocks every future migration, while `abort` refused
too. The pair is governed by one sentence — *`forget` declines anything `abort` can still clean up* —
and, since pass five, by one function. That termination bound has since been re-broken twice by
later changes and caught both times by the tests that pin it, most recently under issue #25; see
`MountAnswerTests.testAbortRefusesTheDeletionWhenTheMountQuestionCannotBeAnswered`.

## An inversion is not a deletion, and recording one as the other overstates coverage

On 2026-09-21, reviewing a new guard in `xcv_stage_write_evidence`:

```bash
[ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; ..." >&3; return 1; }
```

The mutation applied was `[ -n ... ] ||` → `false ||`, and the suite went to five failures. That
was recorded as "the guard is pinned by five checks." A reviewer re-ran the mutation the guard
actually invites — **deleting the line** — and got **zero** failures.

The two are not the same experiment. `false ||` makes the function *always* refuse, so it breaks
the five checks on the success path; it measures whether the success path is covered, which was
never in question. Deleting the line asks the only question that matters — does anything notice
when the guard is gone — and the answer was no, because without it `grep -cF ""` matches every
line and the write is refused anyway. Identical return code, identical absence of a file; the only
observable difference is the *reason* printed on fd 3, and no check read fd 3 on that path.

Two rules follow.

**Mutate by deletion first.** A guard's failure mode is that it is removed or never reached, not
that it fires unconditionally. Substituting an always-fail condition inverts the polarity of the
experiment and reliably produces a high, meaningless kill count — the more central the guard, the
more success-path checks it breaks, and the more convincing the wrong number looks.

**When two branches agree on their observable outcome, the assertion has to reach the thing that
differs.** Here that is the message, so the check now captures fd 3 and asserts the cause. A guard
whose whole value is message accuracy cannot be pinned by a return code.

This is the fifth measurement error in this file's history and the first of this species; the
other four were miscounting failures, running against a stale build, filtering on a file name
instead of a class name, and a contaminated gold copy. The pattern across all five is the same:
the number was produced by a procedure nobody re-derived, and it flattered the change.

A second claim in the same round failed the same way for a different reason. `mv "$tmp" "$out"`
was changed to `cp` and judged "behaviourally equivalent" from reading the code. Measured against
a deliberately filled volume, `cp` failed and left 8 MB of a truncated file at the destination —
destroying what was there — while `mv` failed and left the destination unlinked. The judgement was
reasoning where an eight-line experiment was available.
