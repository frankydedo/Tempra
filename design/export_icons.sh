#!/bin/zsh
# Renders every design/icons/*.icon with Icon Composer's ictool into
#  - Tempra/Resources/AlternateIcons/<Variant>.png  (offered in Settings → General → App Icon)
#  - docs/icon.png                                   (README header, default variant)
# Run after design/make_icons.py whenever the icon designs change.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

render() { "$ICTOOL" "$1" --export-image --output-file "$2" --platform macOS --rendition Default \
  --width "$3" --height "$3" --scale 1 >/dev/null; }

OUT=Tempra/Resources/AlternateIcons
rm -rf "$OUT" && mkdir -p "$OUT"
for doc in design/icons/*.icon; do
  name="${${doc:t:r}#Tempra-}"
  render "$doc" "$OUT/$name.png" 512
  echo "$OUT/$name.png"
done
render Tempra/Resources/AppIcon.icon docs/icon.png 512
echo docs/icon.png
