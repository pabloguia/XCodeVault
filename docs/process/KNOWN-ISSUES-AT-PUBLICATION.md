# Known issues at publication, 2026-09-17

Everything here was found by an independent review before the first push, judged non-blocking, and
deliberately left. It is written down so it becomes public issues rather than knowledge that existed
only in one conversation. Each entry says who found it and what makes it non-blocking *today*,
because several of them stop being non-blocking the moment something else changes.

The blocking findings from the same reviews were fixed; see `STATUS.md` for that pass.

## Privileged helper

Nothing here is reachable by a client. No shipped artifact contains the helper — `bundle-app.sh`
gates the binary and the LaunchDaemon plist behind `--with-helper`, off by default — and no code in
the tree opens a connection to it. **Every item below becomes live the moment that flag is used in a
release**, which is why the same list is repeated beside the flag in `scripts/bundle-app.sh`.

- ~~**Path-based cleanup verb.**~~ **Fixed 2026-09-18** (issue #1). The verb now walks every
  component from `/` with `openat` + `O_NOFOLLOW`, checking owner *and* mode at each level, and —
  the part that took two review rounds to get right — acts **through the returned descriptor**
  (`fstatat`/`openat`/`unlinkat`) instead of rebuilding the path. The first attempt did the walk
  and then re-resolved the string for every operation, which made the guard decorative; both
  reviewers caught it independently. The recursion also refuses to cross a device boundary, which
  `FileManager.removeItem` (`removefile(3)` with `REMOVEFILE_RECURSIVE`) did not.
- ~~**`isMountPoint` fails open in that same verb.**~~ **Fixed 2026-09-18** (issue #2). The query
  is three-valued (`MountAnswer`), is asked of the **descriptor** rather than the name, and the
  verb refuses on `.undetermined`. `isMountPoint` survives for the byte accounting, where the
  collapse is not a safety decision; its doc comment now names both callers and says why the
  remaining guard use is safe.

  Both of the above are now pinned *at the call site*, not only in the primitives. The mutations
  that restore each defect verbatim — replacing the mount switch with `_ = mount(fd)`, and the
  guarded walk with a bare `open` — previously passed the whole suite and now each fail **one
  named test** (`testTheVerbRefusesOnBothNonAnswersFromTheMountQuery`, 6 assertions;
  `testTheVerbRefusesWhenAComponentOfTheChainIsGroupWritable`, 2 assertions). An earlier draft of
  this paragraph said "four named tests each"; that was assertion-failure lines counted as test
  failures — the measurement error `MUTATION-TESTING-NOTES.md` exists to prevent, made in the very
  document meant to be checkable. Corrected by counting distinct `Test Case … failed` lines.

  Seven guards inside the new code remain unpinned. Each says so **at the branch**, with the
  reason: the two `st_dev` checks (one on a child's name, one on the opened descriptor — the
  second needs a mount to appear between the `fstatat` and the `openat`), the `failures += 1` on
  an unstattable child (needs a `readdir`/`fstatat` race), the `readdir` `errno` check (needs a
  real I/O error mid-enumeration), `O_NOFOLLOW` on the recursive child open (survives only
  because the `S_IFLNK` check catches the symlink first — redundant-looking and load-bearing),
  the `AT_REMOVEDIR` failure branch (near-unreachable, since a surviving child already reported),
  and the production gate on the injected mount query (its whole point is the `base == "/"`
  branch, which no test can enter without walking the real system path).

  An earlier draft of this paragraph said two. A reviewer enumerated nine surviving mutations and
  showed that **two of them needed no root, no volume and no race** — `chmod 000` on a
  subdirectory and `chflags uchg` on a file. Those two are now tested, along with the depth
  limit, the trust-anchor containment check and the root-anchor owner refusal. The lesson is the
  one this change is about: "unpinnable" is a claim that has to be checked per guard, not a
  category applied to whatever is left over.
- ~~**The volume-UUID lookup parses an attribute it never confirmed was returned.**~~ **Fixed
  2026-09-19** (issue #3). The request now carries `ATTR_CMN_RETURNED_ATTRS`, and the reply's
  returned-attribute bitmap is checked for `ATTR_VOL_UUID` before any byte of it is read; the reply
  length is validated at both the set and the UUID offset. Independently, the all-zero UUID is
  rejected on both sides — never produced from a reply, and refused at `mountPoint(forVolumeUUID:)`
  before any filesystem is examined, so it cannot act as a wildcard by any route. The parse is
  cross-checked against Core's independent reader on the boot volume, and every filesystem mounted
  on the test machine is asserted never to yield the all-zero value. smbfs, nfs, webdav and FUSE
  remain untested, because none is mounted here.
- ~~**No audit log.**~~ **Fixed 2026-09-19** (issue #4). Every verb invocation is recorded to the
  unified log through `HelperAudit` — caller uid, verb, validated arguments, the authorization
  outcome and the result — at `.notice`, which persists, rather than `.info`, which does not
  survive a reboot. Emitted at the XPC dispatch, which is the only place every invocation passes
  through and which keeps test invocations out of the machine's real log. Redaction uses `os_log`'s
  own privacy qualifiers rather than `Redaction.swift`: that type is built from `[Volume]` and
  lives in Core, and importing Core into the root daemon to save an enum is the wrong trade.
  Caller-supplied arguments are `.private(mask: .hash)`, so they stay correlatable across entries
  without being disclosed. `scripts/helper-invariants.sh` now requires one `emit` per state-changing
  verb and forbids the memory-backed levels.
- ~~**A narrow race in `createVaultDirectory`.**~~ **Fixed 2026-09-19** (issue #5). The verb no
  longer touches the path after resolving it: it opens the volume root `O_NOFOLLOW|O_DIRECTORY` and
  does `fstatat`/`mkdirat`/`openat` relative to that descriptor, so the parent cannot be swapped
  underneath it. POSIX offers no create-and-open for directories, so the remaining window between
  `mkdirat` and `openat` is closed by verification rather than exclusion: `fstat` on the descriptor
  — never `stat` on the path — must report the same `st_dev` as the parent, and for the just-created
  branch `st_nlink == 2` (an empty directory is `.` plus its parent's entry) and `st_uid == 0`.
  **Stated as a verification, not an exclusion:** an attacker who can place an empty root-owned
  directory on that volume defeats it, and doing so requires root.

## `scripts/helper-invariants.sh`

The gaps the pre-publication review listed "in rough order of value" are closed as of 2026-09-19
(issue #7), except the one that cannot be:

- ~~It does not read `Package.swift`~~ — it does now. It parses the target graph and fails when any
  target outside the permitted two depends on `XCodeVaultHelperCore`, and when a helper target
  gains a dependency outside its allowlist. Mutation-tested three ways: the app taking a dependency
  on `HelperCore`, `HelperCore` taking an external product, and the bootstrap taking Core. All three
  turn it red.
- ~~Function bodies are extracted by a fixed-indent terminator~~ — replaced with brace balancing.
  The defect was demonstrated rather than reasoned about: with the old terminator, a one-line body
  followed by a function containing `authorize()` extracted **1** match; with brace balance it
  extracts **0**, which is the truth.
- ~~The helper directory list is hardcoded~~ — derived from the manifest parse, so a new target in
  the helper's closure is scanned rather than invisible.
- Comment stripping is still line-based and only crudely quote-aware. Unchanged.
- **It cannot detect semantic neutering, and no text matcher can.** `_ = authorize()`, or an
  `authorize()` rewritten to `return nil`, leaves every rule green while every gate is dead. This is
  why the project rule stands: **nothing may cite this script as evidence that a change is safe.**
  The helper-security review is the control, and it is mandatory for every change to these files.

A fourth round of mutation testing (2026-09-19) is worth recording because the defeat came from a
*widening made in good faith*: teaching the dispatch matcher the shape the audit trail required made
it match any self-call, and a decoy function then satisfied both the gate rule and the audit rule for
a verb that had neither — **exit 0, "helper invariants: ok"**, on a root verb that was ungated and
unlogged. Both rules now key off the XPC protocol's own verb list, which a decoy cannot join.

## Migration engine

The abort/forget pair terminates under every obstacle produced on this machine so far — `deny
delete` ACLs, `uchg`, read-only parents, a parent with no search permission at all (`0o000`), an
obstacle that only appears on the second attempt — because the redirect is bounded by counting
`ABORT_FAILED` entries rather than by predicting whether a removal will succeed.

**The condition that claim rests on, stated because a fix briefly broke it.** The bound advances
only if `abort` reaches its `ABORT_FAILED` record. A 2026-09-18 change made `abort` refuse *before*
that record when it could not stat the destination, and since `forget`'s `.cleanable` case has no
non-throwing exit, both verbs then refused forever — and with a `started` entry, `refuseIfInterrupted`
blocked every future migration. A reviewer found it; the fix is that `abort` attempts the removal
whenever the copy *may* be present and lets the failure be recorded, rather than declining to try.
Anything that returns early from `abort` before that record breaks termination, and the note at the
guard says so. The bound still depends on a writable journal (issue #10).

Three residuals were found in the original review:

- ~~**"I cannot see it" is reported as "it is gone."**~~ **Fixed 2026-09-18** (issue #8). The four
  sites that asked this question now share one helper, `MigrationEngine.presence(of:)`, returning
  three answers instead of two: only `ENOENT` and `ENOTDIR` are absence, everything else is
  `undetermined`. `leftoverPartialCopies` keeps an entry it could not stat rather than dropping it
  — the copy most worth surfacing is the one that could not be checked — and `abort` refuses
  outright instead of journaling "no partial copy present, source intact" over a path it never
  read. This is the same defect as the helper's `isMountPoint` (#2): a question with three answers
  written with two, where the missing one silently took the value of the safe-sounding one.
- ~~**An entry closed after two failed aborts survives only as a journal summary.**~~
  **Fixed 2026-09-18** (issue #9). `forget` now marks the record it writes when a copy remains, and
  `MigrationEngine.knownLeftoversAfterForget()` reads it back. `doctor` reports it as an
  informational finding — not a fault, because closing the entry was deliberate and correct — and
  `migration status` prints a `KNOWN LEFTOVER` line. Both suppress it once the path is definitely
  gone, using the same `.absent` answer above, so a copy the user removed by hand stops being
  mentioned. The escape hatch still works exactly as designed; it is no longer also the place the
  reminder disappears.
- ~~**If the journal itself cannot be written, every verb errors and nothing closes.**~~
  **Partly fixed 2026-09-18** (issue #10). The failure record in `abort` no longer steals the
  story: a journal-write failure is caught, and the error the user sees names the real obstacle
  (the removal) *and* says the attempt was not counted, so the retry that would let `forget` close
  the entry will not become available until the journal is writable. What is **not** fixed is the
  underlying coupling — the termination bound still counts `ABORT_FAILED` entries in the same
  journal whose unwritability is the problem. Making the count independent of that journal is the
  remaining work, and the engine's comments scope the termination claim to a writable journal
  rather than stating it unconditionally.

## Compatibility

Every claim in `docs/architecture/COMPATIBILITY_MATRIX.md` was measured on one Mac, one
architecture, two macOS builds of one major version, one Xcode and one external volume. Several
findings are `probable` rather than `verified` for that reason alone. This is the gap publication
exists to close; see `CONTRIBUTING.md`.

## Documentation

- The tail of `STATUS.md` is still in Portuguese. `SESSION-HANDOFF.md` was translated in the
  2026-09-18 review because both entry points route a cold start to it; `STATUS.md` was classified
  line by line in the same review but not restructured, because four of its ranges are the only
  surviving copy of a lesson and rehousing them is a separate piece of work. See
  `REVIEW-2026-09-17.md` §G12 for the line ranges and their named destinations.

## Found by the 2026-09-18 pre-publication review and left

Each of these is real, has a written remedy in `REVIEW-2026-09-17.md`, and was judged to cost more
than it returns before a first public commit. They are here so they become issues rather than
knowledge that existed in one conversation.

### Testability of the privileged verbs

**Largely resolved 2026-09-18** (issue #6). `removeRegenerableSystemDirectoryContents` is now
internal and called by tests through a `under:` seam that injects the *trust anchor* only — the
target is still chosen from `HelperCleanupTarget` and the required owner is derived from whoever
owns the anchor, so a test owns its own tree while production keeps demanding root. An earlier
draft injected `requiredOwner` instead; both reviewers pointed out that an owner knob on a root
deletion verb is a way to ask root to delete somebody else's tree, and that a default argument is
not a defence against a future in-module caller.

This section previously made a falsifiable prediction: that replacing `doCreateVaultDirectory`'s
`(created && st_uid == 0) || st_uid == callerUID` guard with `true` would fail no test. It was
correct, and it now fails five rows of a truth table. **What it did not predict is the more
interesting half** — extracting and testing the guard did not pin the *call site*, and the first
attempt at this change left all three call sites mutation-clean while looking thoroughly tested.

**Narrowed 2026-09-19.** Issue #5 closed and did rework the verb onto `openat`/`mkdirat` against a
parent descriptor, so that half of the sentence above is no longer outstanding.
`VaultDirectoryVerbTests` now calls `doCreateVaultDirectory` itself and pins the four refusals that
precede the mount lookup — the authorization gate at its call site among them, which removing the
`authorize()` line demonstrably fails (the invariants script catches it too, independently).

**Narrowed 2026-09-19** (issue #28) — "closed" was the first wording and a reviewer corrected it,
since the privileged success arm is still exercised only by the E-series runbooks. The region below the mount lookup moved into
`HelperService.claimDirectory`, which takes the **parent descriptor** the verb has already verified
rather than a path — so a test opens a directory it owns and drives the create/adopt branches, the
`isTheObjectThisCallJustCreated` switch, the `mayTakeOwnership` decision and the `fchown`. A
descriptor is strictly narrower than a path as a seam: an in-module caller must already hold an open
directory to pass one, and nothing on the XPC wire can supply one. No owner is injected — the uid
granted is still the service's own `callerUID`, which is what both reviewers required when they
rejected the `requiredOwner` knob.

Demonstrated rather than asserted, and the numbers were re-measured by a reviewer rather than taken
on trust: ignoring `mayTakeOwnership` at its call site fails one assertion, ignoring
`isTheObjectThisCallJustCreated` fails four, dropping `AT_SYMLINK_NOFOLLOW` fails one, deleting the
`fchown` fails two, and removing the name validation fails eight.

That last one is a defect the extraction introduced and the review caught: `name` reaches
`mkdirat`/`openat` directly, so `"../OUTSIDE"` created — and `"../VICTIM"` chowned — a directory
outside the anchor subtree. The byte check lived in the caller under a comment saying containment
"is a property this function is responsible for", and moving the syscalls out of that function left
the property in one place and its enforcement in another. It is now checked in both.

One arm stays out of reach and is asserted as its refusal instead: a directory *created by this
call* must be root-owned, which it never is unprivileged. A skip would have been the other option
and is not available — CI asserts a baseline of zero skipped tests, so a test that skips on every
ordinary machine fails that gate rather than documenting the gap. The E-series runbooks are where
that arm runs.

### Structural findings with named seams

- ~~`Doctor.swift` (1,025 lines) has a real two-reasons-to-change seam at lines 471-941~~ —
  **split 2026-09-19** (issue #11). The five CoreSimulator rules are now
  `Doctor/Doctor+CoreSimulator.swift`, following the shape `Doctor+Vault.swift` established;
  `Doctor.swift` is 573 lines. `checkPerDeviceRegenerables` is arguably also Apple-versioned and was
  deliberately left behind: moving it would have made the split something other than the boundary
  the issue stated in advance, and a structural move is only verifiable against a stated boundary.
- ~~`MigrationEngine.swift` (839 lines) has one at 660-839~~ — **split 2026-09-19** (issue #12) into
  `Migration/MigrationJournalForensics.swift`; the engine is 901 lines.

  **The boundary moved, and that is the finding worth keeping.** The issue described a contiguous
  tail in an 839-line file. The file had grown to 1,094 lines and `abort` — which calls `removeItem`
  — now sits *between* `abortDisposition` and the two read-only journal queries at the end. Taking
  the contiguous range would have carried a deletion path into a file named for forensics, which is
  the opposite of the property the split exists to create. What moved is the set the issue's
  *description* names: reads only `[JournalEntry]`, migrates nothing.

  Both splits were proved behaviour-preserving by the method `REVIEW-2026-09-17.md` §S2 prescribes —
  the test-name list captured before and after and diffed to empty (363 either side), the suite
  re-run, and every moved function byte-identical to its previous text.
- ~~Four injection seams are missing, each blocking a specific test.~~ **Five mount-point guards
  were unpinned; all five fixed 2026-09-18** (issue #13) — and **not by adding seams**, which is
  the useful part.

  The issue named three of them. A reviewer found two more of the same shape while checking the
  fix — `MigrationEngine.preflightSource` (the *source* side of the rule the change had just
  pinned on the destination side) and `CleanPlanner`'s skip of a scanned mount point, which
  needed neither root nor the `/` trick because `isMountPoint` is a plain `Bool` on
  `StorageItem`. A third, `Doctor+Vault`'s shadow-data *detection*, remains unpinned: it needs a
  path that exists under a `/Volumes/<name>` which is not a mount point, the same root-only
  staging as below. It also duplicates the `/Volumes/<name>` parse that
  `XcodeLocations.shadowDataRefusal` now owns, which is the "decided twice" shape
  `MUTATION-TESTING-NOTES.md` warns about.

  The first attempt added `isMountPoint` seams to `MigrationEngine.abortDisposition` and
  `CleanExecutor.preflight`, and both an `isMountPoint` and a `resolve` seam to
  `XcodeLocations.preflightLocation`. A review showed the first two had only moved the untested
  mutation: flipping the *production call site* to `{ _ in false }` disabled the mount-point
  refusal on the deletion path with the whole suite green — the guard covered, the line feeding
  it not, one line further from the guard where it reads as plumbing. It is the same shape as an
  owner knob removed from the privileged helper for the same reason. The `resolve` seam was
  worse: public API on the *archives* entry point (the non-regenerable category, while
  `preflightDerivedData` did not carry it), and not a relocation of the question but an off
  switch, since a resolver that never returns a `/Volumes/` prefix makes the branch not run.

  All three seams are gone. `/` is a real mount point, exists and is not a symlink, so the two
  mount rules are reachable with the real `MountStatus`; the shadow-data rule was extracted as
  `XcodeLocations.shadowDataRefusal(resolved:isMountPoint:)` and is tested on a literal, so the
  real `canonicalize`-then-`realpath` still runs in production. Removing any of the three guards
  now fails a named test, and `scripts/helper-invariants.sh` refuses a production caller that
  supplies a mount answer to `shadowDataRefusal` — the one seam parameter left in the tree —
  positive-controlled against a closure literal, a named function reference and a space before
  the colon, the last two of which defeated the rule's first version. The rule is scoped to
  named seam-bearing functions rather than to the identifier, because `isMountPoint` is also a
  plain `Bool` on `ScanItem`; a broad rule flagged that too. Adding a new seam parameter means
  adding it to that list by hand, which is the intent.

  A second rule requires `preflightLocation` to *call* `shadowDataRefusal`. That is this
  script's own round-one lesson — it once required the authorization gate's symbol rather than
  its call sites, so deleting all three calls left CI green — and it is what closes the gap
  below as far as a control can.

  **Still unpinned, and labelled at the line:** the *call* to `shadowDataRefusal` from
  `preflightLocation`. Deleting it fails no test, because reaching the refusal through the
  production path needs a real directory under a `/Volumes/<name>` that is not a mount point,
  and staging one needs root. Extracting the rule moved the untestable part from the whole guard
  down to one line. That is progress, not a fix, and the line says so.

  The fourth — the free-space guard — was never missing a seam. `Doctor.checkFreeSpace(host:)`
  takes a `HostEnvironment` by value, so there is no primitive to inject, and
  `testLowFreeSpaceSeverity` already pinned all three bands; mutating the 40 GB threshold fails
  it. The entry above was wrong about it, which is the second time a finding in this document has
  been inverted (see the note on issue #23).

  Two things worth keeping from the work. `XcodeLocations` needed a second seam — the existence
  check runs on the path the caller gave while the `/Volumes` rule runs on what it *resolves to*,
  so controlling only the mount answer left the branch unreachable from a temp directory. And the
  test that had covered that rule, `testRefusesPlainDirectoryUnderVolumes`, only ran when the
  machine happened to have a plain directory left under `/Volumes` by an unclean eject; it
  `XCTSkip`ped otherwise. A guard whose test skips on most machines has no test on most machines.
  That skip site is one of the ones issue #18 is about; it is now backed by a deterministic test
  rather than replaced by one.
- ~~The `runtime offload` transaction lives in an executable target no test can import.~~
  **Fixed 2026-09-18** (issue #14). The policy moved to `RuntimeOperations.preflightOffload` and
  `offload`, matching the shape `preflightExport`/`preflightImport`/`delete` already used, leaving
  `RuntimeCommands.swift` (then `M2Commands.swift`) as argument parsing and presentation. Three seams — `isMountPoint`,
  `listLibrary`, `imageIsReadable` — let the guards run without a real multi-gigabyte image, and
  all four are now pinned by mutation, along with both journal transitions and the failure path.

  Three things fell out of writing tests that could not have been written before. `offload` had
  an unreachable `guard result.succeeded` after its `do/catch`, because `delete` already throws on
  a non-zero exit — unreachable safety code that a later reader would have trusted. The `.failed`
  journal line now says the installer is untouched, which is the fact a user needs at the moment a
  12 GB deletion has just refused. And `offload` now re-validates the mount and the installer's
  readability before deleting: `OffloadPlan` is `Sendable` and all-`let`, built to be held across
  a confirmation sheet, and "was true at preflight" is not "is true now".

  **The first version of this entry claimed all four guards were pinned by mutation. That was
  false, and the way it was false is the point.** Every test injected `imageIsReadable:`, so the
  production closure — the only one that runs when the product runs — had no coverage at all: a
  reviewer replaced it with `{ _ in true }`, deleting the last check between a 12 GB deletion and
  a truncated `.dmg`, and the whole suite stayed green. Two more mutations survived by pointing
  that check at a *different* installer than the one about to be restored from, which is the same
  defect one guard to the left that this change had already fixed once. And because the fake
  runner recorded nothing, `--dry-run` and `--keep-asset` could both be appended to the deletion
  unnoticed — one reports a deletion that never happened, the other leaves the space it claimed to
  free. All five are now pinned, by a runner that records its invocations and by asserting *which*
  path was checked rather than how many were.

  Still deliberately not closed: the journal records the installer's path but no volume identity,
  so `doctor` cannot tell "the vault is unplugged" from "a different drive is mounted at
  `/Volumes/VAULT`". That is filed as its own issue rather than folded in here. There is also no
  fault injection for a crash mid-`delete`, which would leave the entry at `.started`.

### API surface

~~`XCodeVaultCore` ships as a `.library` product with a large public surface and no
`package`/`internal` discipline~~ — **the exposure is closed as of 2026-09-19** (issue #15). The
library *product* is gone; the three in-repo consumers (the CLI, the app, the test target) depend on
the **target**, which is unaffected, while nothing outside this repository can depend on any of it.
That is the part that made the surface a semver commitment, and removing it closes all of it. The
`package`/`internal` narrowing is now ordinary hygiene rather than a breaking change — narrowing a
surface nobody can reach breaks nobody — and it can proceed incrementally. 502 `public` declarations
remain; the earlier passes counted 551 and 422 by different methods, and the count was never the
point. Re-adding the product has a precondition written beside it in `Package.swift` and a test that
fails if it reappears.

~~`XcodeLocations.Change.key` is a free-form `String` written into
`defaults write com.apple.dt.Xcode`~~ — **fixed 2026-09-19** (issue #16). It is a closed
enumeration of the four keys this tool owns, so an unowned key cannot be *constructed* rather than
being rejected at write time. The enum's raw values are short display names and the defaults keys
come from a separate `switch`, deliberately: fusing them would make renaming a display name silently
rewrite a real Xcode preference key.

~~Each client composes the Doctor's two rule families by hand~~ — **fixed 2026-09-19** (issue #17).
`diagnoseAll` is the single entry point and a test fails when a family is declared under
`Sources/XCodeVaultCore/Doctor` and is not reachable from it.

### CI and the test suite

- ~~Six of the twenty `XCTSkip` sites cannot be ruled out on a GitHub runner~~ — **measured on the
  first CI run, 2026-09-18: zero tests skipped on either `macos-15` or `macos-26`.** All 275
  executed on both. So `chmod +a` works there, `hdiutil create`/`attach` works there, and the
  `/Volumes/<bootname>` symlink exists there; the three ACL tests, including the only pin on the
  abort/forget termination bound, do run in CI. The *residual* is that nothing enforces it: an
  environment change could start skipping tests and no gate would notice. CI should assert its
  environment supports what the skips need, and fail if the skip count exceeds a committed baseline
  of zero.

  **The residual is closed as of 2026-09-19** (issue #18), with two controls rather than one,
  because they fail differently. `scripts/ci-environment-assertions.sh` asserts the capabilities —
  `chmod +a` sets an ACL that sticks, `hdiutil create`/`attach` round-trips, `/Volumes/<boot volume>`
  is a symlink, and the suite is not running as root (which would *remove* eleven permission tests
  rather than fail them). `scripts/ci-assert-no-skips.sh` asserts the outcome: it parses the run's
  own summary and fails when anything was skipped, baseline zero. The capability list is something
  somebody maintains and will eventually be incomplete; the skip count is the property actually
  wanted. Both refuse to report ok on input they could not parse — "zero skips" and "I found no
  test summary" render identically if you only count, which is the instrument failure this
  repository has now made three times.
- `.github/workflows/ci.yml` pins `actions/checkout` and `actions/upload-artifact` by mutable tag
  rather than SHA. Given `permissions: contents: read`, no secrets, and no publishing step, this does
  not materially change the workflow's risk — but the calculus changes the day a release job is added.
- The workflow has still never executed. Publishing is what will run it for the first time.

### Evidence ledger

Three rows in `docs/architecture/COMPATIBILITY_MATRIX.md` warrant demotion on evidence grounds: a
`.verified` catalog status whose evidence (F22) has no matrix entry; a verdict claiming a formula
"generalizes" from n=2 on one machine where the adjacent row correctly scopes the same claim; and a
row whose evidence is "this session's transcript (no `.txt` evidence file written)" in a document
whose header calls it an evidence ledger. Evidence is append-only, so these are demotions only.

### Naming

~~`M2Commands.swift` and `M3Commands.swift` are named for a milestone scheme that appears nowhere in
`README.md`, `CONTRIBUTING.md`, `CLAUDE.md` or `AGENTS.md`~~ — **renamed 2026-09-19** (issue #21),
after the two structural splits it was waiting on, so the names landed on the final shape rather
than an intermediate one.

Renamed by content, following the convention `BenchCommand.swift` already established in the same
directory — one top-level command per file: `CleanCommand.swift`, `RuntimeCommands.swift`,
`LocationsCommands.swift`, `JournalCommand.swift`, `VaultCommands.swift`,
`MigrationCommands.swift`. That is a larger change than the rename the issue asked for, and the
reason is that no single accurate name exists for a file holding `clean`, `runtime` and `locations`:
naming it for all three is the filename admitting it is three files.

The sibling finding in the same issue — experiment IDs appearing in `--help` with no pointer to
where they are defined — was already fixed: `XCodeVaultCTL.swift`'s discussion text names
`docs/architecture/EXPERIMENTS.md`.

Historical references to the old names survive in `REVIEW-2026-09-17.md` and in `STATUS.md`'s dated
log, deliberately: those are records of what was true when they were written, and rewriting them
would be editing evidence.


## Experiment harness and evidence ledger — audited 2026-09-19 (issue #23)

The pre-publication review did not read 19 of the experiment scripts or 44 of the evidence files,
and named them as the first place a second pass should go. That pass has now run. What it checked
mechanically, and what it found:

**Clean.** Every one of the 19 scripts sources `common.sh` and uses its header/redaction helpers —
none writes evidence by hand. Across all 44 evidence files there is no occurrence of this machine's
home directory, its account name as a bare word, any mounted volume's name, or either mounted
volume's UUID. 39 of the 44 carry at least one redaction marker (`<user>`, `<vault>`,
`<vault-uuid>`, `<bootvolume>`, `~`). The five that carry none — `e13-dyld-reboot-*` (2),
`e1b-mount*` (2), `e4b-runtime-from-external-20260909T201158.txt` — were read: they contain only
root-scoped paths under `/Library/Developer` and system version strings, so there was nothing to
redact. An absent marker there is the redactor having nothing to do, not the redactor not running.

**Two findings, neither of them a redaction failure:**

- **`e15-ide-honours-device-set.sh` has produced no evidence file, ever.** It is the only script
  with a zero count, and the `run-experiment` skill classifies it as **destructive** — it
  `defaults write`s and `defaults delete`s `DVTSimulatorSetLocation`, a real key in the user's own
  `com.apple.dt.Xcode`. So the one script in the harness with no recorded run is also one of the
  six that can leave the user's Xcode pointing somewhere else if interrupted. Nothing in the
  product depends on E15, and `HYPOTHESES.md` does not cite it, so this is an untested tool rather
  than an unsupported claim — but it should be run and recorded, or deleted, rather than left as a
  destructive script nobody has exercised.

- **Four evidence files have no script that could have produced them:**
  `e4a-seal-survives-external-relocation-*`, `f11-export-installed-runtime-*`,
  `f12-export-artifact-shapes-*`, `f13-offload-import-device-return-*`. They were produced by hand.
  That is the same class as the E7 row demoted under issue #20 — an evidence ledger entry that
  cannot be re-run by anyone but the person who ran it. They are not wrong and nothing here
  proposes deleting them; what is missing is a script, and writing one is what would let a second
  machine confirm them.

**What this pass did not do.** It is a mechanical audit plus a read of the five unmarked files. It
did not re-derive each script's findings, and it cannot: most of them mutate a real environment.
It says the harness redacts what it claims to redact and that the ledger has no leak of this
machine's identity. It does not say the experiments' conclusions are right — that is what a second
machine is for (`CONTRIBUTING.md`).

The skill's destructive-experiment list, the other half of issue #23, was already corrected in
commit `6322ef0` ("Classify the experiment scripts by what they do, not by their number"), which
replaced the stale three-name list with the six-class table now in
`.claude/skills/run-experiment/SKILL.md` — and `e13b`, `e14b-device-set-external` and `e14c` are
all classified there. Both mirrored copies are byte-identical, checked by
`scripts/check-doc-mirror.sh`.
