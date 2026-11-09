#!/bin/bash
# M6/M7 smoke test without the app: build mochlet-cli, create a throwaway bundle with the fixture pages,
# ingest the sample note, check that find cites it, that a question-shaped query works, and that lint
# reports the planted orphan and the broken link.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product mochlet-cli >/dev/null 2>&1 || swift build --product mochlet-cli
CLI=.build/debug/mochlet-cli
ROOT="${TMPDIR:-/tmp}/mochlet-smoke-$$"
mkdir -p "$ROOT"
trap 'rm -rf "$ROOT"' EXIT
export MOCHLET_KNOWLEDGE_ROOT="$ROOT/Knowledge"
"$CLI" bootstrap >/dev/null
cp -R Tests/Fixtures/knowledge/bundle/. "$ROOT/Knowledge/"
"$CLI" reindex >/dev/null
out=$("$CLI" ingest Tests/Fixtures/knowledge/vision-pro.md)
echo "$out"
case "$out" in *"filed inbox/"*) ;; *) echo "FAIL: ingest did not file a report"; exit 1;; esac
en=$("$CLI" find "Vision Pro price" -k 3)
case "$en" in *"inbox/"*".md:"*) echo "ok: English query cites $(echo "$en" | grep -o 'inbox/[^]]*' | head -1)";; *) echo "FAIL: English query"; echo "$en"; exit 1;; esac
q=$("$CLI" find "how much does the headset cost" -k 3)
case "$q" in *"inbox/"*) echo "ok: question query hits";; *) echo "FAIL: question query"; echo "$q"; exit 1;; esac
dup=$("$CLI" ingest Tests/Fixtures/knowledge/vision-pro.md)
case "$dup" in *"already chewed"*) echo "ok: dedupe";; *) echo "FAIL: dedupe"; echo "$dup"; exit 1;; esac
ex=$("$CLI" extract Tests/Fixtures/ingest/sample.pptx)
case "$ex" in *"## Slide 1"*) echo "ok: pptx slides extracted";; *) echo "FAIL: pptx extract"; echo "$ex" | head -20; exit 1;; esac
case "$ex" in *"_Notes:_"*) echo "ok: speaker notes extracted";; *) echo "FAIL: speaker notes"; exit 1;; esac
pp=$("$CLI" ingest Tests/Fixtures/ingest/sample.pptx)
case "$pp" in *"filed inbox/"*) echo "ok: pptx filed";; *) echo "FAIL: pptx ingest"; echo "$pp"; exit 1;; esac
ls "$ROOT/Knowledge/inbox/references/" | grep -q -- "-sample.pptx" && echo "ok: pptx mirrored"
ls "$ROOT/Knowledge/inbox/references/" | grep -q "\.md$" && echo "ok: readable mirror next to it"
lint=$("$CLI" lint)
echo "$lint" | head -8
case "$lint" in *"orphan: entities/lonely-widget.md"*) echo "ok: orphan reported";; *) echo "FAIL: orphan not reported"; exit 1;; esac
case "$lint" in *"brokenLink: concepts/spatial-computing.md"*) echo "ok: broken link reported";; *) echo "FAIL: broken link not reported"; exit 1;; esac
test -f "$ROOT/Knowledge/meta/lint-$(date +%F).md" && echo "ok: lint page written"
grep -q "ingest |" "$ROOT/Knowledge/log.md" && echo "ok: log line"
echo "smoke-ingest: all good"
