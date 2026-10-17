#!/bin/bash
# Proves each refusal in scripts/release-hygiene.sh fires, and that the tree as committed passes.
# Every case runs on a scratch git copy of the workflows; the repository is only read.
#
# A case passes only when (1) its edit changed the copy — a mutation that matched nothing would otherwise
# "pass" by refusing nothing — and (2) the gate exits 1 with that case's code and no other code. Controls must
# exit 0. Cases marked "review" are the bypasses the helper-security review of 2026-10-02 reproduced against
# the gate's first, line-pattern version.
set -u -o pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$REPO/scripts/release-hygiene.sh"
WORK=$(mktemp -d -t xcv-hygiene)
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
R=.github/workflows/release.yml
C=.github/workflows/ci.yml

fresh() {
    rm -rf "$WORK/t"; mkdir -p "$WORK/t/.github/workflows"
    cp "$REPO"/.github/workflows/*.yml "$WORK/t/.github/workflows/"
    git -C "$WORK/t" init -q
}
snapshot() { (cd "$WORK/t" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum); }
# insert FILE ANCHOR TEXT: put TEXT before the first line that starts with ANCHOR; fail if there is none.
insert() { ANCHOR="$2" TEXT="$3" perl -0pi -e 'BEGIN { $a = $ENV{ANCHOR}; $t = $ENV{TEXT} } s/^\Q$a\E/$t$a/m or die "no anchor: $a\n"' "$1"; }
# swap FILE OLD NEW: replace the first literal OLD; fail if there is none.
swap() { OLD="$2" NEW="$3" perl -0pi -e 'BEGIN { $o = $ENV{OLD}; $n = $ENV{NEW} } s/\Q$o\E/$n/ or die "no match: $o\n"' "$1"; }

run_case() {   # name, expected code ("" for a control), edit run inside the copy
    local name="$1" code="$2" edit="$3" before out status codes
    fresh; before=$(snapshot)
    if ! (cd "$WORK/t" && eval "$edit") 2>"$WORK/edit.err"; then
        echo "FAIL  $name: the edit did not apply: $(cat "$WORK/edit.err")"; failed=$((failed + 1)); return
    fi
    if [ -n "$edit" ] && [ "$(snapshot)" = "$before" ]; then
        echo "FAIL  $name: the edit changed nothing"; failed=$((failed + 1)); return
    fi
    git -C "$WORK/t" add -A
    out=$(bash "$GATE" "$WORK/t" 2>&1); status=$?
    codes=$(printf '%s\n' "$out" | grep -oE 'release-hygiene: HYG[0-9]+ ' | sort -u | awk '{print $2}' | tr '\n' ' ')
    if [ -z "$code" ]; then
        if [ "$status" = 0 ]; then echo "ok    $name"; passed=$((passed + 1)); else echo "FAIL  $name: exit $status: $out"; failed=$((failed + 1)); fi
    elif [ "$status" = 1 ] && [ "$codes" = "$code " ]; then
        echo "ok    $name"; passed=$((passed + 1))
    else
        echo "FAIL  $name: wanted only $code, exit $status, codes [$codes]: $out"; failed=$((failed + 1))
    fi
}

NL=$'\n'
B_STEP='      - name: Toolchain'              # an anchor inside release.yml's build job
CI_JOB='    runs-on: ${{ matrix.os }}'        # an anchor inside ci.yml's only job

run_case "control: the committed workflows"              ""   ""
run_case "control: comment lines naming forbidden things" ""  "printf '# pull_request_target secrets.MACOS_CERT_P12_BASE64 --with-helper environment: release\n' >>$C"
run_case "HYG0 an anchor and alias"                       HYG0 "swap $R 'XCV_TEAM: 4V58BSZL3W' 'XCV_TEAM: &t 4V58BSZL3W${NL}  OTHER: *t'"
run_case "HYG0 review: two jobs keys, the first hiding one" HYG0 "printf 'jobs:\n  evil: {runs-on: x, environment: release, steps: []}\n' | cat - $C >$C.new && mv $C.new $C"
run_case "HYG0 review: a step env given twice"           HYG0 "insert $R '$B_STEP' '      - name: x${NL}        env: {X: \"\${{ secrets.NOTARY_KEY_ID }}\"}${NL}        env: {}${NL}        run: echo${NL}'"
run_case "HYG0 review: a merge key"                      HYG0 "insert $R '$B_STEP' '      - name: x${NL}        <<: {environment: release}${NL}        run: echo${NL}'"
run_case "HYG0 review: on in flow style, then true: clean" HYG0 "swap $R \"on:\${NL}  push:\${NL}    tags: ['v*']\" \"on: [push, workflow_dispatch]\${NL}true:\${NL}  push:\${NL}    tags: ['v*']\""
run_case "HYG0 review: On: beside on:"                   HYG0 "swap $R 'on:${NL}  push:' 'On: [workflow_dispatch]${NL}on:${NL}  push:'"
run_case "HYG0 a key given twice in two spellings"       HYG0 "swap $R '    if: github.repository' '    Permissions: {contents: write}${NL}    if: github.repository'"
run_case "HYG0 review: a quoted on before a plain one"   HYG0 "swap $R 'on:${NL}  push:' '\"on\": [push, workflow_dispatch]${NL}on:${NL}  push:'"
run_case "HYG0 review: a single-quoted on after it"     HYG0 "printf \"'on': [workflow_dispatch]\\n\" >>$R"
run_case "HYG0 review: permiſſions beside permissions"   HYG0 "swap $R '    if: github.repository' '    permiſſions: write-all${NL}    if: github.repository'"
run_case "HYG0 an unknown top-level key"                 HYG0 "printf 'extras: 1\n' >>$R"
run_case "HYG0 a second YAML document"                   HYG0 "printf -- '---\nfoo: 1\n' >>$C"
run_case "HYG1 a tracked .p12"                            HYG1 "touch id.p12"
run_case "HYG1 a tracked AuthKey .p8"                     HYG1 "mkdir -p x && touch x/AuthKey_ABC.p8"
run_case "HYG1 a tracked keychain"                        HYG1 "touch ci.keychain-db"
run_case "HYG2 release.yml missing"                       HYG2 "rm $R"
run_case "HYG3 pull_request_target"                       HYG3 "swap $C '  pull_request:' '  pull_request_target:'"
run_case "HYG3 pull_request_target in flow style"         HYG3 "swap $C '  pull_request:' '  pull_request_target: {}'"
run_case "HYG4 an action pinned by tag"                   HYG4 "perl -pi -e 's/upload-artifact\@[0-9a-f]+/upload-artifact\@v4/' $C"
run_case "HYG4 review: a flow-style step by tag"          HYG4 "insert $C '      - name: Toolchain' '      - {uses: actions/cache@v4}${NL}'"
run_case "HYG5 an environment in ci.yml"                  HYG5 "insert $C '$CI_JOB' '    environment: release${NL}'"
run_case "HYG5 review: a flow-style job with one"         HYG5 "printf '  evil: {runs-on: ubuntu-latest, environment: release, steps: [{run: echo}]}\n' >>$C"
run_case "HYG6 a signing secret in ci.yml"                HYG6 "insert $C '$CI_JOB' '    env: {X: \"\${{ secrets.MACOS_CERT_P12_PASSWORD }}\"}${NL}'"
run_case "HYG6 review: after a # in a quoted string"      HYG6 "insert $C '$CI_JOB' '    env:${NL}      X: \"a #\${{ secrets.MACOS_CERT_P12_PASSWORD }}\"${NL}'"
run_case "HYG6 secrets reached through toJSON"            HYG6 "insert $C '$CI_JOB' '    env: {X: \"\${{ toJSON(secrets) }}\"}${NL}'"
run_case "HYG6 review: toJSON( secrets ) with spaces"     HYG6 "insert $C '$CI_JOB' '    env: {X: \"\${{ toJSON( secrets ) }}\"}${NL}'"
run_case "HYG6 review: tojson in lower case"              HYG6 "insert $C '$CI_JOB' '    env: {X: \"\${{ tojson(secrets) }}\"}${NL}'"
run_case "HYG6 a secret in an if without \${{ }}"         HYG6 "insert $C '$CI_JOB' \"    if: secrets.NOTARY_KEY_ID != ''\${NL}\""
run_case "HYG7 workflow_dispatch"                         HYG7 "swap $R 'on:${NL}  push:' 'on:${NL}  workflow_dispatch:${NL}  push:'"
run_case "HYG7 review: flow-style triggers"               HYG7 "swap $R \"on:\${NL}  push:\${NL}    tags: ['v*']\" 'on: [push, workflow_dispatch]'"
run_case "HYG7 review: a push with no filter"             HYG7 "swap $R \"on:\${NL}  push:\${NL}    tags: ['v*']\" 'on: push'"
run_case "HYG7 a branch push"                             HYG7 "swap $R \"    tags: ['v*']\" \"    tags: ['v*']\${NL}    branches: [main]\""
run_case "HYG7 default permissions"                       HYG7 "swap $R 'permissions: {}' 'permissions: write-all'"
run_case "HYG7 review: a job granted more"                HYG7 "swap $R '    permissions:${NL}      contents: read' '    permissions:${NL}      contents: write${NL}      actions: write'"
run_case "HYG7 a fourth job"                              HYG7 "printf '  extra:\n    runs-on: ubuntu-latest\n    permissions: {}\n    steps: [{run: echo}]\n' >>$R"
run_case "HYG7 a reusable workflow call"                  HYG7 "swap $R '    runs-on: ubuntu-latest' '    uses: ./.github/workflows/ci.yml${NL}    runs-on: ubuntu-latest'"
run_case "HYG8 the helper left out"                       HYG8 "swap $R ' --with-helper --for-ci-signing' ''"
run_case "HYG8 the helper without the CI signing flag"     HYG8 "swap $R ' --for-ci-signing' ''"
run_case "HYG8 a second bundle-app.sh line"                HYG8 "swap $R '          git diff --exit-code' '          bash scripts/bundle-app.sh --release${NL}          git diff --exit-code'"
run_case "HYG9 a signing secret in the build job"         HYG9 "insert $R '$B_STEP' '      - name: x${NL}        env: {X: \"\${{ secrets.NOTARY_KEY_ID }}\"}${NL}        run: echo${NL}'"
# In a plain scalar ` #` really is a comment, to YAML and so to Actions; in a block scalar it is text.
run_case "HYG9 review: toJSON after a # in a run block"   HYG9 "insert $R '$B_STEP' '      - name: x${NL}        run: |${NL}          echo \" #\${{ toJSON(secrets) }}\"${NL}'"
run_case "HYG9 a signing secret in the workflow env"      HYG9 "swap $R '  XCV_TEAM: 4V58BSZL3W' '  XCV_TEAM: 4V58BSZL3W${NL}  K: \${{ secrets.NOTARY_KEY_ID }}'"
run_case "HYG9 an unknown secret in release.yml"          HYG9 "swap $R 'secrets.NOTARY_KEY_ID }}' 'secrets.SONAR_TOKEN }}'"
run_case "HYG9 an environment on the build job"           HYG9 "swap $R '    if: github.repository' '    environment: release${NL}    if: github.repository'"
run_case "HYG0 review: a quoted environment key"          HYG0 "swap $R '    if: github.repository' '    \"environment\": release${NL}    if: github.repository'"
run_case "HYG9 the sign job's environment renamed"        HYG9 "swap $R '    environment: release' '    environment: staging'"

# scripts/release-artifact-scan.sh, on a fake bundle: a tiny program built here, universal (arm64 + x86_64) as a
# release's binaries must be, stands in for each binary, so the Mach-O checks have real Mach-O files to classify.
# Not /bin/echo, which this used until the architecture check: it is x86_64 + arm64e, which the scan refuses.
# Each case must exit with the expected status, and a refusal must not print what it found (its output is a public
# log on CI).
printf 'int main(void) { return 0; }\n' >"$WORK/stand-in.c"
UNI="$WORK/stand-in-universal"; ARM="$WORK/stand-in-arm64"; X86="$WORK/stand-in-x86_64"
if clang -Os -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -o "$UNI" "$WORK/stand-in.c" \
    && lipo "$UNI" -thin arm64 -output "$ARM" && lipo "$UNI" -thin x86_64 -output "$X86"; then :; else
    echo "FAIL  scan: could not build the stand-in binaries"; failed=$((failed + 1))
fi
SCAN="$REPO/scripts/release-artifact-scan.sh"
PLIST="$REPO/Resources/LaunchDaemons/com.xcodevault.helper.plist"
# The bundle's helper parts: a stand-in binary and the tracked plist, as bundle-app.sh --with-helper lays them out.
WITH_HELPER="cp '$UNI' X.app/Contents/MacOS/xcodevault-helper && mkdir -p X.app/Contents/Library/LaunchDaemons && cp '$PLIST' X.app/Contents/Library/LaunchDaemons/"
scan_case() {   # name, expected refusal ("" for a control), edit run inside the bundle's parent, [expected plist, default none]
    # A refusal is pinned by its message, as the unpack cases below are: several of these bundles trip more than one rule.
    local name="$1" want="$2" edit="$3" expected="${4-}" out status
    rm -rf "$WORK/b"; mkdir -p "$WORK/b/X.app/Contents/MacOS" "$WORK/b/X.app/Contents/Resources"
    cp "$UNI" "$WORK/b/X.app/Contents/MacOS/XCodeVault"; cp "$UNI" "$WORK/b/X.app/Contents/MacOS/xcodevaultctl"
    printf '<plist/>\n' >"$WORK/b/X.app/Contents/Info.plist"
    (cd "$WORK/b" && eval "$edit")
    out=$(bash "$SCAN" "$WORK/b/X.app" $expected 2>&1); status=$?
    if [ -z "$want" ] && [ "$status" != 0 ]; then echo "FAIL  scan: $name: exit $status: $out"; failed=$((failed + 1))
    elif [ -n "$want" ] && { [ "$status" != 1 ] || ! printf '%s' "$out" | grep -qF "$want"; }; then
        echo "FAIL  scan: $name: wanted '$want', exit $status: $out"; failed=$((failed + 1))
    elif printf '%s' "$out" | grep -qE 'someone|jane@'; then echo "FAIL  scan: $name: printed what it found"; failed=$((failed + 1))
    else echo "ok    scan: $name"; passed=$((passed + 1)); fi
}
scan_case "control: a clean bundle"                ""  ""
scan_case "control: the runner's home"             ""  "printf '/Users/runner/work/x\n' >X.app/Contents/Resources/r.txt"
scan_case "control: the helper and the tracked plist" "" "$WITH_HELPER" "$PLIST"
scan_case "a person's home path"                   "names a home directory" "printf '/Users/someone/projects\n' >X.app/Contents/Resources/r.txt"
scan_case "an e-mail address"                      "shaped like an e-mail" "printf 'by jane@example.com\n' >X.app/Contents/Resources/r.txt"
scan_case "the helper without its plist"           "without its LaunchDaemons plist" "cp '$UNI' X.app/Contents/MacOS/xcodevault-helper"
scan_case "a LaunchDaemons folder without the helper" "without the helper" "mkdir -p X.app/Contents/Library/LaunchDaemons"
scan_case "a plist that is not the tracked one"    "differs from the tracked one" "$WITH_HELPER && printf ' ' >>X.app/Contents/Library/LaunchDaemons/com.xcodevault.helper.plist" "$PLIST"
scan_case "a second file beside the plist"         "something other than" "$WITH_HELPER && printf 'x' >X.app/Contents/Library/LaunchDaemons/other.plist" "$PLIST"
scan_case "the helper and no plist to compare with" "no expected plist" "$WITH_HELPER"
scan_case "a plist expected and no helper"           "carries no helper" "" "$PLIST"
scan_case "a stray Mach-O"                         "unexpected Mach-O" "cp '$UNI' X.app/Contents/Resources/tool"
scan_case "a symbolic link"                        "symbolic link" "ln -s /etc/hosts X.app/Contents/Resources/l"
# 0.3.0-rc.1: built on an Apple silicon runner, every binary arm64 only (2026-10-17).
scan_case "an arm64-only app binary"               "not exactly [arm64 x86_64]" "cp '$ARM' X.app/Contents/MacOS/XCodeVault"
scan_case "an x86_64-only CLI"                     "not exactly [arm64 x86_64]" "cp '$X86' X.app/Contents/MacOS/xcodevaultctl"
scan_case "an arm64-only helper"                   "not exactly [arm64 x86_64]" "$WITH_HELPER && cp '$ARM' X.app/Contents/MacOS/xcodevault-helper" "$PLIST"
scan_case "an arm64e slice, as /bin/echo has"      "not exactly [arm64 x86_64]" "cp /bin/echo X.app/Contents/MacOS/XCodeVault"

# scripts/ci-unpack-bundle.sh, on zips made with Python's zipfile so entries can be what ditto would never
# write. Each case must exit with the expected status, and a refusal must leave nothing outside DEST.
UNPACK="$REPO/scripts/ci-unpack-bundle.sh"
unpack_case() {   # name, expected refusal ("" for a control), python building $WORK/u/in.zip (zf is the open ZipFile)
    # The refusal is pinned by its message: the later checks also refuse most of these zips, which is how a
    # listing check that never ran still looked fine to a test that only read the exit status.
    local name="$1" want="$2" body="$3" status out
    rm -rf "$WORK/u"; mkdir -p "$WORK/u/sub"
    python3 - "$WORK/u/in.zip" <<PY || { echo "FAIL  unpack: $name: could not build the zip"; failed=$((failed + 1)); return; }
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1], "w")
def link(name, target):
    i = zipfile.ZipInfo(name); i.external_attr = (0o120777 << 16); zf.writestr(i, target)
$body
zf.close()
PY
    out=$(cd "$WORK/u/sub" && bash "$UNPACK" "$WORK/u/in.zip" "$WORK/u/sub/dest" 2>&1); status=$?
    if [ -z "$want" ] && [ "$status" != 0 ]; then echo "FAIL  unpack: $name: exit $status: $out"; failed=$((failed + 1))
    elif [ -n "$want" ] && { [ "$status" != 1 ] || ! printf '%s' "$out" | grep -qF "refusing: $want"; }; then
        echo "FAIL  unpack: $name: wanted '$want', exit $status: $out"; failed=$((failed + 1))
    elif [ -n "$(find "$WORK/u" -mindepth 1 -maxdepth 2 ! -path "$WORK/u/in.zip" ! -path "$WORK/u/sub" ! -path "$WORK/u/sub/dest")" ]; then
        echo "FAIL  unpack: $name: wrote outside DEST"; failed=$((failed + 1))
    else echo "ok    unpack: $name"; passed=$((passed + 1)); fi
}
CLEAN='zf.writestr("XCodeVault.app/Contents/Info.plist", "<plist/>")'
unpack_case "control: a bundle"                          "" "$CLEAN"
unpack_case "an entry outside the bundle"                "an entry is outside" "$CLEAN${NL}zf.writestr(\"other.txt\", \"x\")"
unpack_case "a .. entry"                                 "an entry climbs out" "$CLEAN${NL}zf.writestr(\"XCodeVault.app/../../esc.txt\", \"x\")"
unpack_case "review: a .. entry ahead of 3000 others"    "an entry climbs out" "zf.writestr(\"XCodeVault.app/../../esc.txt\", \"x\")${NL}[zf.writestr(\"XCodeVault.app/Contents/f%d\" % n, \"x\") for n in range(3000)]"
unpack_case "a symbolic link entry"                      "the zip holds a symbolic link" "$CLEAN${NL}link(\"XCodeVault.app/Contents/l\", \"/etc\")"
unpack_case "review: a link ahead of 3000 others"        "the zip holds a symbolic link" "link(\"XCodeVault.app/Contents/l\", \"/etc\")${NL}[zf.writestr(\"XCodeVault.app/Contents/f%d\" % n, \"x\") for n in range(3000)]"

echo "release-hygiene tests: $passed passed, $failed failed, $((passed + failed)) cases"
[ "$failed" = 0 ]
