#!/bin/zsh
# One-time setup: Homebrew tools and the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "installing xcodegen"; brew install xcodegen
fi
# A private Lark transcript folder must never be committed.
if [ -d minutes ]; then
  echo "note: ./minutes is a private transcript folder; it stays gitignored"
fi
xcodegen generate --quiet
echo "generated Mochlet.xcodeproj"
