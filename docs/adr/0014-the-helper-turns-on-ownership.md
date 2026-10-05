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
   6. runs `/usr/sbin/diskutil enableOwnership <diskNsM>` — the bare disk identifier of the mount it holds open; fixed argv, absolute path, no shell, an environment of one
      PATH entry, an empty signal mask and default dispositions, every setup call checked, a deadline after which the
      child is killed and reaped — and verifies by reading the volume again.

   *Fix round 1 (helper-security review, 2026-10-05):* the command names the **UUID**, not the device node (L1) —
   `diskutil(8)` on macOS 26.7.1 accepts "a UUID" as the device (DEVICES), and that it resolves a *volume* UUID was
   measured read-only (`diskutil info <Data volume UUID>` → `disk1s1`). A device node is reassigned when disks come and
   go; the device-node agreement stays as a cross-check. The mount point is opened `O_RDONLY|O_DIRECTORY|O_NOFOLLOW`
   before anything is read and held across the command; immediately before it, `fstatfs` on that descriptor must still
   give the same device and `f_fsid`. The plist must carry `Internal`, `BusProtocol` and `WritableVolume`, or the volume
   is refused (M2); a disk-image key or `Virtual` refuses too. The helper frees the client's reference with
   `.destroyRights`, so an externalized form works once (L3), and a right definition counts as ours only when the
   database records `com.xcodevault.helper` as its writer (L4). The contract version moved to `0.2.0-dev` with the
   product's (L5).

   *Fix round 2 (2026-10-05):* the command takes the **bare disk identifier** (`diskNsM`) of the held descriptor's
   `f_mntfromname`, validated against an anchored pattern and re-verified immediately before the spawn (N2), rather
   than the UUID: a UUID names whichever volume carries it when diskutil looks, and two mounted volumes can carry one.
   The helper refuses unless exactly one mounted volume carries the UUID — when it pins and again right before the
   command — and unless `diskutil info -plist <UUID>`'s `DeviceNode` is the pinned one. `info -plist` still takes the
   UUID. A `Virtual` key as a Bool refuses too (N3).
   It returns a `HelperResult` with a closed `HelperResultCode`, which the audit logs `.public` with the caller uid, the
   UUID hashed and the authorization outcome; the authorization form is never logged.
2. **Per-call admin authorization.** A custom right, `com.xcodevault.helper.enable-ownership`, defined first with
   `kAuthorizationRuleAuthenticateAsAdmin` and, since fix round 4, with **its own rule**: `class user, group admin,
   timeout 10, shared false, allow-root false`. Measured in a real window (H18, 2026-10-05): the stock admin rule's
   `timeout` of 0 makes the client's credential unusable for the helper's non-interactive re-check, which failed with
   -60007. Ten seconds covers that immediate re-check and nothing more; `shared false` keeps the credential in the
   client's one reference, which the client destroys afterwards and the helper frees with `.destroyRights`, so the next
   click asks for the password again; `allow-root false` means the helper's being root never satisfies it. The daemon
   rewrites the old definition at start, the contract moved to 0.2.1-dev, and an app that meets the old daemon removes
   its registration and installs the new one through the approval flow, once per click — and only when that daemon is
   **older** (fix round 5, F2: semantic-version precedence; a newer daemon is never replaced by this copy's older one,
   and the app falls back with "a newer XCodeVault installed this helper; update this copy"). The client obtains it on
   a fresh reference with the system password dialog every time and destroys the reference afterwards. Cancelling the
   dialog is a quiet cancel.

   **What the 10 seconds do and do not bound (fix round 5, F5).** `timeout 10` bounds **this right only**. Granting it
   puts an administrator credential in the client's reference, and while that reference lives the credential can also
   satisfy *other* user-class admin rules evaluated against it, each up to its **own** timeout — for example
   `system.privilege.admin` (300 s, `shared` false). What actually limits the credential is `.destroyRights` on both
   sides: the client destroys its reference as soon as the call returns, and the helper frees its imported copy with
   `.destroyRights` after its one check, so the credential does not outlive the call on either side. The H18 re-test
   checks, where feasible, that two clicks within 10 s both prompt, and that replaying the same external form is denied.
3. **The daemon defines the right**, at startup (before the listener resumes) and again on every call. Stock macOS lets
   any local user *add* an undefined right; a squatter could add this name as `allow`. The daemon is root, relies on the
   definition, and so owns it: anything but its own rule is rewritten **and that call is refused**. Since fix round 5 a
   read-back counts as ours only when, beyond the rule's fields: the writer's code identifier is `com.xcodevault.helper`
   and its code requirement names this build's team (`subject.OU] = "<team>"`, the team `scripts/bundle-app.sh`
   substitutes); `default-prompt` is absent or every text in it is ours (a squatter's wording is never shown under our
   name); and `tries`, which authd adds to every user-class rule (10000 on this Mac), is a whole number of at least 1.
   `scripts/helper-invariants.sh` pins the read-back check whole, line for line.
4. **The client validates the helper before sending the credential**: one connection, `version()` first (replies are
   checked against the helper's code-signing requirement), the password second, the verb third. Without it the
   externalized authorization would go to whoever holds the Mach name — the requirement checks replies, not requests.
5. **The maintainer approved a narrow exception to the helper's prohibitions (2026-10-05)**, applied by the controller
   to both editor hooks (`.claude/hooks/helper-guard.sh`, `.codex/hooks/helper-guard.sh`) and enforced in
   `scripts/helper-invariants.sh`:
   - `posix_spawn` only in `Sources/XCodeVaultHelperCore/HelperDiskutil.swift`: the token exactly once in its code, on
     `DiskutilInvocation.executable` = `/usr/sbin/diskutil`, the spawn line, the argv line and both argument returns
     pinned (a verb and a canonical UUID); `posix_spawnp` forbidden; no absolute path literal but diskutil and
     `/dev/null`;
   - `AuthorizationCopyRights` only in `Sources/XCodeVaultHelperCore/HelperAuthorizationRight.swift`: the token exactly
     once in its code, called on `clientRef`, written only by `AuthorizationCreateFromExternalForm`;
   - `interactionAllowed` forbidden anywhere in the helper, and so are the routes around the rules the review found
     (fix round 1, M1): `dlsym`, `fork`/`vfork`, `@_silgen_name`, `AuthorizationCopyRightsAsync`, flags from a raw
     value, `addinherit_np`, `POSIX_SPAWN_SETEXEC`, and either API bound to a value. The hooks match the two files by
     exact path (proposed in `.superpowers/sdd/r8/hook-change-2.patch`, applied by the maintainer).
   `R8HelperInvariantsTests` mutates a copy of the tree for each of these and requires the script to fail.
   **The static invariants are a tripwire, and the mandatory helper-security review is the control:** a source lint
   cannot prove the absence of every encoding of a forbidden call.
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
- **Read from this Mac by the reviewer (2026-10-05):** `authenticate-admin` has `allow-root = false`, `shared = true`,
  `timeout = 0`. So a root evaluator does not pass on being root.
- **Unmeasured, pending the user's real-window check** (H18): whether the helper's non-interactive `extendRights` check
  succeeds on a client reference that was just granted with interaction — with `timeout = 0` the credential may not be
  reusable for a second evaluation; designs in the EvenBetterAuthorizationSample style rely on it succeeding. If it
  fails, the guided fallback is shown and nothing else changes. Also open: whether the first call, which defines the
  right, passes, and whether `diskutil enableOwnership` takes effect on a mounted volume without a remount. Until then
  the verb is EXPERIMENTAL everywhere.
- Use This Drive after ownership: the volume root keeps its real owner, so the user creates `XCodeVault/` without root;
  a root-owned root is offered the existing `createVaultDirectory` verb in Use This Drive's review.

## Evidence

- H17 physical (COMPATIBILITY_MATRIX): Owners: Disabled after `apfs addVolume` on a USB disk, 2026-10-04.
- H18 (HYPOTHESES, COMPATIBILITY_MATRIX): pending.
- Tests: `R8HelperOwnershipTests` (the verb with fakes: every refusal, the order of checks, the audit record),
  `R8OwnershipAppTests` (client handshake, cancel, fallback, Plan, quit guard), `R8HelperInvariantsTests`.
