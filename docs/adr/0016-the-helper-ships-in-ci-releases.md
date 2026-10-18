# ADR 0016: The privileged helper ships in CI releases, behind a version handshake and without the cleanup verb

- Status: accepted (2026-10-17); the live tests on a release candidate are pending (Consequences)
- Date: 2026-10-17
- Supersedes: ADR-0010's exclusion of the helper from CI releases (the rest of ADR-0010 stands).
- Related: ADR-0007 (permissions asked at need), ADR-0014 (`enableOwnership`), issue #30, H18.

## Context

v0.2.2 was signed and notarized by the Release workflow without the helper, because ADR-0010 kept it out until the
list in `scripts/bundle-app.sh` was closed. On 2026-10-17 the operator asked which items that list held, and accepted
the recommendation for each. Measured against the code that day:

- **The client sent three of four verbs without checking the daemon.** `HelperClient.send` went straight to the verb;
  only `enableOwnership` asked `version()` first. A client's code-signing requirement refuses the peer's *reply*, not
  the request (xpc/connection.h:790-793, measured 2026-09-28), so an older daemon still holding the Mach name would act
  on the verb before the client could refuse it.
- **Neither side had a minimum version.** The requirement language compares strings, and the CLI, a bare Mach-O, has
  no Info.plist to compare.
- **The cleanup verb has no in-use check of its own.** It deletes the CoreSimulator dyld and Cryptex caches whatever is
  running against them. The app refuses while Xcode, a simulator or the cache builder runs (`PrivilegedActionRunner`),
  which protects against accident; a client that passes the requirement and skips the app is not constrained.
- **The audit trail was not rate-limited.** A client that passes the requirement could loop a verb and push older
  records out of the persisted log.
- **The release pipeline refused the helper by construction:** `bundle-app.sh --with-helper` required `--sign`, which
  the build job cannot have; the artifact scan refused the helper and its plist; `ci-sign-notarize.sh` signed two
  binaries; the hygiene gate (HYG8) refused `--with-helper` in `release.yml`.

Two release follow-ups from the v0.2.2 run (38998916695) are fixed here too: `stapler validate` failed once on a
dropped CloudKit connection after notarization was accepted, and the log printed a `plutil` error as the submission ID.

## Decision

- **A version handshake on every connection, both ways.** A new verb, `begin(clientVersion:)`.
  - The client (`HelperClient.opening`), on the connection the verb will use, asks `version()` and refuses a daemon of
    any other version (an older one is `helperOutdated`, which the app reinstalls through the approval flow; a newer or
    unparsable one is `helperNewer`, never reinstalled). Then it sends `begin`, and only then the verb.
  - The daemon refuses `begin` unless the version is exactly its own, and refuses every other verb on a connection
    where `begin` has not succeeded (`clientVersionMismatch`). An older app never sends `begin`, so it is refused.
  - The version is the client's word. That is enough: the daemon has already checked the client's signature
    (`clientRequirement`), so whatever sends it is one of this team's builds, which cannot be altered without breaking
    the signature. The daemon never quotes the client's string in a message or the log.
  - Exact equality, not a minimum: the app, the CLI and the daemon ship in one bundle and carry one version
    (`HelperContractTests`), and after an update the client finds the old daemon and replaces it.
- **The cleanup verb is not offered by this release.** The daemon answers `removeRegenerableSystemDirectoryContents`
  and `forgetMountObservation` with `verbNotOffered` whoever asks (`HelperService.cleanupOffered = false`). The app maps
  no clean action to the verb (`CleanAction.helperCleanupOffered`, asserted equal to the daemon's flag), so the dyld
  cache row shows its manual route. The implementations stay, tested, for the release that gives the verb its own
  in-use check.
- **The audit trail's cheap records are rate-limited per uid** (`AuditThrottle`): `version`, `begin` and the refusals
  made before an implementation ran, 60 a minute; past that one `outcome=throttled` line, those records dropped until
  the window ends, then `outcome=suppressed count=N` before the next one. A verb that reached its implementation is
  always recorded (review R1: otherwise 61 cheap calls could hide one privileged act).
- **The contract version moves to 0.3.0** (`HelperIdentity.version` with the product version).
- **The release builds the helper in.**
  - `bundle-app.sh --with-helper --for-ci-signing --team` assembles without an identity, for the sign job to re-sign.
    Without `--for-ci-signing`, `--with-helper` still requires a Developer ID Application identity (ADR-0014).
  - `release-artifact-scan.sh` accepts the helper only with its plist, a LaunchDaemons folder holding that one file,
    byte for byte the tracked `Resources/LaunchDaemons/com.xcodevault.helper.plist`, which the workflow copies beside
    the signing scripts before the build job's zip is opened.
  - `ci-sign-notarize.sh` signs the helper first, with `--identifier com.xcodevault.helper` (the client's requirement
    pins it), and checks its identifier, team, authority, timestamp and hardened runtime as it does the other two.
  - HYG8 now requires exactly one `bundle-app.sh` line in `release.yml`, with both flags.
- **Release follow-ups:** `stapler staple` and `validate` are retried three times, 20 seconds apart; only a UUID is
  logged as a submission ID; the workflows use `checkout` v6.1.0, `upload-artifact` v6.0.0, `download-artifact` v8.0.2
  and `setup-java` v5.7.0, on Node 24, pinned by SHA.

## Consequences

- An app of 0.2.x meeting a 0.3.0 daemon is refused at every verb, and a 0.3.0 app meeting a 0.2.x daemon reinstalls
  it. A 0.3.0 app does not talk to a 0.2.x daemon at all; nothing in between is supported.
- Every verb costs two more round trips and two more audit records.
- Emptying the dyld cache is manual again, as it was before deliverable 4.
- **Not measured yet, and the condition for publishing a release with the helper:** the operator's live tests on a
  release candidate built and notarized by this workflow (the runbook, Part F): a fresh install through Login Items,
  `createVaultDirectory` on a scratch disk image (never a drive with data), `enableOwnership` again, an update over a
  `0.2.2-dev` daemon, and an uninstall. Until then the helper is labelled experimental everywhere (rule 10), as it is.
- **The build job's reach grows** (helper-security review of M5, R3). Under ADR-0010 a compromised build job, which
  holds no secret, could at most get user-level code signed with the team's Developer ID. Now the bundle carries a
  root daemon, and the scan checks its plist byte for byte but the binary against nothing: a compromised build job
  could get a root LaunchDaemon signed and notarized as this team's, once the operator approves `sign`. That
  approval, the tag ruleset, and the build job running only this repository's pinned code at the tagged commit are
  what stand in the way. A reproducible-build comparison of the helper would close it; not done.
- ~~Still open: no timeout on a client call (advisory A2).~~ Closed 2026-10-18: every message has a deadline
  (`HelperClient.Timeouts`: 15 s for `version` and `begin`, 1500 s for a verb, above the daemon's own worst case of
  about ten `diskutil` runs of up to 120 s each); on it the connection is invalidated and a later reply is dropped. The
  password dialog is answered before the verb is sent, so no deadline waits on the user. A deadline met in the opening
  is `helperDidNotAnswer`: nothing was sent, and the runner journals the step as skipped. One met during the verb stays a
  thrown error, journaled as failed with "whether it acted is unknown"; it is not left open as `started`, because
  `createVaultDirectory` journals as a migration and an open migration record reads as an interrupted migration to
  resume. With the deadline above the daemon's bound, it ends only a daemon that never answers.

## Evidence

- `M5HelperReleaseTests` (9 tests), `M5AuditThrottleScopeTests` (2) and the updated client, boundary and app tests: 90 helper-related tests pass.
  Mutants killed: the daemon's not-begun refusal disabled; the cleanup verb offered; the client ignoring a refused
  `begin`.
- `scripts/test-release-hygiene.sh`: 67 cases. Mutants killed: the plist comparison, the LaunchDaemons listing, the
  Mach-O allowlist widened, HYG8 disabled.
- STATUS.md, 2026-10-17, "M5: the helper in CI releases (ADR-0016)".
