#!/bin/zsh
# Build the Debug app and launch it (kills a running copy first).
#   scripts/dev-run.sh            SwiftPM build (scripts/build-app.sh)
#   USE_XCODE=1 scripts/dev-run.sh   xcodebuild via Mochlet.xcodeproj
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${USE_XCODE:-0}" = "1" ]; then
  [ -d Mochlet.xcodeproj ] || xcodegen generate --quiet
  DERIVED="${DERIVED_DATA:-build/DerivedData}"
  xcodebuild -project Mochlet.xcodeproj -scheme Mochlet -configuration Debug -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' build -quiet 2>&1 | grep -E "error:|warning: unre|BUILD" || true
  APP="$DERIVED/Build/Products/Debug/Mochlet.app"
else
  scripts/build-app.sh debug
  APP="build/debug/Mochlet.app"
fi
[ -d "$APP" ] || { echo "build failed: $APP missing"; exit 1; }
pkill -x Mochlet 2>/dev/null || true
sleep 0.3
open "$APP"
echo "launched $APP"
