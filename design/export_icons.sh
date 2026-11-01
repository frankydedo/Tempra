#!/bin/zsh
# Renders every design/icons/*.icon with Icon Composer's ictool into
#  - Tempra/Resources/AlternateIcons/<Variant>.png  (offered in Settings → General → App Icon)
#  - docs/icon.png                                   (README header, default variant)
# Run after design/make_icons.py whenever the icon designs change.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# ictool renders the icon body edge to edge, but macOS icons sit on a grid where the body is
# 824/1024 of the canvas with a transparent margin. Render the body at that size and pad it,
# so alternate icons match the compiled AppIcon's size in the Dock and Finder.
render() {
  local canvas=$3 body=$(( $3 * 824 / 1024 ))
  "$ICTOOL" "$1" --export-image --output-file "$2" --platform macOS --rendition Default \
    --width "$body" --height "$body" --scale 1 >/dev/null
  sips -p "$canvas" "$canvas" "$2" >/dev/null
}

OUT=Tempra/Resources/AlternateIcons
rm -rf "$OUT" && mkdir -p "$OUT"
for doc in design/icons/*.icon; do
  name="${${doc:t:r}#Tempra-}"
  render "$doc" "$OUT/$name.png" 512
  echo "$OUT/$name.png"
done
render Tempra/Resources/AppIcon.icon docs/icon.png 512
echo docs/icon.png
