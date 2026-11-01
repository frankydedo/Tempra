#!/bin/zsh
# Builds a Release Tempra.app and packages it for a GitHub Release:
#   build/Tempra-<version>.zip and its SHA-256 checksum.
# The app is ad-hoc signed (no Developer ID), so it is not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Tempra.app/Contents/Info.plist)
ZIP="build/Tempra-$VERSION.zip"

# A Finder custom icon (from Settings → App Icon) must not ship in the release.
rm -f "build/Tempra.app/Icon"$'\r'
codesign --force --deep --sign - build/Tempra.app
codesign --verify --strict build/Tempra.app

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tempra.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Packaged $ZIP"
