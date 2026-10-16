# ADR 0007: Permissions are asked for at the moment of need; no root shell in the client; Full Disk Access is guided

- Status: accepted (2026-09-27)
- Date: 2026-09-27
- Spec: `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md`
- Related hypothesis: H15. Related issue: #30. Related safety rules: 1, 3, 10. Builds on ADR-0001
  (SMAppService only, no SMJobBless) and ADR-0006 (helper logic in a library target).

## Context

The target is a user who downloads XCodeVault and uses it without worrying about it. The operator
will obtain an Apple Developer ID (M5), so the target build is a notarized app whose root operations
are approved once through `SMAppService`. Two permissions matter in practice, and each has a limit
that no design can remove:

- **Full Disk Access (TCC)** cannot be granted by the app — not by code, not by password. The user
  switches it on in System Settings (an organisation's MDM profile can also grant it; XCodeVault does
  not rely on one). An app can open the exact pane and detect the grant; nothing more.
- **The privileged helper** registers through `SMAppService.daemon`, lands in `.requiresApproval`,
  and is enabled once by the user in System Settings ▸ General ▸ Login Items & Extensions with
  administrator authentication. No code calls `register()` yet, and both ends of the connection
  require a real Developer ID team ID, which no build has had; so until M5 no verb has ever run
  live (#30).

H15 measured that the refusals root met inside `/Library/Developer/CoreSimulator/` (`mkdir`, `rm`,
`mount_apfs`) were the calling terminal's missing Full Disk Access, and that they vanished with the
grant. TCC therefore applies to root processes, which contradicts the desk claim in
`SECURITY_MODEL.md` that a root launchd daemon does not need Full Disk Access (struck on the same
day as this ADR). Whether the daemon has that access is unmeasured.

Two shortcuts would give "one password prompt" today, without a signed build: `osascript -e 'do
shell script … with administrator privileges'` and `AuthorizationExecuteWithPrivileges`. Both run an
arbitrary command as root on the client's say-so — the arbitrary-execution surface the allowlisted
helper exists to avoid (`SECURITY_MODEL.md`, "Hard requirements"). The second is also deprecated
since OS X 10.7.

## Decision

1. **Ask at the moment of need.** The first run asks for nothing. Full Disk Access is asked for only
   when a scan reports folders refused with `EPERM`; the helper only when the user chooses an action
   that needs root.
2. **No root shell in the client.** Never `osascript … with administrator privileges`, never
   `AuthorizationExecuteWithPrivileges`, never a `sudo` spawned by the app. The helper's allowlisted
   verbs are the only privileged path. A build that cannot reach the helper says "Not available in
   this build" and shows the manual route as text.
3. **Full Disk Access is guided, not automated**, because it cannot be automated: open the exact
   pane, detect the grant with H15's indicator (can this process open `TCC.db`, reading nothing),
   and continue when the user comes back.

**Note (2026-10-04, R4).** Point 3 gained one step before the pane opens: one read-only `open(2)` of
`~/Library/Safari` (`FullDiskAccessRegistration`), meant to make macOS list the app in the pane so the user
only turns its switch on. This is H16 and it is **unverified**: the copy next to the button is hedged ("should
now be in the list … If it isn't there, add it with +"), and a negative manual check removes the step. It
reads nothing and grants nothing; the switch stays the user's.

## Consequences

- A first run that needs no trust, and one privileged surface to review.
- Every build made today is unsigned, so no root action can run from the app; the user does it by
  hand where a manual route is documented — the vault folder (`vault init` prints the command) and
  orphaned dyld caches (`doctor` prints one); the caches of installed runtimes have none. That is the
  honest state until M5, not a gap to paper over.
- Not doing: installing the helper at first launch; a password prompt of our own; a root-shell
  fallback for unsigned builds; automating the Full Disk Access switch.
- Availability comes from the build as well as from launchd: no usable team ID, or no daemon in the
  bundle, means "Not available in this build" whatever `SMAppService` reports — so no button that
  cannot work is ever shown (operator decision 2026-09-27).
- "Unmeasured" is the only honest word for the daemon's Full Disk Access until the first live run
  records it (#30).

## Evidence

H15 (`docs/architecture/HYPOTHESES.md`); `docs/architecture/SECURITY_MODEL.md` (Registration; the
struck TCC paragraph); issue #30; `docs/architecture/COMPATIBILITY_MATRIX.md` "Pending — added
2026-09-27".
