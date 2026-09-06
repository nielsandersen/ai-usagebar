#!/usr/bin/env bash
# Convert the artwork to Apple's standard multi-resolution icon container.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$DIR/AppIcon-source.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$DIR/AppIcon-source.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$DIR/AppIcon.icns"
