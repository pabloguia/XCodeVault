# Security Policy

## Why this file matters more than usual here

XCodeVault ships a **privileged helper** — a daemon that runs as root, installed via
`SMAppService.daemon`. A defect in it is a local privilege-escalation defect, not a crash. The
threat model, the allowlisted API and the reasoning behind both are in
`docs/architecture/SECURITY_MODEL.md`; read it before reporting, and certainly before proposing a
patch.

The helper is currently **built and code-signed-gated but not reachable from any client**: it is not
yet wired into the CLI or the GUI, because that needs a signed bundle. That lowers the practical
impact of a defect in it today. It does not lower the standard applied to changes.

## Reporting a vulnerability

**Do not open a public issue.**

Use GitHub's private vulnerability reporting: the **Security** tab of this repository →
**Report a vulnerability**. That channel is private to the maintainers and gives you a thread to
discuss a fix before anything is disclosed.

Please include:

- macOS build (`sw_vers`), Xcode version, and architecture (`uname -m`);
- the commit you tested;
- what an attacker gains, concretely — the difference between "this path is not validated" and
  "this path is not validated, and here is the sequence that turns it into a root write";
- a reproduction, if you have one. A proof of concept that stops short of damage is welcome and
  preferred.

There is no bounty. This is an unpaid single-maintainer project; expect a first response in days
rather than hours.

## Scope

In scope, and taken seriously:

- anything that lets a non-root caller get the helper to act on a path it should not act on;
- anything that defeats the helper's code-signing requirement, or lets an unsigned or differently
  signed client connect;
- any way to make a documented product flow require SIP to be disabled;
- any path by which a migration destroys data it promised to preserve, or leaves shadow/duplicate
  data after a volume disconnect;
- any command that deletes a non-regenerable artifact (Archives above all) without explicit intent.

Out of scope:

- "the tool could delete files" — it is a storage tool, and deletion is a documented, gated
  operation. The bug is when it deletes something it said it would not, or before verification;
- anything that requires SIP to already be disabled. This project never disables SIP and never asks
  a user to; a machine with SIP off is outside the model rather than a finding against it;
- findings against Apple's own tooling. Report those to Apple. If the behaviour changes what this
  project should do, an issue here is welcome as a compatibility report.

## Supported versions

There are no releases yet. The supported version is `main`, and there is no backporting.
