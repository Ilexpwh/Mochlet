#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project Mochlet.xcodeproj -scheme Mochlet -configuration "${CONFIGURATION:-Debug}" -derivedDataPath build -destination 'platform=macOS,arch=arm64' build "$@"
