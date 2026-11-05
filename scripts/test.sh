#!/bin/zsh
# Every test: SlimeKit, MochletCore, then the app target.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd Packages/SlimeKit && swift test 2>&1 | tail -3)
(cd Packages/MochletCore && swift test 2>&1 | tail -3)
if [ "${USE_XCODE:-0}" = "1" ]; then
  [ -d Mochlet.xcodeproj ] || xcodegen generate --quiet
  xcodebuild -project Mochlet.xcodeproj -scheme Mochlet -derivedDataPath build/DerivedData -destination 'platform=macOS' test -quiet 2>&1 | grep -E "error:|Test Suite|passed|failed" | tail -8
else
  swift test 2>&1 | tail -3
fi
