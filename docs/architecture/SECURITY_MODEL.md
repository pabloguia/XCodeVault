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
  e.g.: mount an approved external-volume UUID at an approved XcodeVault mount point;
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
