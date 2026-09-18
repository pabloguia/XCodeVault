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

- **Path-based cleanup verb.** `removeRegenerableSystemDirectoryContents` validates the final path
  component's owner but not the intermediate components, and not the target's mode. A root-owned but
  group- or world-writable target would let an unprivileged user plant entries that root then walks
  and deletes. Not exploitable on a stock machine — the whole `/Library/Developer/CoreSimulator`
  chain is `root:wheel 0755` — so the safety property is currently inherited from the environment
  rather than enforced. The fix is an `openat` walk with `O_NOFOLLOW` per component.
- **`isMountPoint` fails open in that same verb.** It returns `false` both for "not a mount point"
  and for "the attribute could not be read", and the cleanup path reads that as permission to
  proceed. The same helper is used fail-*closed* elsewhere in the file.
- **`removeStrandedRuntimeDownload` cannot tell stranded from in-flight.** It has no notion of
  "stranded" at all, so a caller can delete a multi-gigabyte runtime image that Xcode is downloading
  right now. Its benefit is also unproven: this project's own research records that macOS 26.5
  refuses the unlink even for `sudo`. A verb with no demonstrated benefit does not belong in a root
  daemon; deleting it is the likely resolution.
- **The volume-UUID lookup parses an attribute it never confirmed was returned.** `getattrlist` is
  called without `ATTR_CMN_RETURNED_ATTRS`, so a filesystem that succeeds without supplying
  `ATTR_VOL_UUID` would yield the all-zero UUID, which is a valid `UUID` and would act as a
  wildcard. Probed on apfs, msdos, devfs and autofs, all of which either return a real UUID or fail;
  smbfs, nfs, webdav and FUSE are untested.
- **No audit log.** A root daemon that deletes files and changes ownership records nothing, so an
  incident has nothing to reconstruct from.
- **A narrow race in `createVaultDirectory`.** Between `mkdir` succeeding and `open` returning, a
  writer on that volume can rename a different directory into the path. The create branch now also
  requires the directory to be root-owned, which closes the demonstrated case; the caller must
  already be an administrator either way.

## `scripts/helper-invariants.sh`

The checker has been mutation-tested by a reviewer three times and defeated every time. The current
round left thirteen known bypasses. Its header states its ceiling, and the important thing is that
**nothing in the project may cite it as evidence that a change is safe** — the helper-security
review is the control. Specific gaps worth closing, in rough order of value:

- It does not read `Package.swift`, so it cannot see the helper target gaining a dependency, and the
  "only two dependents" property is held by human review alone.
- Function bodies are extracted by a fixed-indent terminator rather than brace balance, so a
  one-line body runs into the next function and can borrow its `authorize()`.
- The helper directory list is hardcoded; a new target added to the helper's dependency closure is
  invisible.
- Comment stripping is line-based and quote-aware only crudely.
- It cannot detect semantic neutering — `_ = authorize()`, or an `authorize()` rewritten to return
  nil — and no text matcher can.

## Migration engine

The abort/forget pair terminates under every obstacle a reviewer could produce on this machine —
`deny delete` ACLs, `uchg`, read-only parents, an obstacle that only appears on the second attempt —
because the redirect is bounded by counting `ABORT_FAILED` entries rather than by predicting whether
a removal will succeed. Two residuals were found in the same review and left:

- **"I cannot see it" is reported as "it is gone."** `abort`, `forget` and `leftoverPartialCopies`
  all treat a failing `lstat` on the partial copy as absence. `EACCES` — from a parent with no search
  permission, or an ACL denying `search,list,readattr` — and `EIO` from a failing enclosure both
  produce that, and the operation is then journaled as "no partial copy present, source intact"
  while the copy is still on the drive. Nothing is deleted on this path and the source is untouched;
  what is wrong is the claim. The fix is to keep `errno` and treat only `ENOENT` as absence.
- **An entry closed after two failed aborts survives only as a journal summary.** `doctor` and
  `migration status` read `leftoverPartialCopies`, which is driven by open entries, so once
  `forget --i-verified-both-copies-myself` closes one the partial copy is no longer named anywhere
  but the journal line that records it. That is the intended escape hatch — it exists for a copy the
  machine cannot remove — but the trade is real and worth stating: the user is the one who has to
  remember.
- **If the journal itself cannot be written, every verb errors and nothing closes.** `abort` records
  its failure before rethrowing, so an unwritable journal replaces the removal error with a write
  error and the failure count never advances. Not reproduced; noted because the failure mode is loud
  rather than silent, which is the property that makes it acceptable to leave.

## Compatibility

Every claim in `docs/architecture/COMPATIBILITY_MATRIX.md` was measured on one Mac, one
architecture, two macOS builds of one major version, one Xcode and one external volume. Several
findings are `probable` rather than `verified` for that reason alone. This is the gap publication
exists to close; see `CONTRIBUTING.md`.

## Documentation

- `docs/process/SESSION-HANDOFF.md` and the `PROMPT-*.md` files are in Portuguese while the rest of
  the repository is in English. For an outside reader that is noise.
- `docs/process/PROMPT-PUBLICATION-PREP.md` is a completed session brief whose inventory had five
  errors, corrected in ADR-0005. It carries a header saying so and can be deleted without loss.
