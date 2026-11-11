#!/bin/zsh
# Redraws the app icon (scripts/make_icon.swift) into Resources/AppIcon.icns.
set -e
cd "$(dirname "$0")/.."
SET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  swift scripts/make_icon.swift "$SET/icon_${s}x${s}.png" $s
  swift scripts/make_icon.swift "$SET/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Made Resources/AppIcon.icns"
