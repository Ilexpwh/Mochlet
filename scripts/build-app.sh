#!/bin/zsh
# Build Mochlet.app with SwiftPM and assemble the bundle (no xcodebuild needed).
#   scripts/build-app.sh [debug|release]      -> build/<config>/Mochlet.app
# SIGN_IDENTITY overrides the code-signing identity (default: ad hoc "-").
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
IDENTITY="${SIGN_IDENTITY:--}"

LOG="$(mktemp -t mochlet-build)"
if ! swift build -c "$CONFIG" > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u
    echo "build failed (full log: $LOG)"
    exit 1
fi
grep -E "warning: (unre|var|imm)|Build complete" "$LOG" | sort -u || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
[ -x "$BIN/Mochlet" ] || { echo "build failed: $BIN/Mochlet missing"; exit 1; }
[ -x "$BIN/mochlet-hook" ] || { echo "build failed: $BIN/mochlet-hook missing"; exit 1; }

APP="build/$CONFIG/Mochlet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Mochlet" "$APP/Contents/MacOS/Mochlet"
cp "$BIN/mochlet-hook" "$APP/Contents/Helpers/mochlet-hook"

sed -e 's/\$(EXECUTABLE_NAME)/Mochlet/g' -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' Resources/Info.plist > "$APP/Contents/Info.plist"
HASH=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :MochletGitHash string $HASH" "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="build/$CONFIG/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for f in Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png; do
  n="$(basename "$f")"; cp "$f" "$ICONSET/${n/@1x/}"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (sounds) live next to the executable's resources.
for b in "$BIN"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

if [ "$CONFIG" = "release" ]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP/Contents/Helpers/mochlet-hook"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements Mochlet.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/mochlet-hook"
  codesign --force --sign "$IDENTITY" --entitlements Mochlet.entitlements "$APP"
fi
echo "built $APP ($HASH)"
