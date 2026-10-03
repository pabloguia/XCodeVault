# ADR 0010: Releases are signed and notarized in CI, by a job behind an approved environment

- Status: accepted (2026-10-02); the workflow has not run yet
- Date: 2026-10-02
- Related: ADR-0005 (public open-source release); M5 in STATUS.md; issue #30 (the helper has not run live in
  a signed build). Operator steps: docs/process/RUNBOOK-M5-release-signing.md.

## Context

The repository is public, and a signed, notarized build needs a Developer ID Application identity and an App
Store Connect API key. Until now the only path was `scripts/release.sh` on the operator's Mac, with the
operator's own identity. The operator asked for releases signed by GitHub Actions under two conditions: nobody
signs with their identity without their permission, and nothing private of theirs is exposed. Their name may
appear, since a Developer ID certificate carries it.

Three options were weighed on 2026-09-29:
1. secrets held by a GitHub environment that only an approved job reaches;
2. remote signing (rcodesign), with the key never leaving the operator's Mac;
3. CI builds and attests, the operator's Mac signs.

The operator chose 1, after being told what it does not cover:
- anyone who controls their GitHub account or a token with `repo` scope can push a tag and approve the run;
- code that runs in the signing job can read the key;
- a tag can name a commit that is not on `main`, so that has to be checked.

Measured before deciding:
- A Developer ID Application certificate's subject holds the name, the team ID and the country, and no e-mail.
  Measured on three third-party apps on 2026-09-29, and on the operator's CI certificate on 2026-10-02: its
  keychain name is `Developer ID Application: <name> (<team>)`. The operator's *Apple Development* identity is
  named with their Apple ID e-mail.
- The certificates `codesign --extract-certificates` takes from a Developer ID-signed app (iTerm, 2026-10-02)
  hold no string shaped like an e-mail, so a scan for one runs on the signed bundle without a false positive
  from Apple's chain or timestamp.
- On macOS 26.7, `strings -a` found none of the 206 `/Users/<home>/…` paths in the symbol table of a debug
  `xcodevaultctl`, which `tr -c '[:print:]' '\n'` found. The scan reads the whole file that way.
- Running the new hygiene check over the tree found `sonar.yml` using two actions by tag (`setup-java@v4`,
  `sonarqube-scan-action@v6`) in the job that holds `SONAR_TOKEN`. They are now pinned by commit SHA.

## Decision

- **`.github/workflows/release.yml`** runs on a pushed `v*` tag and on nothing else, starts from
  `permissions: {}`, and grants each job only what it needs.
  - `build` has no environment and no secret. It refuses unless the tag's commit is an ancestor of `main` and
    the tag is `v` + `ScanReport.current`. It runs `scripts/preflight.sh`, then `bundle-app.sh --release
    --team` **without `--with-helper`**, checks that the tracked sources were restored, scans the bundle, and
    hands it on with its SHA-256. The ancestry check catches the operator's mistake, not an attack: a tag on
    another commit runs that commit's `release.yml`, which need not contain the check (Consequences).
  - `sign` has `environment: release`, so it waits for the operator's approval, and it is the only job the
    signing secrets reach. It builds nothing.
    - It copies the two signing scripts out of the checkout before it opens anything the build job made, and
      runs those copies.
    - It refuses if the tag no longer names the commit the run built.
    - It checks the bundle's hash against `build`'s. That only says the zip is what `build` uploaded, and
      `build` made it, so `scripts/ci-unpack-bundle.sh` refuses, from the zip's listing, an entry outside
      `XCodeVault.app/`, a `..` component or a link; and after extraction, a link or anything beside the
      bundle. Its first version, inline here, piped the listing into `grep -q`; under `pipefail` a large
      listing died of SIGPIPE and the refusal never ran (review round 2, reproduced with 3000 entries).
    - It imports the `.p12` into a temporary keychain with a random password (and Apple's Developer ID G2
      intermediate, pinned by SHA-256), and runs `ci-sign-notarize.sh`.
    - It deletes the keychain, at its fixed path, and the key files with `if: always()`.
  - `publish` checks the tag again, since `gh release create` binds to wherever it points now, attests the
    DMG's build provenance, and creates a **draft** release. The operator publishes it.
- **`scripts/ci-sign-notarize.sh`** refuses unless the keychain holds exactly one signing identity, with the
  hash in `APPLE_SIGNING_IDENTITY`, named `Developer ID Application: … (<team>)`. It signs inside-out with the
  hardened runtime and a timestamp, and checks the team, the authority, the timestamp and the runtime flag of
  each signature. It notarizes with the API key and staples the app before building the DMG, then signs,
  notarizes and staples the DMG. It runs `spctl` on both and scans the bundle again.
- **`scripts/release-artifact-scan.sh`** refuses a bundle that holds the helper or its launchd plist, a
  Mach-O file other than the two built, a symbolic link, a `/Users/<name>` path other than the runner's, or
  anything shaped like an e-mail address. It prints the file and a count, never the match: on CI its output
  is a public log.
- **`scripts/release-hygiene.sh`**, in CI and preflight, reads the workflows with a YAML parser (Ruby's
  Psych, which macOS ships). Its first version used line patterns, and the helper-security review of
  2026-10-02 reproduced bypasses through every one of them: a `#` in a quoted string read as a comment, flow
  style, quoted keys, `toJSON( secrets )`. Refused outright, because with them the parser and Actions could
  read different documents: anchors, aliases, merge keys (`<<`), more than one YAML document, a top-level key
  Actions does not define, a quoted or non-ASCII key, and duplicate keys, compared as Psych reads them (a plain `on`, `On`
  and `true` are one key to it). It refuses:
  - tracked signing material;
  - `pull_request_target`;
  - an action not pinned by SHA;
  - an environment, or any secret but `SONAR_TOKEN`, in another workflow;
  - the `secrets` context reached other than as `secrets.NAME`, anywhere;
  - in `release.yml`: a trigger other than `push: tags: ['v*']`, top-level permissions other than `{}`, a job
    other than the three, a job granted other than its listed permissions, a reusable workflow,
    `--with-helper`, a signing secret outside `sign`, or an environment anywhere but `sign`.

  `scripts/test-release-hygiene.sh` proves each refusal fires alone, including each bypass the review
  reproduced; that the committed tree and comment lines naming the forbidden things pass; and the same for
  the artifact scan, on a fake bundle, and the unpacking, on zips built entry by entry.
- **The certificate and the API key exist for CI only.** The operator's own identity stays on their Mac, and
  `scripts/release.sh` now refuses any identity that is not `Developer ID Application: … (<team>)`.
- **The team ID is written in `release.yml`.** It is public in every signed binary, and `build` has no access
  to the environment's variables. `sign` refuses unless the environment's `APPLE_TEAM_ID` agrees.

## Consequences

- A release needs three acts by the operator: create the tag (only they can, by the tag ruleset), approve
  `sign`, and publish the draft. The agent does none of them.
- The repository can enforce what is in the tree, not what is in GitHub's settings. The required reviewer,
  the `v*` deployment rule and the rulesets are settings. On 2026-10-02 `gh api` showed the environment
  **without a required reviewer and with administrator bypass on**. The runbook's B.3 says to fix both, and a
  release must not be tagged until `gh api repos/pabloguia/XCodeVault/environments/release` shows a
  `required_reviewers` rule.
- **What actually holds a tag that is not on `main`:** the tag ruleset and the required reviewer, and
  nothing in this tree. Such a tag runs that commit's workflows, which the hygiene check never read.
- Every `uses:` in every workflow must now be a commit SHA. Updating an action means updating its SHA. The
  check reads the shape: it does not check that the SHA belongs to the repository named, nor what a
  composite action pins inside itself.
- Signing material is recognised by its extension. A key saved under another name is not caught.
- The `.p12` password and the notary key and issuer IDs are command-line arguments inside `sign`, which
  `security import` and `notarytool` require; the runner is a single-use VM.
- Runs are serialised. A third tag pushed while one run waits for approval cancels the second one's pending
  run, and re-running `publish` after its release exists fails at `gh release create`.
- The helper stays out of CI releases. Adding it is a change to `release.yml` that the hygiene check refuses,
  so it has to come with this ADR superseded.
- The signed workflow has not run. The first tag is its first test, and anything it gets wrong is found after
  the operator approves. The DMG goes to a draft, never straight to users, and Part D of the runbook is how
  the operator checks it.
- `release.sh` still exists for local releases.

## Evidence

- STATUS.md, 2026-10-02, "M5: releases signed in CI (ADR-0010)".
- `scripts/test-release-hygiene.sh`: 60 cases. For the workflows, 2 controls and 44 refusals, each required
  to fire alone; for the artifact scan, 2 controls and 6 refusals; for the unpacking, 1 control and 5
  refusals, each pinned by its message. Killed mutants: a job's permission check disabled; the
  indirect-`secrets` matches dropped; each listing check put back in its piped form; the top-level key list
  disabled; duplicate keys compared as written instead of as read.
- The helper-security review of 2026-10-02: round 1 REQUEST CHANGES (B1, R1–R7, N1–N7); round 2 REQUEST
  CHANGES (R8, N8, N9); rounds 3, 4 and 5 APPROVE, each with one NIT (N10, two spellings of one key; N11, a
  quoted key beside a plain one; N12, a key with `ſ`), answered here.
