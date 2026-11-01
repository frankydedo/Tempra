#!/bin/zsh
# Builds Tempra.app (Release) and copies it to ./build/Tempra.app.
# Pass --install to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Tempra.xcodeproj -scheme Tempra -configuration Release \
  -derivedDataPath build/DerivedData -quiet build

rm -rf build/Tempra.app
cp -R build/DerivedData/Build/Products/Release/Tempra.app build/Tempra.app
echo "Built build/Tempra.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tempra 2>/dev/null || true
  rm -rf /Applications/Tempra.app
  cp -R build/Tempra.app /Applications/Tempra.app
  open /Applications/Tempra.app
  echo "Installed to /Applications and launched"
fi
