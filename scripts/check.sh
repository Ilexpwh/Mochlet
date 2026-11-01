#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift test --package-path Packages/SlimeCore
scripts/build.sh
MOCHLET_RUNTIME_SELF_TEST=1 MOCHLET_PI_FIXTURE_PATH="$PWD/Packages/SlimeCore/Tests/SlimeCoreTests/Fixtures/pi-rpc.py" build/Build/Products/Debug/Mochlet.app/Contents/MacOS/Mochlet
