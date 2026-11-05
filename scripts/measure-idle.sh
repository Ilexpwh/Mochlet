#!/bin/zsh
# Samples Mochlet's CPU for N seconds (default 300) while idle; prints the average.
set -euo pipefail
SECONDS_TO_SAMPLE="${1:-300}"
PID=$(pgrep -x Mochlet | head -1) || { echo "Mochlet is not running"; exit 1; }
echo "sampling pid $PID for ${SECONDS_TO_SAMPLE}s"
START_CPU=$(ps -o cputime= -p "$PID" | awk -F'[:.]' '{ print ($1*60+$2) + ($3+0)/100 }')
sleep "$SECONDS_TO_SAMPLE"
END_CPU=$(ps -o cputime= -p "$PID" | awk -F'[:.]' '{ print ($1*60+$2) + ($3+0)/100 }')
awk -v a="$START_CPU" -v b="$END_CPU" -v s="$SECONDS_TO_SAMPLE" 'BEGIN { printf "average cpu: %.2f%% of a core\n", (b-a)/s*100 }'
ps -o rss= -p "$PID" | awk '{ printf "resident memory: %.1f MB\n", $1/1024 }'
