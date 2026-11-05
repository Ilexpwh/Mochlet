#!/bin/zsh
# Replays a hook fixture through the real relay into the running app (debug or release).
#   scripts/replay-hooks.sh Tests/Fixtures/hooks/claude-session.jsonl [delay-seconds] [--agent codex]
# Lines starting with # are skipped. Blocking fixtures (approval.json, question.json, plan.json)
# hold the relay until you answer on the notch; the agent-format output is printed when it returns.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:?fixture path}"
DELAY="${2:-0.5}"
shift 2 2>/dev/null || shift $# 
RELAY="$HOME/Library/Application Support/Mochlet/bin/mochlet-hook"
[ -x "$RELAY" ] || RELAY="$(swift build --show-bin-path)/mochlet-hook"
grep -v '^#' "$FILE" | grep -v '^[[:space:]]*$' | while IFS= read -r line; do
  printf '%s' "$line" | "$RELAY" "$@"
  sleep "$DELAY"
done
