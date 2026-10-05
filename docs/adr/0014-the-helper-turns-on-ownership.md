# ADR 0014: The privileged helper turns on ownership, behind the admin password on every call

- Status: accepted (implementation EXPERIMENTAL until H18 is verified in a real window — rule 10)
- Date: 2026-10-05
- Related hypothesis: H17 (diskutil without sudo), H18 (this verb, new)
- Amends: ADR-0012, decision 4 ("adds **no helper verb**")

## Context

R7-D measured, on the user's physical USB disk, that a volume made with `diskutil apfs addVolume` by the logged-in user
has **Owners: Disabled** (H17 physical). XCodeVault refuses a vault on such a volume (`VolumeQualification`), and turning
ownership on needs root: `diskutil enableOwnership`. ADR-0012 left that to the user — Finder's Get Info, or a copied
`sudo diskutil enableOwnership` — and added no helper verb.

The user then asked for one click (2026-10-05): "tem que ser simples pro usuário, pedir a senha e executar o que for
necessário", keeping the instructions "caso algo dê errado", and said they would sign the app with their own Apple team.

Two hard constraints shaped the answer. CLAUDE.md rule 3: the helper exposes allowlisted verbs only, with no arbitrary
path or command. And `SECURITY_MODEL.md` forbade, in the helper, both process execution and `AuthorizationCopyRights` —
the second because a root process asking the rights API about a reference it made itself, or a NULL one, is told yes
(the CVE-2025-65842 shape). This verb needs one of each.

## Decision

1. **One new allowlisted verb**, `enableOwnership(volumeUUID:authorization:reply:)`. The client sends a UUID and the
   externalized form of an `AuthorizationRef` — never a path, a device node or command text. The helper:
   1. applies the existing administrator gate (and, before it, the connection's code-signing requirement);
   2. parses the UUID (never the all-zero one);
   3. ensures the right's definition, then **re-checks the right** from the client's form with no interaction;
   4. resolves the UUID to a volume itself (mount table + `getattrlist`, `statfs`, `diskutil info -plist <UUID>`, all three
      agreeing on UUID, mount point and device node) and refuses unless it is mounted, local, writable, external, APFS or
      HFS+, not the boot volume or its container, not a disk image, not Time Machine (role or marker);
   5. runs nothing if ownership is already on;
   6. runs `/usr/sbin/diskutil enableOwnership <its own device node>` — fixed argv, absolute path, no shell, an
      environment of one PATH entry, a timeout — and verifies by reading the volume again.
   It returns a `HelperResult` with a closed `HelperResultCode`, which the audit logs `.public` with the caller uid, the
   UUID hashed and the authorization outcome; the authorization form is never logged.
2. **Per-call admin authorization.** A custom right, `com.xcodevault.helper.enable-ownership`, defined with
   `kAuthorizationRuleAuthenticateAsAdmin`. The client obtains it on a fresh reference with the system password dialog
   every time and destroys the reference afterwards. Cancelling the dialog is a quiet cancel.
3. **The daemon defines the right**, at startup (before the listener resumes) and again on every call. Stock macOS lets
   any local user *add* an undefined right; a squatter could add this name as `allow`. The daemon is root, relies on the
   definition, and so owns it: anything but `class=rule, rule=authenticate-admin` is rewritten **and that call is
   refused**.
4. **The client validates the helper before sending the credential**: one connection, `version()` first (replies are
   checked against the helper's code-signing requirement), the password second, the verb third. Without it the
   externalized authorization would go to whoever holds the Mach name — the requirement checks replies, not requests.
5. **The maintainer approved a narrow exception to the helper's prohibitions (2026-10-05)**, applied by the controller
   to both editor hooks (`.claude/hooks/helper-guard.sh`, `.codex/hooks/helper-guard.sh`) and enforced in
   `scripts/helper-invariants.sh`:
   - `posix_spawn` only in `Sources/XCodeVaultHelperCore/HelperDiskutil.swift`: exactly one call, on
     `DiskutilInvocation.executable` = `/usr/sbin/diskutil`; `posix_spawnp` forbidden; no absolute path literal but
     diskutil, `/dev/null` and the `/dev/disk` prefix;
   - `AuthorizationCopyRights` only in `Sources/XCodeVaultHelperCore/HelperAuthorizationRight.swift`: exactly one call,
     whose first argument is `clientRef`, written only by `AuthorizationCreateFromExternalForm`;
   - `interactionAllowed` forbidden anywhere in the helper.
   `R8HelperInvariantsTests` mutates a copy of the tree for each of these and requires the script to fail.
6. **The fallback stays.** The app shows R7-D's guided route (Show in Finder + Copy Command) with the reason whenever
   the click is not offered or did not work: the build is not signed by a usable team with the daemon; the helper was
   not approved; the helper refused; the verb failed. `OwnershipRoute` in Core decides; the views render.

## Why not AppleScript "with administrator privileges"

`do shell script "…" with administrator privileges` would ask for the password and needs no helper. It was rejected:
it runs a **shell command string as root**, built in the app — exactly the arbitrary-command shape rule 3 exists to
rule out, moved from the helper into the client; it is deprecated in spirit (Apple's guidance is a privileged helper);
it cannot be held by `helper-invariants.sh`; and its argument would be a path or device node the *client* chose, which
`SECURITY_MODEL.md` forbids. The helper resolves the volume itself; the AppleScript route cannot.

## Consequences

- ADR-0012 decision 4 is amended: the helper gains exactly one verb. Everything else in it stands; the app still never
  retries a failed `diskutil` with privileges.
- The helper is no longer free of process execution or of the rights API. Both exceptions are one file each, held by
  the script and its mutation tests, and reviewed by `helper-security-reviewer` (mandatory) and
  `migration-safety-reviewer`.
- `HelperResult` gains `code`; an older daemon sends none (decoded `none`). The XPC contract has no separate version —
  `HelperIdentity.version` is pinned to the product version — so a daemon too old to have the verb fails the connection
  and the app falls back.
- **Unmeasured, pending the user's real-window check** (H18): whether the stock `authenticate-admin` rule lets a root
  evaluator pass without the client's credential (its `allow-root`); whether the first call, which defines the right,
  passes the helper's check; whether `diskutil enableOwnership` takes effect on a mounted volume without a remount.
  Until then the verb is EXPERIMENTAL everywhere.
- Use This Drive after ownership: the volume root keeps its real owner, so the user creates `XCodeVault/` without root;
  a root-owned root is offered the existing `createVaultDirectory` verb in Use This Drive's review.

## Evidence

- H17 physical (COMPATIBILITY_MATRIX): Owners: Disabled after `apfs addVolume` on a USB disk, 2026-10-04.
- H18 (HYPOTHESES, COMPATIBILITY_MATRIX): pending.
- Tests: `R8HelperOwnershipTests` (the verb with fakes: every refusal, the order of checks, the audit record),
  `R8OwnershipAppTests` (client handshake, cancel, fallback, Plan, quit guard), `R8HelperInvariantsTests`.
