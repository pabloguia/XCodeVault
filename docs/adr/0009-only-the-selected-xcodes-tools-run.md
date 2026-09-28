# ADR 0009: Only the selected Xcode's tools are run; a signature check is not the vetting step

- Status: accepted (2026-09-28)
- Date: 2026-09-28
- Related: H15 (a grant reaches the tools its holder starts); ADR-0007 (permissions at need). F3 of the
  helper-security review of deliverable 3 of the permissions plan, whose app half was fixed in that
  deliverable (`Scanner(detectXcodeCapabilities: false)`, `GrantedToolEnvironment`) and whose CLI half was
  declared open in STATUS.md.

## Context

`XcodeDiscovery.discover` lists every folder named `Xcode*.app` in /Applications and ~/Applications, plus the
one `xcode-select -p` names, and `inspect` accepts a folder whose Info.plist has a `CFBundleIdentifier`
starting with `com.apple.dt.Xcode`. With `detectCapabilities`, the default, it ran each folder's
`Contents/Developer/usr/bin/xcodebuild -help` by path, and `/usr/bin/xcrun simctl runtime` with `DEVELOPER_DIR`
pointing into the folder. It did so since M1 (23fc324, 2026-09-06), for every CLI command that discovers Xcodes
except `locations set-compilation-cache`, which has read only the version since M3. The `runtime` verbs used
the selected Xcode and, when none was selected, the first one found (since M2, d5be647).

Measured on 2026-09-28 on one machine: macOS 26.7 (25G229), x86_64, Xcode 26.5 (17F42) at /Applications.

- A folder `~/Applications/Xcode-x.app` holding an Info.plist and three shell scripts that only record that
  they ran, in a scratch home (`HOME` and `CFFIXED_USER_HOME` moved for that one process). `xcodevaultctl
  xcode list` ran its `xcodebuild -help`, and `/usr/bin/xcrun` handed `simctl runtime` to the folder's own
  `usr/bin/xcrun`. With no `xcrun` in the folder, only its `xcodebuild` ran.
- How `/usr/bin/xcrun` hands off, measured with scratch developer directories. It loads the directory's
  `usr/lib/libxcrun.dylib`. Only when there is no such file does it run the directory's `usr/bin/xcrun`, and
  with neither it refuses ("missing xcrun"). A library that fails to load stops it, with no fall back to
  `usr/bin/xcrun`. A planted library, empty or signed ad hoc, was refused, the ad hoc one with "mapping process
  is a platform binary, but mapped file is not": `/usr/bin/xcrun` loads only platform code. That is no defence,
  because Apple's own library is platform code anyone can copy. A copy of it in one planted folder refused
  ("unable to find Xcode installation"); in the review's, whose plists differed, it ran the folder's own
  `usr/bin/xcodebuild`, and tried to when there was none. Which plist content decides it was not established.
- ~/Applications can be written by any process of the user. /Applications is `root:admin`, mode `0775`.
- A terminal's Full Disk Access reaches the commands started from it (H15). So the folder's scripts ran
  inside that grant.
- `xcode-select -p` answers `DEVELOPER_DIR` when it is set (`/tmp/nowhere` came back as given, exit 0). It
  turns a path to an `.app` into its `Contents/Developer`. It echoes a trailing space as set, and `xcrun`
  refuses that path ("missing DEVELOPER_DIR path").

The review named two options.

**1. Check each bundle's code signature against an Apple-anchored requirement before running anything from
it.** Measured:
- The bundle's designated requirement (`codesign -d -r- /Applications/Xcode.app`) is not `anchor apple`. It is
  `anchor apple generic` with either the Mac App Store marker or Developer ID markers and
  `certificate leaf[subject.OU] = "59GAB85EFG"`, and `identifier "com.apple.dt.Xcode"`. Its code directory has
  `library-validation`, and its resources are sealed: `Sealed Resources version=2 rules=13 files=121000`.
- `usr/bin/xcodebuild` is signed on its own: `identifier "com.apple.dt.xcodebuild" and anchor apple`.
  `codesign --verify -R '=anchor apple'` on it exits 0 in under a tenth of a second. The same check naming a team
  it does not have exits 3.
- `usr/lib/libxcrun.dylib` is signed on its own: `identifier "com.apple.libxcrun" and anchor apple`.
- `usr/bin/simctl` is a 729-byte bash script, and `codesign -dv` says it "is not signed at all": only the
  bundle's resource seal covers it. `codesign --verify` of the whole bundle, run at background priority
  (`taskpolicy -b`) while the operator's test rigs were running, had not finished after 120 s and was killed.
  It was not timed at normal priority, and one file can be checked against the seal alone
  (`SecCodeValidateFileResource`, public since macOS 10.13). So cost is not what rules this option out.

What does:
- What will run cannot be listed before it runs. The `simctl` script runs `${DEVELOPER_DIR}/usr/bin/xcodebuild
  -runFirstLaunch` when the installed CoreSimulator is not the version it expects, and then runs the system's
  `simctl`. `xcrun` loads `libxcrun.dylib` from the developer directory, and Apple's genuine library, which
  passes any signature check, ran a planted folder's `xcodebuild` (above). `xcodebuild` loads
  `DVTSystemPrerequisites.framework` through `@rpath` entries that point into the bundle (`otool -l`).
- A file checked in a folder the user can write can be replaced before it runs.
- A signature says who built a bundle, not that the user chose it: a genuine, older Xcode, copied there as it
  is, passes every such check.

**2. Run the tools of the Xcode `xcode-select -p` names, and of no other.** That developer directory is the
one `xcrun`, and every developer tool the user runs, already resolves to. Running its tools runs nothing the
user's own commands do not. It is the boundary the app already draws (`GrantedToolEnvironment`), except that
the CLI keeps its caller's environment, so `DEVELOPER_DIR` steers it as it steers `xcrun`.

What the CLI needs from other Xcodes, by reading every caller:
- `RuntimeOperations` reads the capabilities of the Xcode it is given. The `runtime` verbs give it the
  selected one, or the first one found when none is selected; that fallback ran another bundle's tools too.
- `locations set-compilation-cache` reads only the version, from `discover(detectCapabilities: false)`.
- `xcode list` and the scan's text print the capabilities. Nothing else reads another Xcode's.

## Decision

- `XcodeDiscovery.inspect` runs `xcodebuild -help` and `xcrun simctl runtime` for the bundle whose developer
  directory is the one `xcode-select -p` answered, compared as strings, and for no other. Every other bundle is
  read (Info.plist and version.plist) and nothing in it is run.
- The answer is taken as printed, less the newline that ends it. Trimming more would select an Xcode that
  `xcrun` itself refuses, as with a trailing space.
- `XcodeInstallation.capabilitiesProbed` says whether the capabilities were measured: the Xcode is the selected
  one, and its `xcodebuild -help` ran. Every capability of an Xcode that was not probed reads `false`, so
  without the field "not probed" would read as "unsupported". `xcode list` says "capabilities not probed", and
  why, instead of the rows, and the scan's text flags it.
- The `runtime` verbs refuse when no Xcode is selected. The refusal counts the Xcodes found, prints none of
  their paths, and says how to select one: `xcode-select -s`, or `DEVELOPER_DIR`. A folder's name is chosen by
  whoever made the folder, and can hold a newline or a terminal escape; this text is printed right above advice
  to run `sudo`.
- No signature check, for the reasons above.

## Consequences

- A folder named `Xcode*.app` runs nothing unless the user selects it: with `xcode-select -s`, which needs an
  administrator, or with `DEVELOPER_DIR` in their own environment. That is the same choice that makes every
  developer tool run it. A bundle the user selected is trusted, planted or not. This does not defend against
  a user who is led to select one, or against anything that can already set the user's environment.
- The rule is enforced where an Xcode is chosen (`inspect`, `Runtime.selected`), not where tools are run.
  `RuntimeOperations` and `SimulatorDiscovery.runtimes(developerDir:)` accept any developer directory, and
  `inspect` is public. A new caller has to take its Xcode from the selection too.
- To see another Xcode's capabilities, select it for one command:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app xcodevaultctl xcode list`.
- With the Command Line Tools selected, no Xcode is probed and the `runtime` verbs refuse until one is
  selected. `doctor` already reports that state (`checkXcodeSelect`).
- The comparison is by string. When `xcode-select -p` spells the selected bundle through a symlink, the bundle
  is listed twice and only the spelling that matches is probed: measured with `DEVELOPER_DIR` under
  `/private/tmp` for a folder the search found under `/tmp`. Not fixed. If it is fixed by resolving paths, the
  tools must still be run at the path `xcode-select` printed, never at a candidate's: a symlink could change
  between the comparison and the run.
- A failure of `xcrun simctl runtime` alone, with `xcodebuild -help` run, still reads as ✗ on the `simctl`
  rows.
- Probed means `xcodebuild -help` ran, not that it succeeded: one that starts and then fails reads as probed,
  its flags parsed from whatever it printed. A healthy install's exits 0, as the review measured. This changes
  only what is displayed (`xcode list`, the scan's text, `--json`); a `runtime` verb whose flag reads `false`
  refuses.
- `xcode list`, `scan`, `status` and `report` print the paths of the Xcodes found as they are, a planted
  folder's included. That predates this change.
- `scripts/experiments/e8-feature-detect.sh` still runs the tools of every `/Applications/Xcode*.app`, or of
  the bundles named on its command line. It is the experiment that measures them. It is run by hand, and by CI
  on every push, without arguments, on runners that have no user's grant. Not changed.
- The app's scan detected no capabilities before this and still does not.
- `locations set-compilation-cache` still falls back to the first Xcode found when none is selected. It reads
  that Xcode's version and runs nothing from it.

## Evidence

- STATUS.md, 2026-09-28, "F3: the CLI runs only the selected Xcode's tools". It has the measurements above;
  the planted folder run with the CLI before and after the change; the control, in which the planted folder
  selected through `DEVELOPER_DIR` does run; and the `runtime` refusal.
- Tests: `XcodeCapabilityExecutionTests` (GrantedToolsTests.swift) and `CLIXcodeSelectionTests`.
