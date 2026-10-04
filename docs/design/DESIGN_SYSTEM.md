# XCodeVault design system (controls and status)

Status: **implemented in R7-B** (2026-10-04), with the controller's rulings (`.superpowers/sdd/r7/rulings.md`, B-1 to
B-4) folded in below; where this text and a ruling differed, the ruling won and the text now says so. Scope: the SwiftUI app (`Sources/XCodeVault`), macOS 14+. It does not replace
`docs/brand/BRAND.md` (logo, palette, bucket tokens); it builds on it. The CLI is out of scope.

Why it exists: in a real window the user could not tell a status marker from a button (Drives, screenshot
`.superpowers/sdd/r7/17.webp`: the **Experimental** capsule sits next to the **Add an APFS volume…** button with the same
grey rounded fill). The rule that fixes it, in one line: **only things you can click look clickable, and everything that
looks clickable is.**

---

## 0. Sources

Apple first; the market systems are used where Apple is silent (tags vs chips) and to confirm a rule is consensus.

*Note (ruling B-4):* the fetch of the Apple HIG, Material 3 and Atlassian pages failed while this was written; those three
are cited from prior knowledge of the pages linked below. That is acceptable for a style guide; check a link before
quoting it as current.

| Topic | Source |
| --- | --- |
| Buttons, default/destructive, ellipsis | HIG Buttons — https://developer.apple.com/design/human-interface-guidelines/buttons |
| Toggles (checkbox, switch, button-style toggle) | HIG Toggles — https://developer.apple.com/design/human-interface-guidelines/toggles |
| Pop-up buttons | HIG Pop-up buttons — https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons |
| Labels (non-interactive text) | HIG Labels — https://developer.apple.com/design/human-interface-guidelines/labels |
| Color (semantic, never alone) | HIG Color — https://developer.apple.com/design/human-interface-guidelines/color |
| Typography (text styles) | HIG Typography — https://developer.apple.com/design/human-interface-guidelines/typography |
| Layout | HIG Layout — https://developer.apple.com/design/human-interface-guidelines/layout |
| Accessibility | HIG Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility |
| Sheets | HIG Sheets — https://developer.apple.com/design/human-interface-guidelines/sheets |
| Alerts / confirmations | HIG Alerts — https://developer.apple.com/design/human-interface-guidelines/alerts |
| SF Symbols | HIG SF Symbols — https://developer.apple.com/design/human-interface-guidelines/sf-symbols |
| `.bordered` / `.borderedProminent` / `.borderless` / `.plain` / `.link` | https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/bordered · …/borderedprominent · …/borderless · …/plain · …/link |
| `controlSize` | https://developer.apple.com/documentation/swiftui/view/controlsize(_:) |
| `ButtonRole.destructive` | https://developer.apple.com/documentation/swiftui/buttonrole/destructive |
| `.defaultAction` / `.cancelAction` | https://developer.apple.com/documentation/swiftui/keyboardshortcut/defaultaction · …/cancelaction |
| `.disabled(_:)` | https://developer.apple.com/documentation/swiftui/view/disabled(_:) |
| `confirmationDialog` | https://developer.apple.com/documentation/swiftui/view/confirmationdialog(_:ispresented:titlevisibility:actions:message:) |
| Fluent 2 Badge (non-focusable status) | https://fluent2.microsoft.design/components/web/react/core/badge/usage |
| Fluent 2 Tag / Button | https://fluent2.microsoft.design/components/web/react/core/tag/usage · https://fluent2.microsoft.design/components/web/react/core/button/usage |
| Material 3 Chips (filter chip = selectable, checkmark) | https://m3.material.io/components/chips/guidelines |
| Material 3 Badges / Buttons / states | https://m3.material.io/components/badges/guidelines · https://m3.material.io/components/buttons/guidelines · https://m3.material.io/foundations/interaction/states/overview |
| IBM Carbon Tag (read-only vs selectable vs dismissible) | https://carbondesignsystem.com/components/tag/usage/ |
| IBM Carbon Button | https://carbondesignsystem.com/components/button/usage/ |
| GitHub Primer Label (metadata, not an action) | https://primer.style/product/components/label/ |
| GitHub Primer Button | https://primer.style/product/components/button/ |
| Atlassian Lozenge (status) / Tag / Button | https://atlassian.design/components/lozenge · https://atlassian.design/components/tag · https://atlassian.design/components/button |
| WCAG 2.2 1.4.1 Use of Color | https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html |
| WCAG 2.2 1.4.3 Contrast (Minimum) | https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html |
| WCAG 2.2 1.4.11 Non-text Contrast | https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html |
| WCAG 2.2 2.5.8 Target Size (Minimum) | https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html |

What the market systems agree on (the basis for §3):

- **Status markers are not controls.** Carbon: read-only tags "are not clickable and can not be interacted with".
  Fluent: badges "don't receive focus" by default. Primer: a Label is "contextual metadata". Atlassian splits status
  (Lozenge) from Tag and from Button. None of them give a status marker a button's container.
- **A selectable token is its own component** with a visible selected state: Carbon's selectable tag, Material 3's filter
  chip (leading checkmark when selected), Fluent's interactive tag. It is never a button and never a status badge.
- **Disabled controls are exempt from contrast** (WCAG 1.4.11, "inactive user interface components"), so the dimmed look
  alone is a weak signal: say *why* in text.
- **Targets:** at least 24×24 pt, or enough spacing that a 24-pt circle on each does not overlap a neighbour (WCAG 2.5.8).
- **Never color alone** (WCAG 1.4.1, HIG Color): every state is a symbol and a word.

---

## 1. Principles

1. **Affordance is binary.** A container (bordered fill, capsule, stroke) means "clickable". Non-interactive things —
   status, metadata, markers — are a symbol and text on the background, nothing behind them. No hover state, no pointing
   hand, not focusable.
2. **One primary action per surface.** A sheet has one default button (`.defaultAction`); a view body has at most one
   `.borderedProminent`. A list of independent objects (each drive in Drives) may give *each object row* one prominent
   button, never two in a row (ruling B-1: each row is its own surface, and the recommended fix is that row's primary).
   Destructive actions are never the default.
3. **Never color alone.** Status = SF Symbol (tinted) + word (`.primary`/`.secondary`). Text is never red, orange or
   green; bucket colors are fills and symbol tints only (BRAND.md).
4. **Native first.** Use the system styles (`.bordered`, `.borderedProminent`, `.link`, `Toggle(.checkbox)`,
   `Picker(.menu)`, `confirmationDialog`, `GroupBox`, `Form(.grouped)`) and system colors. Write a custom style only where
   AppKit has no equivalent — in this spec, that is exactly two: **Tag** and **FilterChip**. Every custom component lives in
   one folder (`Sources/XCodeVault/DesignSystem/`) so a lint can find violations elsewhere.
5. **Disabled says why.** A disabled control is shown (not hidden) when the user can do something to enable it, and the
   reason is visible text next to it. A control that can never work in this build is not shown (project rule; HIG
   "don't show controls people can't use").

---

## 2. Tokens

Put them in `Sources/XCodeVault/DesignSystem/Tokens.swift`; views reference the names, not literals.

### 2.1 Semantic colors

| Token | Value | Use |
| --- | --- | --- |
| `text.primary` | `.primary` | Body text, status words, titles |
| `text.secondary` | `.secondary` | Facts, explanations, tags, captions |
| `status.success` | `Color.green` (system) | Success symbol tint only |
| `status.warning` | `Color.orange` (system) | Warning symbol tint only |
| `status.blocker` | `Color.red` (system) | Blocker / failure symbol tint only |
| `status.danger` | `Color.red` (system) | "This will destroy…" consequence symbol only |
| `status.info` | `Color.accentColor` | Info symbol in banners |
| `status.neutral` | `.secondary` | Not-an-error states (boot volume, "Off", not qualifying) |
| `bucket.*` | `SavingsBucket.color` (BRAND.md, appearance- and contrast-aware) | Fills, card stripes, bar segments, bucket symbol tint |
| `sim.runtime` / `sim.device` | `Color.indigo` / `Color.teal` (system; BRAND.md) | Simulators chart only |
| `surface.card` | `NSColor.controlBackgroundColor` | Cards, plan rows |
| `surface.code` | `NSColor.textBackgroundColor` | Log, code blocks |
| `stroke.hairline` | `NSColor.separatorColor` | Card and bar outlines (decorative) |
| `stroke.chip` | `Color.secondary` | FilterChip outline (the only boundary that identifies it, so ≥ 3:1, WCAG 1.4.11) |
| `fill.chipSelected` | `Color.accentColor.opacity(0.18)` + `accentColor` stroke | Selected FilterChip |

No new hex values. Bucket tokens stay as BRAND.md defines them.

### 2.2 Spacing (pt, 4-pt grid)

| Token | Value | Use |
| --- | --- | --- |
| `Spacing.xxs` | 2 | Symbol-to-text inside a tag |
| `Spacing.xs` | 4 | Inside chips and labels; between lines of one row |
| `Spacing.s` | 8 | Between controls in a row; between rows of a group |
| `Spacing.m` | 12 | Between groups inside a card or sheet; Grid column gap |
| `Spacing.l` | 16 | View padding (`.padding()` default); card padding |
| `Spacing.xl` | 20 | Sheet padding |
| `Spacing.xxl` | 24 | Between major sections |

### 2.3 Corner radii

| Token | Value | Use |
| --- | --- | --- |
| controls | system | Never set a radius on a `Button`; the style owns it |
| `Radius.card` | 8 | Overview cards, plan rows, health cards (unify today's 8 and 10) |
| `Radius.code` | 4 | Log and code backgrounds |
| `Radius.bar` | 5 | Disk bar |
| `Radius.swatch` | 2 | Legend swatch, card stripe |
| chip | `Capsule()` | FilterChip only. **No other component uses a capsule.** |

### 2.4 Type scale (semantic text styles only; no point sizes)

| Style | Use |
| --- | --- |
| `.title2` bold, `.monospacedDigit()` | The headline amount on an Overview card |
| `.title3` | Bucket symbol in headers |
| `.headline` | Section titles, row names (drive, permission), sheet title |
| `.body` | Default; table cells; chart axis labels (full, never truncated) |
| `.callout` | Facts, verdict lines, notice text, sheet content |
| `.caption` | Tags, chart value annotations, metadata |
| `.footnote` | Disabled reasons in footers, view footers |
| `.system(.callout, design: .monospaced)` | Commands and paths (selectable) |

`.caption2` is not used. All sizes use `.monospacedDigit()`. Case: buttons and menu items **Title Case**; labels, tags,
toggles, captions sentence case (HIG Writing; the earlier review's X5).

---

## 3. Components

Each component has one SwiftUI type in `Sources/XCodeVault/DesignSystem/`. Views use the type, not a re-implementation.

### 3.1 Button

| Kind | Recipe | Where |
| --- | --- | --- |
| **Primary** | `Button(t) {…}.keyboardShortcut(.defaultAction)` in a sheet/dialog (macOS draws the default button in the accent color); elsewhere `.buttonStyle(.borderedProminent)` | One per surface (§1.2) |
| **Secondary** | `.buttonStyle(.bordered)` (explicit) | Every other action in content, rows, cards |
| **Destructive** | `Button(t, role: .destructive) {…}.buttonStyle(.bordered)`; never `.defaultAction`; title names the destruction ("Delete 12 Items…", "Erase PABLO…") | Footer or row; always opens a confirmation (§3.6) |
| **Tertiary / link** | `.buttonStyle(.link)` for navigation inside text ("Show in Health"); `.borderless` + icon-only + `.help` for small inline affordances (dismiss ×) | Inline |
| **Cancel** | `Button(L10n.tr("app.action.cancel"), role: .cancel) {…}.keyboardShortcut(.cancelAction)` | Sheets, always Escape |

Rules:

- Title is a verb (+ object), Title Case, ≤ ~30 characters. An ellipsis (…) only when the button opens more UI before
  acting (a sheet, a confirmation). Paths, sizes and names go in the content, not the button (screenshot 20's
  "Point Archives at /Volumes/PABLO/XCodeVault/Archives" breaks this).
- `controlSize`: `.regular` by default; `.small` only for secondary buttons inside dense rows (Copy Command, table-row
  actions). Never `.small` on a primary.
- In `List`/`Form` rows, set `.buttonStyle(.bordered)` explicitly: the automatic style there renders as a grey fill that is
  indistinguishable from a tag (the root cause of screenshot 17).
- Icon-only buttons have `.help(…)` and `.accessibilityLabel(…)` and a hit area ≥ 24×24 pt
  (`.frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())`, WCAG 2.5.8).

**Disabled.** Use `.disabled(_:)` only — never a custom opacity or grey tint, so the system appearance and the
accessibility "dimmed" trait stay consistent. The reason is **visible text** adjacent to the control: in a sheet, the
footer's leading footnote (§3.7); in a row, a `.footnote .secondary` line under the button. `.help` may repeat it but is
never the only carrier: tooltips are not discoverable, are not read on focus by every assistive setup, and are unreliable
on disabled controls in SwiftUI on macOS (community-reported; attach any tooltip to the containing row, not the disabled
button). The reason comes from a tested function (e.g. `AppModel.blockerText`), never from view logic.

Do:
- `Button("Use Drive") {…}.buttonStyle(.bordered)` in a drive row.
- A checkbox gate ("I understand unit tests may fail…") that enables the primary, with the footnote saying so (screenshot
  19 does this right).

Don't:
- Put a tag and buttons in one `HStack` that reads as a button group.
- Use `.toggleStyle(.button)` for filters (it renders as a button, and the "on" state as a prominent button).
- Show two prominent buttons in one view, or make a destructive button the default.

### 3.2 Tag (non-interactive status / marker)

Replaces `MarkerBadges` and `HistoryKindBadge`. One type: `Tag`.

```swift
/// Metadata about a row, sheet or drive. Not a control: no container, no hover, no pointer, not focusable.
struct Tag: View {
    let text: String          // L10n.tr(...) already resolved
    let symbol: String        // SF Symbol name
    var tint: Color? = nil    // symbol tint only (status.* or bucket color); text stays secondary
    var help: String? = nil

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? .secondary)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .help(help ?? text)
    }
}
extension Tag {
    static func marker(_ m: SavingsMarker) -> Tag { /* text AppText.marker(m), symbol MarkerBadges.symbol(m); .losesUserData tinted status.warning */ }
    static func historyKind(_ k: JournalTimeline.Kind) -> Tag { /* symbol k.symbolName, tint k.color */ }
}
```

Rules:
- **No background, no stroke, no capsule, no padding box.** Not `.onHover`, not `NSCursor`, not `.focusable`, never wrapped
  in a `Button` or `onTapGesture`.
- Placement: after the thing it qualifies, on the same baseline (sheet title, row name) — or on its own line under it. Never
  in the same `HStack` as buttons; if a row has both, the tag line comes first and the button line second.
- Experimental (rule 10) is always `Tag.marker(.experimental)`: text "Experimental", symbol `flask`. It stays everywhere it
  is today; only its look changes.

Do: `HStack { Text(title).font(.headline); Tag.marker(.experimental) }`.
Don't: `.background(…, in: Capsule())` on any Label/Text; a tinted capsule for a table cell value (HistoryKindBadge today).

### 3.3 FilterChip (toggleable filter)

The Storage legend (and any future multi-select filter). Distinct from a button (capsule, outline, checkmark) and from a tag
(it has a container and a selected state).

```swift
struct FilterChipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { FilterChip(configuration: configuration) }
}

private struct FilterChip: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark")
                    .opacity(configuration.isOn ? 1 : 0)       // reserves width: no layout jump
                    .accessibilityHidden(true)
                configuration.label
            }
            .font(.callout)
            .padding(.horizontal, Spacing.s + 2)
            .frame(minHeight: 24)                              // WCAG 2.5.8
            .background(configuration.isOn ? Tokens.chipSelectedFill : (hovering ? Color.primary.opacity(0.06) : .clear),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(configuration.isOn ? Color.accentColor : Tokens.chipStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && isEnabled }
        .accessibilityAddTraits(.isToggle)                     // macOS 14
        .accessibilityValue(Text(verbatim: configuration.isOn ? L10n.tr("app.a11y.on") : L10n.tr("app.a11y.off")))
    }
}
```

Rules:
- Use with `Toggle(isOn:) { Label… }.toggleStyle(FilterChipStyle())`. The label is the bucket symbol (bucket tint), short
  name and size.
- Selected = checkmark + accent outline + light accent fill. Never a solid accent fill (that is the prominent button).
- A chip row is followed, when any chip is on, by exactly one **Show All** button (`.bordered`, `.small`). No second
  "clear" affordance (today there is an × in a capsule *and* Show All).
- The filter summary ("Filtering: Keep") is plain `.callout .secondary` text with the filter symbol — no capsule.

### 3.4 Status label

`StatusLabel(kind:text:)` = `Label { Text(text) } icon: { StatusIcon(kind) }`; the text is `.primary` (or `.secondary` for
neutral); only the symbol is tinted.

| Kind | Symbol | Tint | Example |
| --- | --- | --- | --- |
| success | `checkmark.circle.fill` | `status.success` | "Ready — a vault" |
| warning | `exclamationmark.triangle.fill` | `status.warning` | "Vault: Ready, with warnings" |
| blocker | `xmark.octagon.fill` | `status.blocker` | "Erasing is blocked: this disk holds a vault" |
| danger | `exclamationmark.triangle.fill` | `status.danger` | "These volumes will be erased" |
| info | `info.circle.fill` | `status.info` | Feedback banner |
| neutral | `circle.dashed` / `minus.circle` | `status.neutral` | "Boot volume", FDA "Off" |

Rules: always the filled variant (today warnings mix `exclamationmark.triangle` and `.fill`). The symbol is
`accessibilityHidden(true)` because the word says it. Severity words are sentence/title case, never ALL CAPS.

### 3.5 Notice rows (warning, blocker, success, info)

`NoticeRow(kind:title:detail:actions:)`:

```swift
VStack(alignment: .leading, spacing: Spacing.xs) {
    StatusLabel(kind: kind, text: title).font(.callout).bold(detail != nil)
    if let detail { InlineCodeText(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    if hasActions { HStack(spacing: Spacing.s) { actions }.buttonStyle(.bordered).controlSize(.small).padding(.leading, 28) }
}
```

Rules:
- Text wraps (`fixedSize(horizontal: false, vertical: true)`), never `lineLimit`; commands inside are monospaced and
  selectable with a Copy button.
- Wrap in `GroupBox` only when the notice has actions or several lines (Interrupted migrations, "will erase" list);
  single-line notices are bare `StatusLabel`s.
- Several warnings of the same kind fold behind a `DisclosureGroup("2 Warnings")` (Drives already does) — but a sheet's
  warnings that gate a decision are never folded or clipped.
- Hypothesis/experiment IDs ("E2, reproduced", "E6 pending") do not appear in notice text (earlier review X1); they belong
  in the docs.

### 3.6 Destructive confirmation

- Trigger: a destructive button (`role: .destructive`, title ends in "…").
- Container: `confirmationDialog` for a single decision; inside an operation sheet, the sheet's review state is the
  confirmation (do not chain a dialog on top unless a second destructive step follows, e.g. Remove Original).
- Title: a question naming object and count: "Move 12 items (3.4 GB) to the Trash?".
- Message: consequence and recoverability in ≤ 2 sentences; mention what cannot be undone.
- Buttons: destructive verb repeating the object ("Move to Trash", "Erase PABLO") with `role: .destructive`, bordered,
  never the default. **Ruling B-2** (overrides this spec's earlier "nothing is the default"): in an operation sheet's
  destructive review, **Cancel stays the default action** — Return cancels, as ADR-0012 and R6 require — and **Escape also
  closes the sheet**, through the sheet's `.onExitCommand`, not a second shortcut on the Cancel button.
  (`confirmationDialog` handles its own keys.)
- High-blast-radius (erase): additionally type the name (exists: `app.prep.typeName.*`) and list what is destroyed in a
  `danger` NoticeRow.

### 3.7 Sheet footer

```swift
VStack(spacing: 0) {
    ScrollView { content }                         // content scrolls; warnings are never clipped
    Divider()                                      // shows the boundary when content scrolls
    HStack(alignment: .center, spacing: Spacing.s) {
        if let reason { Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true) }   // why primary is disabled
        // or tertiary actions: Show in History, Copy Log (.bordered)
        Spacer(minLength: Spacing.m)
        cancelOrSecondary                           // .cancelAction
        primary                                     // .defaultAction, rightmost
    }
    .padding(Spacing.xl)
}
```

Rules: primary rightmost; Cancel immediately left of it; tertiary actions on the leading side after the reason; at most one
default button; the footer is always visible regardless of content height (R3SheetFitTests). The disabled reason has no
`lineLimit`. During an un-stoppable phase the footer shows the "can't stop" info line, not an empty bar.

### 3.8 Charts

- Category labels are shown **in full** at `.body`, never truncated with "…": a leading label column sized to the longest
  label (wrapping for long localized names), or the label on its own full-width line above the bar. No `lineLimit` on
  chart labels.
- Every bar shows its size annotation (`.caption`, `.monospacedDigit()`, `.secondary`), including bars too short to hold
  it; use `annotation(position: .trailing, overflowResolution: .init(x: .fit, y: .disabled))` (macOS 14).
- Color is the bucket fill + the bucket symbol + the name (never color alone); the Simulators chart uses the system pair
  with a legend.
- Interactive bars: pointing hand and hover emphasis (exists), a persistent one-line hint, and an equivalent
  keyboard-reachable control (the FilterChips / the table selection).

---

## 4. Audit of the current app (`feat/r7-polish-plan` @ 0b3c6e5)

Paths are under `Sources/XCodeVault/`. "R7-A" marks rows that the R7-A brief already schedules; R7-B should implement them
with the components above if R7-A has not.

| # | File:line | Deviation | Change |
| --- | --- | --- | --- |
| 1 | `Views/BucketViews.swift:33-42` | `MarkerBadges` draws each marker as a capsule with `quaternaryLabelColor` fill — same look as a small bordered button in dark mode (17, 18, 19, 20) | Replace with `Tag.marker(_:)` (§3.2): symbol + `.caption .secondary` text, no background |
| 2 | `Views/DrivesViews.swift:243-249` | The Experimental badge and the option buttons share one `HStack` with one `.controlSize(.small)`: reads as a button group (17) | Tag on its own line above (or after the verdict line); buttons in their own row |
| 3 | `Views/DrivesViews.swift:245-246` | Option buttons have no explicit style inside a `List` (render as grey fill); recommended option not distinguished except by text | `.buttonStyle(.bordered)`; the recommended option `.borderedProminent` (one per drive row); `.controlSize(.regular)` |
| 4 | `Operations/OperationText.swift:185-187` | Option button title is a sentence: "Add an APFS volume (erases nothing) — recommended…" | Verb title ("Add APFS Volume…", "Erase Drive…"); "erases nothing" / "recommended" as a `.footnote .secondary` line under the button row |
| 5 | `Views/DrivesViews.swift:233-236` | Ownership buttons: no explicit style in a `List` row | `.buttonStyle(.bordered).controlSize(.small)` |
| 6 | `Views/DrivesViews.swift:240` | **Use Drive** has no explicit style in a `List` row | `.buttonStyle(.bordered)` (or prominent if it is the row's only/primary action) |
| 7 | `Views/OperationSheetView.swift:69` | Sheet title uses `MarkerBadges` capsule (18-20) | `Tag.marker(.experimental)` after the title, same baseline |
| 8 | `Views/HealthHistoryViews.swift:272-283` | `HistoryKindBadge`: tinted capsule fill + coloured stroke in a table cell — looks like a chip | `Tag.historyKind(_:)`: tinted symbol + text, no container |
| 9 | `Views/DetailViews.swift:51-68` | Filter summary is a capsule with an × button **and** a separate Show All — two clears, and the capsule reads as a chip (21) | Plain `.callout .secondary` label "Filtering: Keep" + one **Show All** (`.bordered`, `.small`); drop the × |
| 10 | `Views/DetailViews.swift:76-84` | Legend chips use `.toggleStyle(.button)`: off = bordered button, on = accent-filled = looks like the primary button (21, "Keep") | `Toggle(...).toggleStyle(FilterChipStyle())` (§3.3); regular size, ≥ 24 pt high |
| 11 | `Views/ChartViews.swift:76-85` | Storage axis labels truncate ("Pa…", "Ke…") (21) — R7-A | Full labels at `.body` per §3.8; no truncation |
| 12 | `Views/ChartViews.swift:137-146` | Simulators axis labels truncate ("iOS 26…") (22) — R7-A | Same as #11 |
| 13 | `Views/ChartViews.swift:127-129` | Annotation `.caption2` (Storage uses `.caption`); the shortest bar shows no size (22, "iPhone SE") — R7-A | `.caption`; `overflowResolution` so every bar keeps its size |
| 14 | `Views/OperationSheetView.swift:465-468` | Disabled reason is `.caption` with `lineLimit(3)` — can truncate the only explanation | `.footnote .secondary`, no `lineLimit`, `fixedSize(vertical)` (§3.7) |
| 15 | `Views/OperationSheetView.swift:472-476` | Destructive review: Cancel is `.defaultAction` (Return cancels, Escape does nothing); destructive button unstyled | Per ruling B-2: Cancel stays `.defaultAction`; the sheet's `.onExitCommand` makes Escape close it; destructive `.bordered` + `role: .destructive` (§3.6) |
| 16 | `Views/OperationSheetView.swift:479` + `Operations/OperationText.swift:107` | Primary title carries the full path ("Point Archives at /Volumes/PABLO/XCodeVault/Archives", 20) — very wide, truncates in other locales | Short verb ("Use This Folder", "Run"); path stays in the "To" fact |
| 17 | `Views/OperationSheetView.swift:25-36` | Content `ScrollView` and footer have no separator; clipped warnings look cut off, not scrollable (19) — R7-A | `Divider()` above the footer; scroll content; extend R3SheetFitTests |
| 18 | `Views/OperationSheetView.swift:206-215` | Destination drives repeat the picker's verdict with a neutral check and a generic **Prepare…** (19, 20) — R7-A | Verdict once (in the picker); one specific button ("Add a Case-insensitive Volume…") next to it, only when there is something to prepare |
| 19 | `Views/OperationSheetView.swift:105` | Warning uses outline `exclamationmark.triangle` | `StatusIcon(.warning)` (filled) |
| 20 | `Views/OperationSheetView.swift:287` | Same outline triangle (indistinguishable-identity notice) | `StatusIcon(.warning)` |
| 21 | `Views/OperationSheetView.swift:273-277` | "Will erase" list uses an ad-hoc red triangle | `NoticeRow(kind: .danger, …)` |
| 22 | `Views/OperationSheetView.swift:267`, `:362`, `:567`; `Views/DrivesViews.swift:234` | Copy Command buttons are unstyled regular buttons; `PlanRowView` uses `.bordered .small` with a symbol and a "Copied" state | One `CopyCommandButton(command:a11yName:)` used everywhere (bordered, small, `doc.on.doc`, "Copied" feedback) |
| 23 | `Views/BucketViews.swift:121` | **Run** has no explicit style; it opens a sheet but has no ellipsis | `.buttonStyle(.bordered)`, title "Run…" (`app.plan.run`) |
| 24 | `Views/OperationSheetView.swift:99` | **Check Again** placed in content below blockers, full width of the column (19) | Attach to the blocker `NoticeRow`'s actions (`.bordered .small`), not a free-standing row |
| 25 | `Views/DetailViews.swift:56-61`; `Views/MainView.swift:227-230` | Icon-only `.plain` × buttons ~16 pt — below the 24-pt target | `.frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())` (#9 removes the first) |
| 26 | `Views/OverviewView.swift:44, :134`; `Views/DrivesViews.swift:92, :101, :110, :120, :147`; `Views/HealthHistoryViews.swift:50, :82, :242`; `Views/OperationSheetView.swift:352, :394, :556`; `Views/BucketViews.swift:201` | Status symbols built ad hoc with `foregroundStyle(.red/.orange/.green)` (correct semantics, duplicated) | `StatusIcon(kind)` / `StatusLabel` so the symbol–tint pairs live in one place (§3.4) |
| 27 | `Views/DrivesViews.swift:43` | Offline vault: two-state green/red tint chosen inline | `StatusIcon(c.isUsable ? .success : .blocker)` |
| 28 | `Views/OverviewView.swift:144-149` vs `Views/BucketViews.swift:131-132`, `Views/HealthHistoryViews.swift:112-113` | Card radii 10 vs 8; strokes `separatorColor` vs `.quaternary` | `Radius.card` (8) and `stroke.hairline` everywhere |
| 29 | `Views/DrivesViews.swift:74`, `:208` | Facts line `lineLimit(1)` truncates with no tooltip | `.help(facts)` on the line, or allow wrapping |
| 30 | `Views/BucketViews.swift:465-467` | Delete Selected: no visible reason when disabled (nothing deletable selected) beyond the count | When `chosen.isEmpty`, the count line reads "Select items to delete" (`.footnote .secondary`) |
| 31 | `Views/OperationSheetView.swift:488-489` | Finished footer: Show in History is a sibling of Done in the trailing group | Show in History leading (tertiary), Done trailing (default) per §3.7 |
| 32 | `Views/DetailViews.swift:203` | **Clear Selection** unstyled in a header row next to the chart title | `.buttonStyle(.bordered).controlSize(.small)`, consistent with Show All |

**32 rows.** Rows 1-10 and 15-16 are the affordance fixes the user asked for; rows 11-13, 17-18 overlap R7-A.

**R7-B, as implemented** (`.superpowers/sdd/r7/b-report.md` has the row-by-row record):

- Every row is done. Row 4's titles are the ones the Run sheet already used ("Add a Case-insensitive Volume…",
  "Erase “STICK”…", "Erase the Disk…"), so a drive's action has one name in both places; "erases nothing" and
  "recommended" are the footnote under the row. Row 16 drops the paths ("Use This Folder", "Export the iOS Installer",
  "Copy 18 GB of Archives to PABLO"); a runtime's title keeps the runtime's name and size, which can pass 40 characters.
  Row 24's **Check Again** sits in the footer beside the reason it answers, since the blocker is said there, not in a
  notice. The destructive **Delete Selected…**, **Uninstall Helper…** and **Remove Original…** take `.bordered` with
  `role: .destructive`; macOS draws a bordered destructive button with neutral text, so the title names the destruction.
- FilterChip's outline is a rounded rectangle of half the chip's height rather than `Capsule().strokeBorder`, which drew
  stray vertical segments at its ends off-screen. Same shape; the fill is still a capsule.
- The bar chart's label column (§3.8) is the longest label as measured on one line at body size and semibold (its
  hovered weight), plus the symbol, capped at 260 pt (`BarChartLayout.labelColumnWidth`, `ChartLabelMetrics`). The
  charts are a hand-built `Grid`, not Swift Charts (R7-A), so `overflowResolution` does not apply: every row carries its
  own size.
- U7 counts literal `.borderedProminent` and `actionButton(prominent: true)` per view; a per-row prominent decided by a
  function (ruling B-1) is checked by `DesignSystemTests.testADriveRowHasAtMostOnePrimary` instead. U10 accepts a
  `// U10: dialog` marker for a `confirmationDialog`'s own button.

---

## 5. Tests and enforceable invariants

Keep them cheap: a source lint for what is syntactic, Core/AppModel unit tests for decisions, one gallery snapshot for the
eye. Follow the existing patterns (`scripts/helper-invariants.sh`; measure rules with `/usr/bin/grep` or `/bin/bash`, not
the agent shell's `grep`).

### 5.1 Source lint — `scripts/ui-invariants.sh`

Scope: `Sources/XCodeVault/**/*.swift` excluding `Sources/XCodeVault/DesignSystem/`. Add it to `scripts/preflight.sh` and
`.github/workflows/ci.yml` together (preflight checks the step count).

| Rule | Pattern (fails the build) | Why |
| --- | --- | --- |
| U1 No capsule containers outside the design system | `in: Capsule()` or `Capsule().fill` / `Capsule().strokeBorder` | Only FilterChip may be a capsule (§2.3) |
| U2 No button-styled toggles | `\.toggleStyle\(\.button\)` | Filters use `FilterChipStyle` (§3.3) |
| U3 No ad-hoc status tints | `foregroundStyle\((Color\.)?(red|orange|green)\)` | Use `StatusIcon`/`StatusLabel` (§3.4) |
| U4 Filled warning symbols only | `"exclamationmark\.triangle"` (no `.fill`) outside `Tag.marker` | One warning glyph app-wide |
| U5 No truncation in charts | `lineLimit` or `truncationMode` in `Views/ChartViews.swift` | §3.8 |
| U6 No retired badge types | `MarkerBadges\(` or `HistoryKindBadge\(` | One `Tag` type (§3.2) |
| U7 One prominent per file body (heuristic) | more than one `.borderedProminent` per `struct … View` | §1.2; exceptions listed in the script with a reason |
| U8 No custom disabled look | `\.opacity\(.*(isEnabled|disabled)` | Use `.disabled(_:)` (§3.1) |
| U9 Sheet Cancel binds Escape | a `Button(…"app.action.cancel"…)` line in `OperationSheetView.swift`/`XCodeVaultApp.swift` without `.cancelAction` — or with `.defaultAction` (ruling B-2) in a file with no `.onExitCommand {` | §3.6–3.7 |
| U10 Buttons in List/Form rows are styled | `Button(` in `DrivesViews.swift`, `AccessView.swift` row views without `.buttonStyle(` within the same view chain (checked per call site, allow-list for toolbar/menu/dialog contexts) | Root cause of 17 |

Each rule prints `file:line` and the rule ID; a mutation self-test (inject one violation in a temp copy, expect failure)
keeps the lint honest, as `helper-invariants.sh` does.

### 5.2 Unit tests (no windows, no disks)

- **Disabled reason exists:** for every `OperationSheetState` fixture in review phase,
  `!model.canConfirmOperation ⇒ model.operationBlockers.first != nil` and `AppModel.blockerText(_)` is non-empty in every
  locale (`AppModelTests`).
- **Button titles are short verbs:** `OperationText.optionButton` and `operationConfirmTitle` contain no `/` (no paths) and
  are ≤ 40 characters in en (#4, #16).
- **Status mapping is total and distinct:** `StatusKind.allCases` map to distinct (symbol, tint) pairs except
  `blocker`/`danger` (same tint, different symbol); every symbol name resolves (`NSImage(systemSymbolName:)` non-nil).
- **Tag is not interactive:** `Tag` declares no gesture, hover or focus modifiers — asserted by the U1/U6 lint plus a
  `DesignSystemTests` check that `Tag.marker(.experimental)` produces "Experimental" + `flask` (rule 10 stays visible).
- **Contrast:** extend `BrandTokenTests` so `stroke.chip` and the selected-chip accent stroke reach 3:1 against
  `windowBackgroundColor` and `controlBackgroundColor` in `.aqua`/`.darkAqua` (WCAG 1.4.11); status tints are symbols,
  so 3:1 applies, not 4.5:1.
- **Chart labels in full:** the label string passed to the axis equals `AppText.bucketShortName`/`bar.name` exactly (no
  ellipsis inserted); `ScreenFitTests` covers ja/de at minimum width (R7-A).
- **Sheet fit:** `R3SheetFitTests` asserts the footer is visible and the last warning is reachable at minimum height.

### 5.3 Gallery snapshot

`DesignSystemSnapshotTests` renders one view with every component — primary/secondary/destructive/link buttons enabled and
disabled, Tag variants, FilterChip off/on/disabled (hover cannot be rendered off-screen), each StatusLabel, a NoticeRow with actions, a sheet footer with a
disabled reason — in light, dark and Increase Contrast, en and ja. Reviewers compare it, not 20 screens. Like the existing
snapshot tests, it renders off-screen (no window, no scan).

---

## 6. Implementation order (R7-B)

1. Add `DesignSystem/` (Tokens, Tag, StatusIcon/StatusLabel, NoticeRow, FilterChipStyle, CopyCommandButton, SheetFooter) +
   gallery snapshot + `scripts/ui-invariants.sh` in report-only mode.
2. Migrate audit rows 1-10, 15-16 (affordance), then 19-27 (status consolidation), then the rest.
3. Switch the lint to failing; wire it into preflight and CI.
4. Link this file from `docs/brand/BRAND.md` and `CLAUDE.md` ("Read before acting") in the same change.
