#!/bin/zsh
# Builds Tempra.app (Release). Pass --install to copy it to /Applications and launch it.
#
# Only /Applications/Tempra.app should exist as a visible app. The build product stays inside
# build/DerivedData.noindex (".noindex" keeps Spotlight away) and is unregistered from
# LaunchServices, so it doesn't show up in Spotlight, Launchpad or "Open With".
set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PRODUCT=build/DerivedData.noindex/Build/Products/Release/Tempra.app

xcodegen generate --quiet
xcodebuild -project Tempra.xcodeproj -scheme Tempra -configuration Release \
  -derivedDataPath build/DerivedData.noindex -quiet build
"$LSREGISTER" -u "$PRODUCT" 2>/dev/null || true
echo "Built $PRODUCT"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tempra 2>/dev/null || true
  rm -rf /Applications/Tempra.app
  cp -R "$PRODUCT" /Applications/Tempra.app
  "$LSREGISTER" -f /Applications/Tempra.app
  open /Applications/Tempra.app
  echo "Installed to /Applications and launched"
fi
