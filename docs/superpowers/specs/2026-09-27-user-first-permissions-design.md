# User-first docs and permissions: design

*Approved by the operator 2026-09-27. The operator will obtain an Apple Developer ID (M5), so the
target is a notarized app whose root operations are approved once through `SMAppService`.*

## Goal

A user downloads XCodeVault and uses it without worrying about it:

- The first run asks for nothing.
- A permission is asked for only at the moment an action needs it.
- Wherever macOS allows, "asking" means one system prompt for approval or credentials. The user is
  not handed a Terminal command to run.

## Hard limits (they shape the design; do not design around them)

- **Full Disk Access (FDA) cannot be granted by code or by password.** The user must turn it on in
  System Settings. The most the app can do:
  - open the exact pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`);
  - detect the grant;
  - continue on its own.
- **The root helper needs a signed build.**
  - `SMAppService.daemon` registration lands in `.requiresApproval`.
  - The user enables it once in System Settings ▸ General ▸ Login Items & Extensions, with admin
    authentication.
  - Until M5, no verb has run live (issue #30).
- **Never run a root shell from the client** (rule 3; `SECURITY_MODEL.md`). No `osascript … with
  administrator privileges`, no `AuthorizationExecuteWithPrivileges`. The helper's allowlisted verbs
  are the only privileged path.
- **Whether the launchd daemon needs FDA is unmeasured.**
  - `SECURITY_MODEL.md` ("A root launchd daemon does not need Full Disk Access") is a desk claim.
  - H15 contradicts it for root processes in `/Library/Developer/CoreSimulator`.
  - Say "unmeasured" everywhere until the first live run records it (issue #30 comment,
    2026-09-27).
- Every safety rule in `CLAUDE.md` holds. Labels stay *experimental* where they are today (rule 10).

## 1. User documentation

- **`README.md`** becomes user-first and about one screen long:
  1. what it does;
  2. install;
  3. first run;
  4. a permissions table;
  5. what it never does (five lines);
  6. the honest state.

  Install covers today's route (build from source) and the planned one (notarized DMG, Homebrew
  cask), with the planned one labelled as planned. Research, ADRs, hypotheses and contributor
  material move to a "For contributors" block of links.
- **`docs/USER_GUIDE.md`** (new): each GUI section and CLI command, what it changes, and how to undo
  it.
  - A "Permissions: which, when, why, how the app asks" table.
  - An FAQ covering at least:
    - external drive disconnected;
    - "why did the space come back";
    - "why is this greyed out".
- **`docs/product/UX_AND_CLI.md`** gains the `permissions` command and the ask-at-the-moment-of-need
  flow.
- **`docs/architecture/SECURITY_MODEL.md`** is corrected in place (strike the claim, cite H15, keep
  the history).
- **`docs/adr/0007-permissions-asked-at-need.md`** (new) records three decisions:
  - ask at the moment of need;
  - no root shell in the client;
  - FDA is guided rather than automated, because it cannot be automated.
- **`STATUS.md` and `COMPATIBILITY_MATRIX.md`** record the helper flow as *pending — needs a signed
  build*.

## 2. Permissions model (XCodeVaultCore)

One source of truth, used by the CLI and the GUI:

- **`FullDiskAccessState`**: `granted | notGranted | unknown`.
  - The probe opens `/Library/Application Support/com.apple.TCC/TCC.db` read-only, the project's
    existing indicator (`xcv_stage_tcc_indicator`).
  - EPERM means `notGranted`. Success means `granted`. Anything else means `unknown`.
  - The path is injectable for tests.
  - Never read the file's contents.
- **`HelperState`**: `unavailableInThisBuild | notInstalled | awaitingApproval | enabled`.
  - It maps from `SMAppService.Status` plus the build's team-ID usability (`HelperIdentity.isUsableTeamID`).
  - `.notFound` and `.notRegistered` both mean `notInstalled`. `HelperClient.serviceStatus()`
    documents why both occur.
  - This is an installation hint only. Peer authentication stays in `HelperClient.connect()`.
- **`PrivilegeRequirement`**: `.helper | .helperWithFullDiskAccess | .appFullDiskAccess`.
  - `.helperWithFullDiskAccess` applies to `/Library/Developer/CoreSimulator/Caches/dyld` only, the
    same scope as today's `CleanAction.privilegeRequirement`, and its text says "unmeasured".
  - The human text comes from one place.
  - `CleanAction.privilegeRequirement` (a942c02) is migrated to use it, not duplicated.
- **Doctor findings** that today say "run `sudo …`" gain an optional structured action. First case:
  vault directory creation → helper verb `createVaultDirectory(volumeUUID:)`.
  - The text remediation stays as the fallback.
  - `sudo xcode-select` is Xcode's own and stays text.

## 3. What the user sees

**CLI.**
- New read-only command `xcodevaultctl permissions [--json]`: the FDA state and the helper state,
  each with one next step.
- `clean`'s tag points to it.

**GUI.**
- New sidebar section **Permissions**:
  - two rows, FDA and helper, each with a status, one sentence of why, and one button:
    - [Open Settings] for FDA;
    - [Install] or [Uninstall] for the helper.
  - When the app becomes active again after the user returns from Settings, re-check and rescan.
- **FDA is asked for only when needed.** The prompt appears only when a scan reports unreadable
  paths caused by EPERM. The Overview banner then says "Some folders could not be read — [Open
  Settings]".
- **The helper is asked for only when needed.** When the user picks a root action, a sheet explains
  it in one sentence with an [Allow] button. Then:
  1. `register()`;
  2. `SMAppService.openSystemSettingsLoginItems()`;
  3. poll the status;
  4. when it reaches `enabled`, run the action.
- In an unsigned build, the same place says "Not available in this build" and shows the manual
  fallback. **A button that cannot work is never shown.**
- **Uninstall** calls `unregister()`. The Homebrew cask draft already references it.

## 4. Testing and review

**Unit tests.**
- The FDA probe, with an injected readable path and an injected EPERM path.
- The `HelperState` mapping, for every `SMAppService.Status` case, with an unusable and a usable team
  ID.
- `PrivilegeRequirement` per action.
- The doctor structured action is present only for the vault-dir finding.
- The GUI's button-visibility decision, extracted into a testable function.

**Other checks.**
- `permissions --json` joins the `cli-smoke` gate.
- Mutants on the key decisions:
  - an action button appears only when the state is `enabled`;
  - an unusable team ID means `unavailableInThisBuild`;
  - EPERM means `notGranted`.
- For each mutant, verify that it was applied and print the test count.

**Declared gaps.**
- `register()`, the approval round-trip and XPC calls cannot run live before M5.
- They are unit-tested with fakes and recorded as *pending*.

**Reviews.**
- **helper-security-reviewer:** anything touching `HelperClient`, registration or XPC, and
  `scripts/helper-invariants.sh` must stay green. The single-`NSXPCConnection` rule still holds.
- **migration-safety-reviewer:** actions that create or delete data (the vault directory, cache
  cleanup).
- `scripts/preflight.sh` (11 gates) before every push.

## 5. Deliverables (separate commits, each reviewed and preflighted)

1. User docs, ADR-0007, and the `SECURITY_MODEL.md` correction.
2. The `Permissions` model in Core, plus `xcodevaultctl permissions`.
3. The GUI Permissions section and the ask-at-need flow. FDA works today.
4. The helper register/approval/unregister flow and the doctor buttons, gated on a signed build.

## Out of scope

- Signing, notarization and the release pipeline themselves (M5; needs the operator's certificate).
- Measuring whether the daemon needs FDA (first live helper run, #30).
- Physical-yank and dyld-rebuild research (STATUS "Next three actions").
