# ADR 0017: Releases are universal (arm64 + x86_64), and a bundle that is not is refused

- Status: accepted (2026-10-17); the first universal release build passed on CI the same day (Consequences)
- Date: 2026-10-17
- Related: ADR-0001 (minimum macOS 14.0), ADR-0010 and ADR-0016 (the CI release), `docs/process/RUNBOOK-M5-release-signing.md`.

## Context

The release candidate 0.3.0-rc.1 was signed, notarized and stapled correctly, and could not run on the Intel Mac this
project is developed on: Finder showed the app with the "cannot run" mark (operator, 2026-10-17). `lipo -archs` on its
three binaries — the app, `xcodevaultctl` and `xcodevault-helper` — said `arm64` for each.

The cause is in the build, not the signing. The release workflow runs on `macos-15`, an Apple silicon runner, and
`scripts/bundle-app.sh` ran `swift build -c release --product …` with no architecture, which builds for the host only.
Nothing in the pipeline asked which architectures a binary held, so every check that ran — `codesign`, Gatekeeper, the
artifact scan, the stapled tickets — passed a build that half the supported Macs cannot open. v0.2.2's draft was built
the same way. Earlier local bundles worked here only because they were built here, on Intel.

macOS 14 and later run on both Intel and Apple silicon Macs (ADR-0001 sets the floor by OS version, not by hardware),
and nothing in the product is specific to either.

## Decision

1. **A release is universal.** `bundle-app.sh --release` builds each product once per architecture, one `--arch` per
   `swift build` (a single `--arch` keeps SwiftPM's native build system; several switch it to XCBuild, which is a
   different build of the same package), and joins the slices with `lipo -create`. A debug bundle stays host-only: it
   is for the machine that built it, and building it twice would double the slowest step of local work.
2. **A release bundle that is not exactly arm64 + x86_64 is refused, twice.** `bundle-app.sh` refuses before signing if
   any binary in `Contents/MacOS` holds a different set. `scripts/release-artifact-scan.sh` refuses the same for each of
   the three Mach-O files it allows; the release workflow runs it on the unsigned bundle in `build`, and the `sign` job
   runs its own copy on the bundle it receives and on the one it signs. "Exactly" also refuses an extra slice, such as
   the `arm64e` that system binaries carry: what ships is what was built.
   The scan also refuses a bundle in which the app, the CLI or (when it ships) the helper is missing or is not a Mach-O
   file. Before, it checked only the Mach-O files it found, so a helper replaced by a shell script passed, and the
   `sign` job, which runs only the scan, would have signed it for launchd to run as root (helper-security review, L1;
   it predates this ADR).
3. **The `sign` job checks each slice.** `codesign -d` shows the host's slice only, arm64 on the runner, so
   `ci-sign-notarize.sh` checks the team, the Developer ID authority, the timestamp, the hardened runtime and the
   helper's identifier once per architecture (review, L2). `codesign --verify` already covers every slice.
4. `scripts/test-release-hygiene.sh` pins the scan's refusal with an arm64-only app, an x86_64-only CLI, an arm64-only
   helper and an `arm64e` slice, on stand-in binaries it builds with `clang`. With the check disabled, all four fail
   (mutation, 2026-10-17).

## Consequences

- The `build` job compiles the package twice in release, so it takes longer. Each slice is a full release compile.
- **Answered (2026-10-17, `v0.3.0-rc.2`, run 39080152043):** whether the x86_64 slice of `XCodeVaultCore` builds in
  release on CI, given that on this Intel Mac the release build of `XCodeVaultCore` spun at 100% CPU for about two hours
  and never finished (STATUS, 2026-10-05). It does: the universal `build` job took 14 minutes, as the arm64-only one had,
  and each slice of the app compiled in about 81 s. So the hang is in this Mac's build, its machine or its toolchain
  (Swift 6.3.2 here; the runner's Xcode differs), and is not cross-compilation to x86_64. The resulting DMG ran on this
  Intel Mac, and every slice of every binary carried the team, identifier and hardened runtime.
- The runbook's checks of a downloaded release now include `lipo -archs` on each binary.
- `scripts/release.sh`, the local release path, inherits the universal build through `bundle-app.sh --release`.
