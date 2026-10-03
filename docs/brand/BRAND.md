# XCodeVault brand guide

## Concept

A vault door seen front-on. The dial's handle leaves the door as an outward teal arrow: "storage,
safely moved out". The mark uses no Apple marks, no hammer and no Xcode icon.

## Assets

| File | Use |
| --- | --- |
| `Resources/Brand/logo.svg` | Master artwork (tile, door, arrow). Edit this one. |
| `Resources/Brand/logo-mono.svg` | Single color, no tile. For one-color print and contexts without a tile; light backgrounds only, no dark-background variant yet. |
| `Resources/App/AppIcon.icns` | App icon, generated from the master. |
| `docs/brand/logo-256.png` | README and docs, generated from the master. |

## Palette

| Role | Value |
| --- | --- |
| Indigo (primary / mono) | `#2B2D6E`; logo tile gradient `#3B3E92` → `#1C1E52` |
| Teal | UI accent `#1FB5A8` (flat, `Brand.teal`); logo arrow gradient `#17A497` → `#62E6CF` |
| Door | `#F5F7FC` to `#C7CCDF` |

## Bucket tokens

Every savings bucket has one color and one SF Symbol. Never use the color alone: always show the
symbol and the localized bucket title with it.

| Bucket | Color (token; app dark appearance) | App light appearance | SF Symbol |
| --- | --- | --- | --- |
| Delete | `#C27C12` | `#AB6D10` | `arrow.counterclockwise.circle` |
| Park | `#3B82F6` | `#2776F5` | `shippingbox` |
| Run from external | `#22A06B` | `#1E8B5D` | `externaldrive.badge.checkmark` |
| Keep local | `#8A8FA3` | `#737991` | `internaldrive` |

All four tokens reach at least 3:1 contrast on white and on `#1C1E52` (pinned by `BrandTokenTests`).

In the app the colors are appearance-aware (`SavingsBucket.nsColor`, a dynamic `NSColor`): the token in the dark
appearance, and a darker variant of the same hue in the light one, because on the light window background earlier
macOS versions use (`#ECECEC`) three of the tokens fall below 3:1. `BrandTokenTests` resolves `windowBackgroundColor` and
`controlBackgroundColor` under `.aqua` and `.darkAqua` and holds every bucket to 3:1 against both, and against `#FFFFFF`,
`#ECECEC`, `#323232` and `#1E1E1E`.

### CLI

The CLI colors bucket titles only, and only on a terminal: 24-bit when `COLORTERM` is `truecolor` or `24bit`, the nearest xterm-256 cube color otherwise. There is no color when `NO_COLOR` is set
(any value), when `TERM=dumb`, with `--json`, for `report`, or when output is piped.

## Using the tokens in the app

- Bucket colors are fills and icon tints, never text color.
- Tokens must be appearance-aware (light and dark) before GUI use.
- Do not use `Brand.indigo` as a foreground in dark mode or `Brand.teal` on light surfaces.
- In selected rows the symbol uses the selection style.
- Never place the mark next to toolbar or menu actions, where it could read as "log out".

## Clear space

Keep one door-radius of empty space around the tile.

## Minimum size

16 px. Below that the arrow is no longer visible, and the arrow is the point of the mark.

## Don'ts

- In the color mark the arrow is always the teal gradient; in the mono mark everything is one color.
- Do not use Apple marks, the Xcode icon or a hammer, alone or combined with the mark.
- Do not stretch, rotate or add effects to the mark.
- Do not signal a bucket by color alone.

## Regenerating the icon

`scripts/make-icon.sh` renders `Resources/Brand/logo.svg` into `Resources/App/AppIcon.icns` and
`docs/brand/logo-256.png`. It needs `rsvg-convert` (`brew install librsvg`). The outputs are
committed, so CI never runs it.
