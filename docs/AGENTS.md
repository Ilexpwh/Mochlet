# Connecting coding agents to Mochlet

Mochlet never launches or pins your agents. It watches the sessions you already run through
each agent's hook system: a tiny relay, `mochlet-hook`, is called by the agent for every
event, adds the terminal it runs in, and writes one JSON line to Mochlet's Unix socket.
Blocking hooks (permission requests, AskUserQuestion) keep the socket open until you answer
on the notch, or hand the decision back to the terminal.

```
~/Library/Application Support/Mochlet/
├── bin/mochlet-hook              # the relay (copied from Mochlet.app/Contents/Helpers on launch)
├── mochlet.sock                  # the socket (0600, same uid only)
└── statusline-previous.json      # your previous Claude statusLine, chained after Mochlet's
```

Settings → Agents installs the hooks for Claude Code, Codex and Gemini CLI: it shows the whole
new file before writing, keeps a dated `.bak-yyyyMMdd-HHmmss` next to the original, refuses to
write if the file changed in between, and removes only entries that mention `mochlet-hook`.

## Claude Code (also Cursor and Claude Desktop code sessions)

`~/.claude/settings.json` gets one group per event (`SessionStart`, `SessionEnd`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`,
`StopFailure`, `SubagentStart`, `SubagentStop` at 10 s; `PermissionRequest` at 120 s) plus a
`PreToolUse` group with `matcher: "AskUserQuestion"` running `mochlet-hook --ask` (130 s):

```json
{"hooks": [{"type": "command", "command": "\"/Users/you/Library/Application Support/Mochlet/bin/mochlet-hook\"", "timeout": 10}]}
```

The `statusLine` command becomes `"…/mochlet-hook" --statusline`. The relay forwards
`rate_limits` (the plan pills) and then runs your previous statusline command with the same
stdin, echoing its output unchanged, so nothing you had stops working. Removing the hooks
restores the saved command.

Replies: `PermissionRequest` → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny", "updatedPermissions": <permission_suggestions when Always>}}}`;
`ExitPlanMode` adds `updatedInput` and a `setMode` permission for Auto/Manual; "Change plan"
denies with `interrupt: true` and brings the terminal forward. `AskUserQuestion` →
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":…,"answers":{"<question>": "<label>" | ["a","b"]}}}}`.
"Reply in terminal", a timeout or a card that leaves the screen print nothing, so the agent
asks in its own interface.

Cursor's Claude Code sessions are recognised by the bundle id; Claude Desktop's by
`CLAUDE_CODE_ENTRYPOINT=claude-desktop`.

## Codex

`~/.codex/hooks.json`, same event names, command `/bin/sh "…/mochlet-hook" --agent codex`,
`PermissionRequest` carries `statusMessage: "Waiting for your answer in the notch (Mochlet)"`.
Codex ignores hooks until you run `/hooks` inside `codex` and trust them; the Agents tab shows
"Trusted." once `~/.codex/config.toml` holds the `[hooks.state]` entry for Mochlet's
SessionStart group (or once the first Codex event arrives). Codex has no "always allow", so
Always is hidden on its cards.

## Gemini CLI

`~/.gemini/settings.json` → `hooks` with `matcher: "*"` groups and millisecond timeouts:
`SessionStart`, `SessionEnd` (10000), `BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent`,
`Notification` (5000). The command names the normalised event
(`… --agent gemini PreToolUse`). Gemini requires JSON on stdout, so the relay always prints `{}`.

## Any other agent

Call the relay yourself with an agent tag (`^[a-z0-9-]{1,24}$`, `claude` reserved) and the
event name, piping the agent's JSON on stdin:

```sh
mochlet-hook --agent myagent PreToolUse < payload.json
```

Recognised payload keys (Claude Code's vocabulary, with the common aliases): `hook_event_name`
(or the `--agent`'s own names: `BeforeTool`, `preToolUse`, `pre_tool_use`, `AfterAgent`, `stop`…),
`session_id` / `conversationId` / `sessionId`, `cwd` / `workspacePaths[0]` / `workdir`,
`tool_name` / `toolName` / `toolCall.name`, `tool_input` / `toolArgs` / `toolCall.args`
(`CommandLine → command`, `FilePath → file_path`), `prompt`, `message`, `last_assistant_message`,
`transcript_path` (Claude's JSONL, for the session root and `/rename` title), `permission_suggestions`.

Relay output per agent after a permission decision: Claude/Codex/generic → the
`hookSpecificOutput` shape above; Copilot and Muse → `{"permissionDecision":"allow"|"deny"|"ask"}`;
Hermes → `{"choice":"once"|"always"|"deny"}`; Gemini, Antigravity, Muse and Copilot always
receive JSON (`{}` for plain events, `{"decision":"ask"}` for Antigravity's PreToolUse).
Set `MOCHLET_HOOK_DEBUG=1` to see what the relay did on stderr; `MOCHLET_SOCKET` overrides the
socket path (used by `scripts/test-hook.sh` with `scripts/fake-socket.py`).

## Socket protocol

One JSON object per connection, newline-terminated, at most 1 MB. Fields the relay adds:
`mochlet_agent`, `mochlet_kind` (`permission`, `ask_user_question`, `statusline`),
`mochlet_wait: true` when it will wait for a reply line, `session_root`, `session_title`, and the
terminal identity: `term_program`, `term_session_id`, `iterm_session_id`, `wezterm_pane`,
`kitty_window_id`, `ghostty`, `tmux_pane`, `tmux_socket`, `bundle_id`, `tty`, `shell_pid`,
`claude_entrypoint`, `vscode_ipc`. Mochlet answers blocking lines with
`{"permissionDecision": "allow" | "always" | "deny" | "ask" | "change_plan" | "answer", "mode"?: "auto"|"default", "answers"?: {…}}`
and closes. If the agent hangs up first (you answered in the terminal, or pressed Esc), the card
disappears with "Handled in <terminal>."

## What the notch does with events

| Event | Session card and slime |
|---|---|
| SessionStart | a mini slime pinches off the main one; `work` sound |
| UserPromptSubmit | thinking; the prompt becomes the ticker line |
| PreToolUse | working; "Reads · x", "Edits · y", "Runs · z", "server · tool" for MCP |
| PostToolUse (Edit, MultiEdit, Write, apply_patch) | a diff chip (+n −m) opens the diff view |
| Notification | a question mark for questions; rate limits turn the mini red |
| PermissionRequest | approval card, `!` on the mini; Allow / Always / Deny / Reply in terminal |
| AskUserQuestion | question card, chips and "Other…" |
| Stop | finished: happy jump, the first line of the answer as the final line; the island opens unless that terminal is frontmost |
| StopFailure | error face with the reason (rate limit, auth, overloaded…) |
| SessionEnd | the mini merges back |

The main slime mirrors the most urgent session (approval/question > error > working > idle).
Click a mini for its card, double-click it to jump to its terminal (`⌃⌥T` jumps to the focused
session: tmux pane, Terminal/iTerm tab by tty, WezTerm/kitty pane, Ghostty window, Cursor or
VS Code folder, else the terminal app).

## Replaying fixtures

```sh
scripts/replay-hooks.sh Tests/Fixtures/hooks/claude-session.jsonl 0.4     # a whole turn
scripts/replay-hooks.sh Tests/Fixtures/hooks/approval.json 0              # blocks until you answer
scripts/replay-hooks.sh Tests/Fixtures/hooks/question.json 0 --ask
scripts/replay-hooks.sh Tests/Fixtures/hooks/two-agents.jsonl 0.3
scripts/test-hook.sh                                                      # relay checks without the app
```
