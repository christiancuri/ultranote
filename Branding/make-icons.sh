#!/usr/bin/env bash
# Regenerates every UltraNote icon asset from Branding/mark.svg (a note page with a
# folded corner, a checked to-do and text lines).
#
#   UltraNote/AppIcon.icon/Assets/{page,ink}.svg    app icon layers (icon.json is hand-edited)
#   Branding/preview/AppIcon.svg, AppIcon-1024.png        flat preview for review (rsvg-convert)
#   Branding/preview/AppIcon-rendered-1024.png            Liquid Glass render (actool + IconServices)
#   Branding/preview/AppIcon-rendered-dark-1024.png       dark appearance render (ictool)
#   Branding/VolumeIcon.icns                              DMG volume icon, the rendered app icon
#
# Usage: Branding/make-icons.sh [--flat]
#   --flat  skip the Xcode renders (rendered previews and VolumeIcon.icns).
# Requires `brew install librsvg`; the renders need Xcode 26+ (actool, Icon Composer's ictool).
set -euo pipefail

BRANDING="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$BRANDING")"
ICON="$ROOT/UltraNote/AppIcon.icon"
PREVIEW="$BRANDING/preview"
RENDER=1
[[ "${1:-}" == "--flat" ]] && RENDER=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in rsvg-convert; do
  command -v "$tool" >/dev/null || { echo "missing $tool: brew install librsvg" >&2; exit 1; }
done

# layer <id>: the path data of one layer in mark.svg.
layer() {
  local d
  d="$(sed -n "s/.*id=\"$1\".* d=\"\([^\"]*\)\".*/\1/p" "$BRANDING/mark.svg")"
  [[ -n "$d" ]] || { echo "no path with id=\"$1\" in mark.svg" >&2; exit 1; }
  printf '%s' "$d"
}
PAGE="$(layer page)"
INK="$(layer ink)"

# App icon layers: one SVG per layer on the 1024 pt Icon Composer canvas. The
# layer colors, opacities, groups and glass settings come from icon.json.
mkdir -p "$ICON/Assets"
for name in page ink; do
  case "$name" in
    page) d="$PAGE" ;;
    ink) d="$INK" ;;
  esac
  cat >"$ICON/Assets/$name.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#fff" fill-rule="evenodd" d="$d"/>
</svg>
EOF
done

# Flat preview: the icon.json light gradient and layer opacities inside the
# macOS squircle (824 pt of the 1024 pt grid). No Liquid Glass; see the renders.
# Keep these colors in sync with icon.json.
mkdir -p "$PREVIEW"
cat >"$PREVIEW/AppIcon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#7B61FF"/>
      <stop offset="1" stop-color="#2A1B78"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#0E0830" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
  <g transform="translate(100 100) scale(0.8046875)" fill="#fff" fill-rule="evenodd" filter="url(#shadow)">
    <path fill-opacity="0.35" d="$PAGE"/>
    <path d="$INK"/>
  </g>
</svg>
EOF
rsvg-convert -w 1024 -h 1024 -o "$PREVIEW/AppIcon-1024.png" "$PREVIEW/AppIcon.svg"

if [[ "$RENDER" == 1 ]]; then
  # The real Liquid Glass rendering of AppIcon.icon, as macOS draws it.
  swift "$BRANDING/render-icon.swift" "$ICON" "$TMP/VolumeIcon.iconset"
  cp "$TMP/VolumeIcon.iconset/icon_512x512@2x.png" "$PREVIEW/AppIcon-rendered-1024.png"
  iconutil -c icns -o "$BRANDING/VolumeIcon.icns" "$TMP/VolumeIcon.iconset"

  # Dark appearance (IconServices only serves the light one to a CLI process),
  # via Icon Composer's ictool (not `xcrun ictool`, which is actool's). It
  # renders the squircle full bleed; pad it onto the same 1024 grid.
  ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
  "$ICTOOL" "$ICON" --export-preview macOS Dark 824 824 1 -45 "$TMP/dark.png" >/dev/null
  sips -p 1024 1024 "$TMP/dark.png" --out "$PREVIEW/AppIcon-rendered-dark-1024.png" >/dev/null
  # Kept for the small-size check in README review.
  if [[ -n "${KEEP_ICONSET:-}" ]]; then cp -R "$TMP/VolumeIcon.iconset" "$KEEP_ICONSET"; fi
fi

echo "icons regenerated"
