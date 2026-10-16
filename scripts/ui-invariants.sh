#!/bin/bash
# The design system's source lint (docs/design/DESIGN_SYSTEM.md §5.1, R7-B): rules U1–U11 over the app's views, outside
# `Sources/XCodeVault/DesignSystem/`, where the components that may break them live.
#
# Why a lint: the user could not tell a status marker from a button (screenshot 17), and the cause was a capsule drawn
# ad hoc in a view. These rules keep that from coming back one view at a time. Each prints `file:line [Ux] why`.
#
#   scripts/ui-invariants.sh              # lint the tree; exits 1 on any violation
#   scripts/ui-invariants.sh --self-test  # inject one violation per rule into a copy; every rule must catch its own
#
# Every rule's output is captured before it is searched: `lint | grep -q` would report a miss whenever grep's early exit
# made `lint` fail under pipefail — every rule looked missed the first time this self-test ran.
#
# Measured with /usr/bin/grep and awk, never the agent shell's grep (ugrep), whose regex dialect differs.
set -u -o pipefail
cd "$(dirname "$0")/.."

GREP=/usr/bin/grep

lint() {  # lint <root>: prints violations, returns their count (capped at 255)
    local root="$1" n=0
    local app="$root/Sources/XCodeVault"
    # An array, so a path with a space stays one argument (A+B review M8).
    local files=() f
    while IFS= read -r f; do files+=("$f"); done < <(find "$app" -name '*.swift' -not -path "$app/DesignSystem/*" | sort)
    report() { echo "$1"; n=$((n + 1)); }

    # U1 No capsule containers outside the design system: only FilterChip is a capsule (§2.3).
    local u1='in: Capsule\(\)|Capsule\(\)\.(fill|stroke|strokeBorder)|'
    u1+='clipShape\(Capsule\(\)\)|(background|overlay)\( *Capsule\(\)'
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U1] capsule container outside DesignSystem/ (only FilterChipStyle is a capsule)"; done \
        < <($GREP -nE "$u1" "${files[@]}" /dev/null)
    # U2 No button-styled toggles: filters use FilterChipStyle (§3.3).
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U2] .toggleStyle(.button): use FilterChipStyle"; done \
        < <($GREP -nE '\.toggleStyle\(\.button\)' "${files[@]}" /dev/null)
    # U3 No ad-hoc status tints: StatusIcon / StatusLabel own the symbol–tint pairs (§3.4).
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U3] ad-hoc status tint: use StatusIcon/StatusLabel or a Tokens color"; done \
        < <($GREP -nE '(foregroundStyle|foregroundColor|tint)\(\.(red|orange|green)\b|Color\.(red|orange|green)\b' "${files[@]}" /dev/null)
    # U4 Filled warning symbols only: one warning glyph app-wide.
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U4] outline warning triangle: use StatusIcon(.warning)"; done \
        < <($GREP -nE '"exclamationmark\.triangle"' "${files[@]}" /dev/null)
    # U5 No truncation in charts: every label in full (§3.8).
    if [ -f "$app/Views/ChartViews.swift" ]; then
        while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U5] truncation in a chart"; done \
            < <($GREP -nE 'lineLimit|truncationMode' "$app/Views/ChartViews.swift" /dev/null)
    fi
    # U6 No retired badge types: one Tag type (§3.2).
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U6] retired badge type: use Tag"; done \
        < <($GREP -nE '(MarkerBadges|HistoryKindBadge)\(' "${files[@]}" /dev/null)
    # U7 One prominent button per view body (§1.2). A literal `.borderedProminent` or `actionButton(prominent: true)`
    # counted per `struct … : View`. A per-row prominent decided by a function (each drive row's recommended option,
    # ruling B-1) is `actionButton(prominent: <expression>)` and not counted here: `DriveAssessment.isRecommended` and
    # The Drives row reads one value, `DriveAssessment.primaryAction`, which `DesignSystemTests` also reads. Nested view
    # types start their own count.
    # Known limit: a view's body written in an `extension` is counted with whatever struct precedes it.
    for f in "${files[@]}"; do
        while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U7] more than one prominent button in one view"; done < <(awk -v F="$f" '
            /^[[:space:]]*((private|fileprivate) )?struct [A-Za-z0-9_]+.*: *View/ { if (count > 1) print F ":" line ": " name; name=$0; count=0; line=NR }
            { count += gsub(/\.borderedProminent|actionButton\(prominent: *true\)/, "&") }
            END { if (count > 1) print F ":" line ": " name }' "$f")
    done
    # U8 No custom disabled look: `.disabled(_:)` only (§3.1).
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U8] custom disabled look: use .disabled(_:)"; done \
        < <($GREP -nE '\.opacity\(.*(isEnabled|disabled)' "${files[@]}" /dev/null)
    # U9 A sheet's Cancel binds Escape: `.cancelAction`, or — Cancel the default in a destructive review (ruling B-2) —
    # `.defaultAction` with the sheet's `.onExitCommand` closing it.
    for f in "$app/Views/OperationSheetView.swift" "$app/XCodeVaultApp.swift"; do
        [ -f "$f" ] || continue
        local exits=0
        $GREP -qE '^[[:space:]]*\.onExitCommand \{' "$f" && exits=1
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            case "$hit" in
                *".cancelAction"*) ;;
                *".defaultAction"*) [ "$exits" = 1 ] || report "$f:$hit [U9] Cancel is the default but nothing binds Escape (.onExitCommand)" ;;
                *) report "$f:$hit [U9] sheet Cancel without .cancelAction" ;;
            esac
        done < <($GREP -nE 'Button\(L10n\.tr\("app\.action\.cancel"\)' "$f")
    done
    # U10 Buttons in List and Form rows are styled: the automatic style there is a grey fill that reads like a tag (17).
    # A `Button(` must be styled on its line or the next two (`.actionButton(` or `.buttonStyle(`), unless the line says
    # `// U10: dialog` (a confirmationDialog's buttons are the system's). Both `Button(` and the trailing-closure `Button {`.
    for f in "$app/Views/DrivesViews.swift" "$app/Views/AccessView.swift"; do
        [ -f "$f" ] || continue
        while IFS= read -r hit; do [ -n "$hit" ] && report "$f:$hit [U10] unstyled button in a list row: add .actionButton()"; done < <(awk '
            { lines[NR] = $0 }
            END {
                for (i = 1; i <= NR; i++) {
                    if (lines[i] !~ /(^|[^A-Za-z])Button *[({]/ || lines[i] ~ /U10: dialog/) continue
                    ok = 0
                    for (j = i; j <= i + 2 && j <= NR; j++) {
                        if (j > i && lines[j] ~ /(^|[^A-Za-z])Button *[({]/) break
                        if (lines[j] ~ /\.actionButton\(|\.buttonStyle\(/) { ok = 1; break }
                    }
                    if (!ok) print i ": " lines[i]
                }
            }' "$f")
    done
    # U11 A destructive bordered button is `DestructiveButton` (A+B review M3): its danger symbol and never red text. A
    # dialog's own destructive buttons and a context menu's are plain `Button(…, role: .destructive)`, unstyled.
    while IFS= read -r hit; do [ -n "$hit" ] && report "$hit [U11] bordered destructive button: use DestructiveButton"; done \
        < <($GREP -nE 'role: \.destructive.*\.(actionButton|buttonStyle)\(' "${files[@]}" /dev/null)
    return $((n > 255 ? 255 : n))
}

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d -t xcv-ui-invariants)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/Sources"
    cp -R Sources/XCodeVault "$tmp/Sources/"
    lint "$tmp" >/dev/null || { echo "ui-invariants self-test: the clean copy already fails" >&2; exit 1; }
    v="$tmp/Sources/XCodeVault/Views"
    inject() {  # inject <rule> <file> <line of Swift>
        local rule="$1" file="$2" text="$3"
        cp "$file" "$file.orig"
        printf '%s\n' "$text" >>"$file"
        local out
        out=$(lint "$tmp")
        if printf '%s\n' "$out" | $GREP -q "\[$rule\]"; then echo "  $rule caught"; else echo "  $rule MISSED" >&2; failed=1; fi
        mv "$file.orig" "$file"
    }
    failed=0
    inject U1 "$v/DetailViews.swift" '        let x = Text("a").background(.quaternary, in: Capsule())'
    inject U1 "$v/DetailViews.swift" '        let x = Text("a").clipShape(Capsule())'
    inject U1 "$v/DetailViews.swift" '        let x = Text("a").background(Capsule().fill(.gray))'
    inject U2 "$v/DetailViews.swift" '        let x = Toggle("a", isOn: .constant(true)).toggleStyle(.button)'
    inject U3 "$v/DetailViews.swift" '        let x = Image(systemName: "a").foregroundStyle(.red)'
    inject U3 "$v/DetailViews.swift" '        let x = Button("a") {}.tint(.red)'
    inject U3 "$v/DetailViews.swift" '        let x = Text("a").foregroundColor(.orange)'
    inject U4 "$v/DetailViews.swift" '        let x = Image(systemName: "exclamationmark.triangle")'
    inject U5 "$v/ChartViews.swift" '        let x = Text("a").lineLimit(1)'
    inject U6 "$v/DetailViews.swift" '        let x = MarkerBadges(markers: [])'
    twice='HStack { Button("a") {}.buttonStyle(.borderedProminent); Button("b") {}.buttonStyle(.borderedProminent) }'
    inject U7 "$v/DetailViews.swift" "    private struct NestedTwice: View { var body: some View { $twice } }"
    inject U7 "$v/DetailViews.swift" "struct Twice: View { var body: some View { $twice } }"
    inject U8 "$v/DetailViews.swift" '        let x = Text("a").opacity(isEnabled ? 1 : 0.4)'
    cp "$v/OperationSheetView.swift" "$v/OperationSheetView.swift.orig"
    /usr/bin/sed -i '' 's/\.onExitCommand {/.removedExitCommand {/' "$v/OperationSheetView.swift"
    out=$(lint "$tmp")
    if printf '%s\n' "$out" | $GREP -q '\[U9\]'; then echo "  U9 caught"; else echo "  U9 MISSED" >&2; failed=1; fi
    mv "$v/OperationSheetView.swift.orig" "$v/OperationSheetView.swift"
    inject U10 "$v/DrivesViews.swift" '        let x = Button("a") { }'
    inject U10 "$v/DrivesViews.swift" '        let x = Button { } label: { Text("a") }'
    inject U11 "$v/DetailViews.swift" '        let x = Button("a", role: .destructive) {}.actionButton()'
    [ "$failed" = 0 ] && echo "ui-invariants self-test: ok (11 rules, 17 injections)" || exit 1
    exit 0
fi

out=$(lint .)
count=$?
if [ "$count" -ne 0 ]; then
    echo "$out"
    echo "ui-invariants: $count violation(s) of docs/design/DESIGN_SYSTEM.md §5.1" >&2
    exit 1
fi
echo "ui-invariants: ok (U1–U11)"
