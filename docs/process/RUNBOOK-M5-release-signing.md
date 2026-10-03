# RUNBOOK — M5: signing and notarizing releases in GitHub Actions

Written 2026-09-29; Parts A and B done by the operator on 2026-10-02; Part C written 2026-10-02 (ADR-0010).
**No release has run yet.** This is option 1 of the three discussed on 2026-09-29: the release is signed and
notarized by a GitHub Actions workflow, with a certificate that exists only for CI.

- Parts A and B are the operator's: Apple and GitHub configuration. Nothing in them touches this repository.
- Part C is the repository's side: the workflow, the hygiene gate and ADR-0010. It goes through the
  helper-security review before it lands.
- Part D is how a release is cut once Part C is in. Part E is what to do if a CI secret may have leaked.

Local signing on the operator's Mac stays as it is (`scripts/release.sh`, the operator's own Developer ID).
The first signed builds and the live run of the helper (#30) happen there, not in CI.

## What this protects, and what it does not

It protects against:
- **The public and forks.** Secrets never reach a workflow run for a pull request from a fork. The
  `release` environment's secrets reach only a job that the operator approves.
- **Signing something unintended.** Only a `v*` tag, which only the operator can create, after the operator
  approves the run. These two settings are the control. The workflow also refuses a tag whose commit is not on
  `main`, but that catches a mistake, not an attack: a tag on another commit runs that commit's workflow.
- **Exposing the operator's e-mail.** A Developer ID certificate carries the name, the team ID and the
  country, and no e-mail. This was measured on three Developer ID certificates on 2026-09-29. The operator's
  *Apple Development* identity has the Apple ID e-mail in its name, so it is never used for anything
  distributed.

It does not protect against:
- **Someone who controls the operator's GitHub account or one of its tokens.** They can push a tag *and*
  approve the run through the API. So B.1 is part of the key's security.
- **Code that runs in the signing job.** That job is kept to Apple's tools and actions pinned by commit SHA,
  and it builds nothing. The surface is small, not zero.
- **A copied key.** A copy signs without asking anyone. That is why the certificate is CI-only: revoking it
  leaves the operator's own certificate untouched (Part E).

The agent never creates a release tag unless asked, and never approves a signing run.

## Part A — Apple, on the operator's Mac

### A.1 A Developer ID Application certificate for CI only

An account can have up to five Developer ID Application certificates, and only the Account Holder can create
them.

1. Open Keychain Access (on recent macOS, find it with Spotlight). Choose Keychain Access ▸ Certificate
   Assistant ▸ Request a Certificate From a Certificate Authority, and fill in:
   - **User Email Address:** your Apple ID. It goes to Apple only.
   - **Common Name:** `XCodeVault CI`. This becomes the name of the private key in the keychain.
   - **CA Email Address:** leave it empty.
   - Choose **Saved to disk**.

   This creates the private key in the login keychain and saves a `.certSigningRequest` file.
2. Go to developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Certificates ▸ **+** ▸ Developer ID
   Application. Choose the G2 Sub-CA profile type, upload the request, and download the `.cer`.
3. In Keychain Access select the **login** keychain in the sidebar, then File ▸ Import Items… and choose the
   `.cer`. It joins its private key there. Double-clicking it while the **iCloud** keychain is selected fails
   with error -25294 (`errSecNoSuchKeychain`), as it did on 2026-10-02.
4. Check it: `security find-identity -v -p codesigning` now lists a Developer ID Application identity whose
   key is `XCodeVault CI`.

### A.2 Export it for GitHub, then remove it from the Mac

1. Make a folder **outside the repository**, e.g. `mkdir -m 700 ~/xcv-ci-secrets`.
2. In Keychain Access ▸ login ▸ My Certificates, find the new certificate (expand it: the key is
   `XCodeVault CI`). Right-click it ▸ Export ▸ format `.p12` ▸ save it in that folder as `XCodeVault-CI.p12`.
3. Give it a long random password, for example from `openssl rand -base64 32`. Keep the password in your
   password manager until B.4.
4. After B.4 has uploaded it, delete the certificate and its key from the login keychain (right-click ▸
   Delete) and delete the folder. The CI key then exists only in the GitHub environment. If you keep a backup,
   keep it encrypted, in a password manager. Losing the key costs a revocation and a new certificate, nothing
   more.

### A.3 A notarization API key for CI only

1. Go to App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ **Team Keys** ▸ Generate
   API Key. The first time, request access to the API on that page.
2. Name it `XCodeVault CI notary` and give it the access **Developer**, which is enough for notarization.
3. Download `AuthKey_<KEY ID>.p8` into `~/xcv-ci-secrets`. It can be downloaded only once. Note the **Key ID**
   and the **Issuer ID** shown on that page.
4. Delete the `.p8` after B.4.

This key is separate from any key you use locally; revoking one does not affect the other.

## Part B — GitHub

### B.1 Your account: the key's security depends on it

- **Two-factor authentication** with a passkey or a security key (Settings ▸ Password and authentication).
- **Tokens:** go to Settings ▸ Developer settings ▸ Personal access tokens. Delete what you do not use, and keep
  no token with `workflow` or `admin` scopes you do not need.
- **Sessions:** review Settings ▸ Sessions, and Settings ▸ Applications for authorized apps.
- **The `gh` CLI on this Mac.** `gh auth status` shows its scopes. It is the token the agent pushes with, and
  the API would let it create tags and approve runs; the rule above is what stops that. To make it
  structural, the agent can push through a separate bot account that is not a reviewer of `release`.

### B.2 Repository settings (github.com/pabloguia/XCodeVault ▸ Settings)

- **Actions ▸ General ▸ Fork pull request workflows:** choose the strictest option, which requires approval
  for all outside collaborators.
- **Actions ▸ General ▸ Workflow permissions:** set read-only permissions for repository contents and
  packages, and untick "Allow GitHub Actions to create and approve pull requests".
- **Collaborators:** confirm that nobody else has write or admin access. Write access can change workflows;
  admin access can change everything below.

### B.3 The `release` environment

Go to Settings ▸ Environments ▸ New environment, and name it `release`.

- **Required reviewers:** your account. Leave **Prevent self-review** off: you push the tag and you approve it,
  and with it on a sole maintainer could never approve.
- If the page offers **Allow administrators to bypass configured protection rules**, untick it.
- **Deployment branches and tags:** choose "Selected branches and tags" ▸ add a rule ▸ ref type **Tag** ▸
  pattern `v*`. Add nothing else.
- **Environment variables.** These are not secrets; both values are public in every signed binary:
  - `APPLE_TEAM_ID` = your team ID;
  - `APPLE_SIGNING_IDENTITY` = the identity's **SHA-1 hash**, the 40 hex digits `security find-identity -v
    -p codesigning` prints before the name. `scripts/ci-sign-notarize.sh` refuses anything else, and refuses
    unless that hash is a `Developer ID Application: … (<TEAMID>)` identity.

  The team ID is also written in `release.yml` (`XCV_TEAM`), because the job that builds cannot read the
  environment's variables; the signing job refuses unless the two agree.

### B.4 The secrets

Run these in your own terminal, from `~/xcv-ci-secrets`. In the third, `XXXXXXXXXX` stands for your Key ID:
use the file's real name (`ls AuthKey_*.p8`). The values go from your files straight to GitHub;
never paste them into a chat. A command with no input redirected prompts for the value, which is neither shown
nor kept in the shell history.

```bash
base64 -i XCodeVault-CI.p12 | gh secret set MACOS_CERT_P12_BASE64 --env release --repo pabloguia/XCodeVault
gh secret set MACOS_CERT_P12_PASSWORD --env release --repo pabloguia/XCodeVault
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release --repo pabloguia/XCodeVault
gh secret set NOTARY_KEY_ID --env release --repo pabloguia/XCodeVault
gh secret set NOTARY_ISSUER_ID --env release --repo pabloguia/XCodeVault
```

Check with `gh secret list --env release --repo pabloguia/XCodeVault`. It shows the five names and never the
values. Then finish A.2 step 4 and A.3 step 4.

### B.5 Rulesets (Settings ▸ Rules ▸ Rulesets)

- **Tag ruleset `release tags`:**
  - target: tags matching `v*`;
  - enforcement: Active;
  - rules: Restrict creations, Restrict updates, Restrict deletions;
  - bypass list: Repository admin, which is you.

  Only you can then create, move or delete a `v*` tag.
- **Branch ruleset `main`:** target the default branch, with Restrict deletions and Block force pushes.
  Requiring pull requests is not needed for this, and would change how the agent pushes.

## Part C — Repository work

Written 2026-10-02, recorded in ADR-0010, which says what each piece checks and why. In short:

- **`.github/workflows/release.yml`** runs only on a pushed `v*` tag.
  - **`build`** sees no secret. It refuses a tag whose commit is not on `main` or that is not
    `v` + `ScanReport.current`. It runs the preflight and builds without the helper.
  - **`sign`** waits for your approval and is the only job the secrets reach. It builds nothing.
  - **`publish`** attests the DMG and makes a **draft** release.
- **`scripts/ci-sign-notarize.sh`** does the signing, notarization and checks inside `sign`.
- **`scripts/release-artifact-scan.sh`** refuses a bundle carrying the helper, a stray binary, a home path or
  an e-mail address.
- **`scripts/release-hygiene.sh`** (in CI and preflight) and **`scripts/test-release-hygiene.sh`** keep that
  shape from being undone in the tree. They read the workflows with a YAML parser; ADR-0010 lists what they
  do not catch.
- **`.gitignore`** lists the signing file types, and **`scripts/release.sh`** now refuses any identity that is
  not a Developer ID Application.

**Before the first tag**, check the settings this repository cannot enforce:

```bash
gh api repos/pabloguia/XCodeVault/environments/release --jq '{can_admins_bypass, rules: [.protection_rules[].type]}'
```

It must show `required_reviewers` among the rules and `can_admins_bypass: false`. On 2026-10-02 it showed only
`branch_policy`, with bypass on. Without that rule a tag signs with no one approving.

## Part D — Cutting a release, once Part C is in

1. With `main` green, bump `ScanReport.current` in `Sources/XCodeVaultCore/Scan/ScanReport.swift` in its own
   commit, and push it.
2. **You** create and push the tag; the agent does not.

   ```bash
   git tag -a v0.1.0 -m "XCodeVault 0.1.0"
   ```

   ```bash
   git push origin v0.1.0
   ```

3. Open GitHub ▸ Actions ▸ the Release run. When it waits at `sign`, check that the tag and the commit SHA it
   shows are the ones you meant. Then choose Review deployments ▸ `release` ▸ Approve.
4. When the run finishes, download the DMG from the draft release and check it on your Mac.
   - The checksum matches the published `.sha256`:

     ```bash
     shasum -a 256 XCodeVault-0.1.0.dmg
     ```

   - The provenance attestation says which workflow and commit built it:

     ```bash
     gh attestation verify XCodeVault-0.1.0.dmg --repo pabloguia/XCodeVault
     ```

   - The notarization ticket is stapled:

     ```bash
     xcrun stapler validate XCodeVault-0.1.0.dmg
     ```

   - The image passes Gatekeeper:

     ```bash
     spctl --assess --type open --context context:primary-signature -vv XCodeVault-0.1.0.dmg
     ```

   - Mount the image, then check the app inside. It must show `source=Notarized Developer ID` with your name
     and team:

     ```bash
     spctl --assess -vv /Volumes/XCodeVault/XCodeVault.app
     ```

5. Publish the draft release. Updating `packaging/homebrew/` (the real owner and the SHA-256) is a separate
   step.

## Part E — If a CI secret may have leaked

1. **Revoke the CI certificate:** developer.apple.com ▸ Certificates ▸ the CI Developer ID ▸ Revoke.
   - As reported on the Apple Developer Forums, not in Apple's documentation: apps already installed keep
     running, and new installations of builds signed with it stop passing Gatekeeper. Apple can also revoke
     the notarization of a single build.
   - Your own local certificate is not affected.
2. **Revoke the API key:** App Store Connect ▸ Integrations ▸ Team Keys ▸ Revoke.
3. **Clean up and check.** Delete the `release` environment's secrets. Check that the environment and the
   rulesets were not changed. Read Settings ▸ Security log and the runs that used `release`.
4. **Start again:** create new credentials (Part A) and release again.

## Sources

- Apple, [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/):
  up to five Developer ID Application certificates; the Account Holder role.
- Apple Developer Forums, [Which API key role to use for notarization?](https://developer.apple.com/forums/thread/133063):
  the Developer role is enough.
- Apple Developer Forums, [Certificate revocation impact](https://origin-devforums.apple.com/forums/thread/673516).
- GitHub Docs, [Managing environments for deployment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment):
  required reviewers, prevent self-review, deployment branches and tags, and availability in public
  repositories on every plan.
