#!/bin/zsh
# Render a state or script to out/<name>/contact.png for motion review.
# usage: scripts/filmstrip.sh <state|emote|pinch|sessions|ghost|split> [extra slimekit-tools args]
set -euo pipefail
cd "$(dirname "$0")/.."
STATE="${1:-idle}"; shift || true
swift run -q --package-path Packages/SlimeKit slimekit-tools render-filmstrip --state "$STATE" --out "out/$STATE" "$@"
open "out/$STATE/contact.png"
