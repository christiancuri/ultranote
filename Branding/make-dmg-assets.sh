#!/usr/bin/env bash
# Regenerates the DMG window background used by scripts/release.sh:
#   Branding/dmg-background.png, dmg-background@2x.png   660 x 400 pt window background
#                                                        (resvg + SF Pro, from dmg-background.svg)
# The DMG volume icon (Branding/VolumeIcon.icns) comes from Branding/make-icons.sh.
#
# usage: Branding/make-dmg-assets.sh
# Requires `brew install resvg`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v resvg >/dev/null || { echo "missing resvg: brew install resvg" >&2; exit 1; }

# SF Pro is passed explicitly so the caption matches Finder's labels.
FONT=(--use-font-file /System/Library/Fonts/SFNS.ttf)
resvg "${FONT[@]}" -w 660 "$HERE/dmg-background.svg" "$HERE/dmg-background.png"
resvg "${FONT[@]}" -w 1320 "$HERE/dmg-background.svg" "$HERE/dmg-background@2x.png"
echo "rendered dmg-background.png (660 x 400) and dmg-background@2x.png (1320 x 800)"
