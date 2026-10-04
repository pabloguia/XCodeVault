#!/usr/bin/env bash
# Renders Resources/Brand/logo.svg into Resources/App/AppIcon.icns and docs/brand/logo-256.png.
# Needs rsvg-convert (brew install librsvg) and iconutil; the outputs are committed, so CI never runs this.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "make-icon: rsvg-convert not found (brew install librsvg)" >&2; exit 2; }
work=$(mktemp -d -t xcv-icon); trap 'rm -rf "$work"' EXIT
set_dir="$work/AppIcon.iconset"; mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Resources/Brand/logo.svg -o "$set_dir/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) Resources/Brand/logo.svg -o "$set_dir/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o Resources/App/AppIcon.icns
mkdir -p docs/brand
rsvg-convert -w 256 -h 256 Resources/Brand/logo.svg -o docs/brand/logo-256.png
echo "make-icon: wrote Resources/App/AppIcon.icns and docs/brand/logo-256.png"
