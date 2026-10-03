# XCodeVault brand guide

## Concept

A vault door seen front-on. The dial's handle leaves the door as an outward teal arrow: "storage,
safely moved out". The mark uses no Apple marks, no hammer and no Xcode icon.

## Assets

| File | Use |
| --- | --- |
| `Resources/Brand/logo.svg` | Master artwork (tile, door, arrow). Edit this one. |
| `Resources/Brand/logo-mono.svg` | Single color, no tile. For one-color print and contexts without a tile. |
| `Resources/App/AppIcon.icns` | App icon, generated from the master. |
| `docs/brand/logo-256.png` | README and docs, generated from the master. |

## Palette

| Role | Value |
| --- | --- |
| Indigo (tile) | `#2B2D6E`, tile gradient `#3B3E92` to `#1C1E52` |
| Teal (arrow) | `#1FB5A8`, gradient to `#62E6CF` |
| Door | `#F5F7FC` to `#C7CCDF` |

## Bucket tokens

Every savings bucket has one color and one SF Symbol. Never use the color alone: always show the
symbol and the localized bucket title with it.

| Bucket | Color | SF Symbol |
| --- | --- | --- |
| Delete | `#C27C12` | `arrow.counterclockwise.circle` |
| Park | `#3B82F6` | `shippingbox` |
| Run from external | `#22A06B` | `externaldrive.badge.checkmark` |
| Keep local | `#8A8FA3` | `internaldrive` |

All four reach at least 3:1 contrast on white and on `#1C1E52` (pinned by `BrandTokenTests`).

### CLI

The CLI colors bucket titles only, and only on a terminal. There is no color when `NO_COLOR` is set
(any value), when `TERM=dumb`, with `--json`, for `report`, or when output is piped.

## Clear space

Keep one door-radius of empty space around the tile.

## Minimum size

16 px. Below that the arrow is no longer visible, and the arrow is the point of the mark.

## Don'ts

- Do not recolor the arrow; it is teal everywhere the mark has color.
- Do not use Apple marks, the Xcode icon or a hammer, alone or combined with the mark.
- Do not stretch, rotate or add effects to the mark.
- Do not signal a bucket by color alone.

## Regenerating the icon

`scripts/make-icon.sh` renders `Resources/Brand/logo.svg` into `Resources/App/AppIcon.icns` and
`docs/brand/logo-256.png`. It needs `rsvg-convert` (`brew install librsvg`). The outputs are
committed, so CI never runs it.
