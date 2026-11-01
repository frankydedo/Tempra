#!/bin/zsh
# Builds a Release Tempra.app and packages it for a GitHub Release:
#   build/Tempra-<version>.zip and its SHA-256 checksum.
# The app is ad-hoc signed (no Developer ID), so it is not notarized.
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
