#!/bin/zsh
# Release build: Developer ID signature, hardened runtime, notarisation, stapling, a zip and a DMG.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=mochlet scripts/release.sh
# Without SIGN_IDENTITY the app is ad-hoc signed and only zipped (for testing on this Mac; Gatekeeper
# will refuse it elsewhere). NOTARY_PROFILE is a keychain profile made once with
#   xcrun notarytool store-credentials mochlet --apple-id <id> --team-id <TEAMID> --password <app-specific>
# SKIP_NOTARY=1 signs without notarising.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:--}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
OUT="build/release"

SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh release
APP="$OUT/Mochlet.app"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

if [ "$IDENTITY" = "-" ]; then
  echo "ad-hoc signature: skipping notarisation (set SIGN_IDENTITY for a shippable build)"
elif [ "${SKIP_NOTARY:-0}" != "1" ]; then
  [ -n "${NOTARY_PROFILE:-}" ] || { echo "NOTARY_PROFILE is not set"; exit 1; }
  ditto -c -k --keepParent "$APP" "$OUT/Mochlet-notary.zip"
  xcrun notarytool submit "$OUT/Mochlet-notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/Mochlet-notary.zip"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1
fi

ZIP="$OUT/Mochlet-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

DMG="$OUT/Mochlet-$VERSION.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Mochlet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [ "${SKIP_NOTARY:-0}" != "1" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
ls -la "$ZIP" "$DMG" | awk '{ print $5, $9 }'
echo "release $VERSION ready in $OUT"
