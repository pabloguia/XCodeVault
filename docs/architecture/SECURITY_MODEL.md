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
