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

## Corollaries

- **`exit != 0` is not "the test caught it".** One mutant in this sequence did not compile, and the
  non-zero exit was read as a catch. Count assertion failures and compile errors separately; a
  broken experiment is not evidence.
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

