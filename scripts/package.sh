#!/bin/zsh
# Builds a Release Tempra.app and packages it for a GitHub Release:
#   build/Tempra-<version>.zip and its SHA-256 checksum.
# The app is ad-hoc signed (no Developer ID), so it is not notarized.
#
# This Mac keeps only the latest release: the packaged app replaces /Applications/Tempra.app
# (pass --no-install to skip), and zips and notes of older versions are removed from build/
# (they remain downloadable from GitHub Releases).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
APP=build/DerivedData.noindex/Build/Products/Release/Tempra.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Tempra-$VERSION.zip"

# A Finder custom icon (from Settings → App Icon) must not ship in the release.
rm -f "$APP/Icon"$'\r'
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "${ZIP:t}") | tee "$ZIP.sha256"
echo "Packaged $ZIP"

# Keep only this version's artifacts.
for old in build/Tempra-*.zip(N) build/Tempra-*.zip.sha256(N) build/release-notes*.md(N); do
  [[ "$old" == *"-$VERSION."* || "$old" == *"-$VERSION.md" ]] || rm -f "$old"
done

if [[ "${1:-}" != "--no-install" ]]; then
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pkill -x Tempra 2>/dev/null || true
  rm -rf /Applications/Tempra.app
  ditto "$APP" /Applications/Tempra.app
  "$LSREGISTER" -f /Applications/Tempra.app
  open /Applications/Tempra.app
  echo "Installed Tempra $VERSION in /Applications"
fi
