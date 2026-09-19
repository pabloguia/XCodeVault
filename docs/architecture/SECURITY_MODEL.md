# Privileged Helper — Security Model

## Threat model summary

The helper runs with elevated privilege to perform mount/unmount and narrowly scoped
filesystem operations the GUI/CLI cannot do unprivileged. Assume an attacker controls
or can impersonate the unprivileged client and will try to use the XPC boundary to
escalate to arbitrary root filesystem access. The helper's job is to make that
impossible by construction, not by validation alone.

## Hard requirements

- **Allowlisted API only.** No arbitrary command execution, no arbitrary shell, no
  client-supplied arbitrary paths, no generic `rm`/`mv`/`mount`/`umount`.
- Every operation is a specific, narrow verb against a specific, approved resource,
  e.g.: mount an approved external-volume UUID at an approved XCodeVault mount point;
  unmount an approved volume; create an approved canonical mount point; query mount
  state; update a single, explicitly controlled `/etc/fstab` record (only if the
  chosen architecture requires it — prefer avoiding fstab edits entirely if possible);
  perform a narrowly scoped ownership/permission repair on an approved path; perform
  an approved transactional switch operation defined by the migration engine.
- Validate the calling application's identity appropriately for the XPC connection
  (code-signing requirement, not just PID/bundle-ID string matching).
- No operation accepts a free-form path string from the client that isn't first
  resolved against the approved catalog server-side (in the helper), not just checked
  client-side.
- Every privileged-helper change gets a security review before merge (this is a
  standing review gate — see `process/AGENTIC_ENGINEERING_SETUP.md`; the responsible
  role/agent must not be the same one that authored the change).

## Explicitly out of scope for the helper

Arbitrary filesystem browsing, arbitrary deletion, arbitrary process execution,
network access, anything not required by an approved migration/mount operation.

## Persistent state the helper keeps (issue #24)

The daemon was stateless until the fix for issue #24, and this section exists because a
reviewer pointed out that the change made that sentence false while the document still
said it. It now keeps one thing:

`/Library/Application Support/XCodeVault/helper-mount-history/<target>` — root-owned,
`0700` directory, `0600` files, one file per allowlisted cleanup target, contents
`wasMountPoint` or `wasPlainDirectory`. It records what the cleanup verb has observed at
that target so a plain directory where a mount point used to be is refused as shadow data
rather than deleted as a cache.

Properties this state has to have, and where each is enforced:

- **Reached by a guarded walk, never by a path.** `HelperMountHistory.openDirectory` walks
  from `/Library/Application Support` with `openat(… O_NOFOLLOW | O_DIRECTORY)` at every
  step, verifying through the descriptor that each component is a directory, is owned by
  whoever owns the anchor, and is not group- or other-writable. The first version used
  `FileManager` and inherited those properties from a stock macOS install instead of
  enforcing them; `FileManager.fileExists(atPath:isDirectory:)` also follows symlinks, so a
  symlinked component sent root's write wherever it pointed.
- **Its contents never reach a `.public` log field.** The read is size-capped and returns
  fixed reasons; the first version put the file's bytes in the refusal message, which
  `HelperAudit` emits `privacy: .public`, at unbounded length with interior newlines
  intact — log injection into a root-owned audit trail.
- **Failure to read it is not "never seen".** `ReadResult` has three cases. Absence of the
  store is absence; anything the walk rejects is `.unreadable`, which refuses. "Absence" means
  `ENOENT` and nothing else. It briefly also meant `ENOTDIR`, which looks harmless and is not:
  with `O_DIRECTORY` set, Darwin evaluates the type before the symlink rule, so a **symlinked**
  ancestor returns `ENOTDIR`, not `ELOOP` (measured on Darwin 25.6.0). Classifying that as
  absence turns a redirected store into "nothing was ever recorded here, proceed and delete".
  Anyone tempted to widen that test again should read `testASymlinkedAnchorComponentIsRefused‑
  RatherThanReadAsNeverSeen` first.
- **Failure to write it is reported, not swallowed.** Both call sites check the result. An
  unrecorded observation silently disables the guard for the following run.

**What `forgetMountObservation` leaves standing, stated plainly.** With that verb in the API,
the issue #24 guard is defeatable by any caller authorized to reach the XPC surface — so it
is a safety control against *accident*, not a security control against a hostile client. A
caller that satisfies the code-signing requirement and runs as an admin uid could already
call `removeRegenerableSystemDirectoryContents`; `forget` restores exactly that pre-#24
behaviour for one enum-named target and grants nothing beyond it. The confirmation that
would make it safe against a hostile client can only live in the client, which this threat
model assumes is attacker-controlled. Any client exposing this verb must require explicit
interactive confirmation naming the target.

It is **sticky on purpose**: nothing expires it, because an expiry would re-open the hole
on exactly the timescale a disconnected volume sits unplugged. `forgetMountObservation` is
therefore part of the allowlisted API rather than an omission — without it a user whose
vault volume is gone for good could never clean that cache again. It is gated and audited
like every other state-changing verb, because clearing the record re-enables a root
deletion, and it is a separate call so that no single message can both forget an
observation and act on having forgotten it.

Two consequences worth stating rather than discovering later:

- Uninstalling the app does not remove this directory. `packaging/homebrew/` zaps it, but a
  user who removes the app by hand leaves a root-owned directory behind.
- It is per-machine, not per-user, and it is not synced or backed up by design.

## SIP

The helper must never disable, weaken, or instruct disabling of SIP, and must never
require it as a precondition for any documented flow. Never modify `/System`.

---

## Concrete implementation requirements (2026-09-05 research pass)

### Registration

> **Specification, not shipped behaviour.** `SMAppService` is named in two comments and called
> nowhere: there is no registration, no `.status` handling, no `unregister()`, and no client opens a
> connection to the helper at all. `README.md` says so plainly ("Built and security-reviewed, not
> reachable from any client") and `scripts/bundle-app.sh` keeps the daemon behind `--with-helper`,
> off by default. This section says what registration must do when it is written.

- Use **`SMAppService.daemon(plistName:)`** (macOS 13+). `SMJobBless` is deprecated as
  of macOS 13 and, per ADR-0001, we do not ship a parallel SMJobBless path.
- **Only `.daemon` runs as root**; `.agent` runs as the user.
- launchd plist at `XCodeVault.app/Contents/Library/LaunchDaemons/<name>.plist`. Pass
  the **full filename including `.plist`** (omitting it is a known cause of registration
  error 108). Use `BundleProgram` (bundle-relative) and `AssociatedBundleIdentifiers`.
  Do **not** carry over `SMPrivilegedExecutables` / `SMAuthorizedClients` — those are
  SMJobBless-era keys and mixing them is a known failure mode.
- Registration lands in `.requiresApproval`; the user must enable it in
  **System Settings ▸ General ▸ Login Items & Extensions**, and a daemon additionally
  requires admin authentication. Handle every `SMAppService.status` case in the UI.
- The registration is bound to the app bundle's location and signature — moving or
  deleting the app breaks it, and `brew uninstall` leaves a **stale BTM entry**. Ship an
  in-app uninstall that calls `unregister()`, plus a Homebrew `zap` stanza. Debug with
  `sfltool dumpbtm`.

### Client validation — the part where a bug is a local root escalation
- Use **`NSXPCConnection.setCodeSigningRequirement(_:)`** (macOS 13+), set **before
  `resume()`**. Apple DTS: it performs real certificate-chain validation; **do not
  hand-roll `SecCodeCheckValidity`** (TOCTOU exposure).
- **Never validate by PID.** `processIdentifier` → `SecCodeCopyGuestWithAttributes` is
  the classic PID-reuse/exec-race escalation. Audit token or the requirement API only.
- Never `return YES` unconditionally from `shouldAcceptNewConnection:`, and never call
  `AuthorizationCopyRights` with a NULL `AuthorizationRef` — that exact pair, plus a
  helper that execs attacker-controlled arguments, is **CVE-2025-65842** (any local user
  → root). Our allowlisted-verb design exists specifically to make that class impossible.
- Resolve and validate paths **inside the helper, after resolution**, against the
  approved catalog — symlink swap between check and use is the other half of the class.
  No shell interpretation anywhere: array-argument `posix_spawn` only.
- Include a version predicate in the requirement if the app can be downgraded.

### Privilege and TCC facts worth designing around
- **No entitlement exists or is needed** for an unsandboxed root daemon to mount. The
  App Sandbox is what blocks it (`system.volume.external.mount` authorization right).
- **A root launchd daemon does not need Full Disk Access** — TCC is a user-level concept.
  The **GUI app**, running as the user, is the part that hits TCC enumerating
  `~/Library`. Split responsibilities accordingly: app does UI and presentation, helper
  does privileged filesystem work and can also serve size accounting if TCC bites.
- Whether `~/Library/Developer` is TCC-protected on macOS 26/27 is unverified — test on
  a clean VM before designing either way.
- Removable volumes have their own TCC category with **no API to preflight or request
  it** — see H6/E2; this may constrain the product regardless of mount path.

### Distribution
Developer ID for app *and* helper · inside-out signing (helper first) · hardened runtime
(avoid `disable-library-validation` — it lets an attacker-supplied dylib into a root
process) · `--timestamp` on every signature · notarize the **container**, staple the
`.app`/`.dmg`/`.pkg` · strip `com.apple.quarantine` xattrs before signing (Apple
requirement since 2025-02-18).

### Reference material (study, don't copy wholesale)
`trilemma-dev/SwiftAuthorizationSample` and `SecureXPC` for security reasoning
(SMJobBless-era); `alienator88/HelperToolApp` for SMAppService registration mechanics
**only** — its arbitrary-command design is the anti-pattern; `securing/SimpleXPCApp`
(archived) as a teaching repo for the vulnerability class. Apple's own SMAppService
sample is **agent-only, not a root daemon** — there is no well-audited reference
implementation for what we need, so the security review gate is not optional.
