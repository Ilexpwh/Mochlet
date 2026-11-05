#!/bin/zsh
# Exercises the built mochlet-hook relay against scripts/fake-socket.py.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$(swift build --show-bin-path)/mochlet-hook"
[ -x "$BIN" ] || swift build --product mochlet-hook >/dev/null
T="$(mktemp -d)"
export MOCHLET_SOCKET="$T/s.sock"
export HOME_SAVED="$HOME"
fail=0
waitsock() { for _ in $(seq 1 60); do [ -S "$MOCHLET_SOCKET" ] && return 0; sleep 0.05; done; echo "socket never appeared"; }
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: got '$1' expected '$2'"; fail=1; fi }

# 1. no server: exit 0, no output, fast
start=$(python3 -c 'import time;print(time.time())')
out=$(echo '{"hook_event_name":"PreToolUse","session_id":"x","tool_name":"Bash","tool_input":{"command":"ls"}}' | "$BIN"; echo "rc=$?")
end=$(python3 -c 'import time;print(time.time())')
check "$out" "rc=0" "no server exits 0 silently"
python3 -c "import sys; d=$end-$start; sys.exit(0 if d < 1.0 else 1)" && echo "ok   no server returns in under 1 s" || { echo "FAIL slow: $(python3 -c "print($end-$start)")"; fail=1; }

# 2. non-blocking event is delivered with identity fields and normalised names
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --log "$T/1.log" > "$T/srv.out" & waitsock
out=$(echo '{"hook_event_name":"BeforeTool","conversationId":"c1","toolCall":{"name":"run_shell_command","args":{"CommandLine":"ls"}}}' | TERM_PROGRAM=iTerm.app "$BIN" --agent gemini)
wait
check "$out" "{}" "gemini gets {}"
line=$(cat "$T/1.log")
check "$(echo "$line" | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o["hook_event_name"], o["mochlet_agent"], o["session_id"], o["tool_name"], o["tool_input"]["command"], o["term_program"], bool(o.get("cwd")))')" "PreToolUse gemini c1 run_shell_command ls iTerm.app True" "gemini payload normalised"

# 3. PermissionRequest → Claude format with Always + suggestions
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --log "$T/2.log" --reply '{"permissionDecision":"always"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"rm x"},"permission_suggestions":[{"type":"addRules"}]}' | "$BIN")
wait
check "$out" '{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules"}]},"hookEventName":"PermissionRequest"}}' "always → updatedPermissions"
check "$(python3 -c 'import json; o=json.loads(open("'"$T/2.log"'").read()); print(o["mochlet_wait"], o["mochlet_kind"])')" "True permission" "permission line waits"

# 4. deny, codex always → plain allow, copilot ask on timeout-less no-decision
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --reply '{"permissionDecision":"deny"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{}}' | "$BIN"); wait
check "$out" '{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Mochlet"},"hookEventName":"PermissionRequest"}}' "deny"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --reply '{"permissionDecision":"always"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{}}' | "$BIN" --agent codex); wait
check "$out" '{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}' "codex always is a plain allow"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --reply '{"permissionDecision":"ask"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"permissionRequest","sessionId":"s","toolName":"bash","toolArgs":{}}' | "$BIN" --agent copilot); wait
check "$out" '{"permissionDecision":"ask"}' "copilot ask stays ask"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --reply '{"permissionDecision":"allow","mode":"auto"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"ExitPlanMode","tool_input":{"plan":"# P"}}' | "$BIN"); wait
check "$out" '{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"plan":"# P"},"updatedPermissions":[{"destination":"session","mode":"auto","type":"setMode"}]},"hookEventName":"PermissionRequest"}}' "plan auto mode"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --reply '{"permissionDecision":"allow"}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{}}' | "$BIN" --agent hermes); wait
check "$out" '{"choice":"once"}' "hermes once"

# 5. --ask
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --log "$T/3.log" --reply '{"permissionDecision":"answer","answers":{"Which?":"A"}}' > /dev/null & waitsock
out=$(echo '{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}}' | "$BIN" --ask); wait
check "$out" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"answers":{"Which?":"A"},"questions":[{"options":[{"label":"A"},{"label":"B"}],"question":"Which?"}]}}}' "ask answer shape"
check "$(python3 -c 'import json; o=json.loads(open("'"$T/3.log"'").read()); print(o["mochlet_kind"])')" "ask_user_question" "ask line kind"
out=$(echo '{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{}}' | "$BIN" --ask)
check "$out" "" "--ask ignores other tools"

# 6. statusline chaining
export HOME="$T/home"; mkdir -p "$HOME/Library/Application Support/Mochlet"
echo '{"type":"command","command":"cat >/dev/null; printf \"[prev %s]\" \"$X\""}' > "$HOME/Library/Application Support/Mochlet/statusline-previous.json"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --log "$T/4.log" > /dev/null & waitsock
out=$(echo '{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":12}},"model":{"display_name":"Opus"}}' | X=line "$BIN" --statusline); wait
check "$out" "[prev line]" "previous statusline runs with its stdin"
check "$(python3 -c 'import json; o=json.loads(open("'"$T/4.log"'").read()); print(o["mochlet_kind"], o["rate_limits"]["five_hour"]["used_percentage"], o["model"]["display_name"])')" "statusline 12 Opus" "statusline forwarded"
out=$(echo 'garbage' | "$BIN" --statusline)
check "$out" "[prev ]" "statusline tolerates bad stdin"
export HOME="$HOME_SAVED"

# 7. transcript session name
printf '{"cwd":"/Users/me/root","type":"x"}\n{"type":"custom-title","customTitle":"Nice name"}\n' > "$T/t.jsonl"
python3 scripts/fake-socket.py "$MOCHLET_SOCKET" --log "$T/5.log" > /dev/null & waitsock
echo "{\"hook_event_name\":\"Stop\",\"session_id\":\"s\",\"transcript_path\":\"$T/t.jsonl\"}" | "$BIN" >/dev/null; wait
check "$(python3 -c 'import json; o=json.loads(open("'"$T/5.log"'").read()); print(o["session_root"], o["session_title"])')" "/Users/me/root Nice name" "session root and title from transcript"

# 8. bad stdin
out=$(echo 'nope' | "$BIN" --agent copilot permissionRequest)
check "$out" '{"permissionDecision":"ask"}' "copilot fail-closed on bad stdin"
out=$(echo '' | "$BIN"); check "$out" "" "empty stdin silent"

rm -rf "$T"
[ $fail = 0 ] && echo "all relay checks passed" || { echo "relay checks FAILED"; exit 1; }
