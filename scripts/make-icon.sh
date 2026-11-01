#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/icon-tool App/Assets.xcassets/AppIcon.appiconset
xcrun swiftc -parse-as-library App/SlimeView.swift scripts/make-icon.swift -o build/icon-tool/make-icon
build/icon-tool/make-icon App/Assets.xcassets/AppIcon.appiconset
