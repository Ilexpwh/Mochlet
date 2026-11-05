<!-- Reference notes extracted on 2026-11-05 from the Coucou source (MIT, /Users/ilex.poon/Coucou) to guide Mochlet's own implementation. Facts about Coucou, not Mochlet's design. -->

# Coucou hook relay and socket server: spec

Sources: `/Users/ilex.poon/Coucou/NotchBuddy/Sources/App/HookServer.swift` (the relay script strings are at lines 3237–3973), `ApprovalQueue.swift`, `PillSessionRegistry.swift`, `ClaudeHost.swift`, `AskQuestion.swift`, `ClaudePlanGauge.swift`, `CoucouKit/DiffEngine.swift`, `AppState.swift`, plus `/Users/ilex.poon/Coucou/docs/AGENTS.md` and `/Users/ilex.poon/Coucou/docs/INTEGRATIONS.md`.

**Corrections to the brief and docs, found in the code:**
- The agent tag field is **`coucou_agent`**. The names `nb_agent` and `mochi_agent` appear nowhere. There is also a `coucou_kind` field.
- **There is no tty detection.** INTEGRATIONS.md says the relay finds the tty by walking parent processes. The relay code never does this, and no file in Sources contains the word `tty`.
- The relay sends `iterm_session_id` and `term_session_id`, but the app never reads them. It only uses `term_program`, `bundle_id` and `cwd`.
- INTEGRATIONS.md says the question answer is `{"decision":"answer",...}`. The code uses the key `permissionDecision`.

---

## 1. Relay CLI (`nb-hook` shell wrapper and `nb-hook.py`)

**Files.** The GitHub build writes `nb-hook` (mode 0755) and `nb-hook.py` (0755) at every launch, into `~/Library/Application Support/NotchBuddy/`. That folder is set to 0700. The App Store build writes them to `~/.claude/coucou/` when hooks are installed. The two Python scripts are identical except for the socket path.

**Shell wrapper `nb-hook`:**
- It runs Python only if `xcode-select -p` succeeds. The command is `out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)`.
- If Python exits non-zero, `out` is cleared.
- If `out` is not empty, it prints `out` plus a newline.
- If `out` is empty, it applies a fail-closed rule for Copilot only. When any argument equals `copilot`:
  - if any argument is `permissionRequest` or `PermissionRequest`, it prints `{"permissionDecision":"ask"}`;
  - otherwise it prints `{}`.
- It always exits 0.

**Arguments:**
- `--statusline`: anywhere in argv.
- `--ask`: anywhere in argv.
- `--agent <name>`: the next argument is the agent name.
- The first other argument is the fallback event name (`arg_event`).
- The modes are checked in this order: `--statusline`, then `--ask`, then normal.

**Reading stdin.** The relay reads all of stdin as bytes and parses it as JSON.
- Empty stdin, or a JSON error, makes it return with no output. The exception is `--statusline` mode, which carries on with `payload={}`.
- The whole of `main()` sits inside `try/except: pass`, followed by `sys.exit(0)`. The exit code is always 0.

**Normal mode, in order:**
1. If `--agent` was given, `payload.setdefault('coucou_agent', agent)`. A value already in the payload wins.
2. If `coucou_agent` is still empty and the environment has `CLAUDE_CODE_ENTRYPOINT == 'claude-desktop'`, set `coucou_agent = 'claude-desktop'`.
3. Terminal identity, all with `setdefault`:

   | Payload key | Source environment variable |
   |---|---|
   | `term_program` | `TERM_PROGRAM` |
   | `iterm_session_id` | `ITERM_SESSION_ID` |
   | `term_session_id` | `TERM_SESSION_ID` |
   | `bundle_id` | `__CFBundleIdentifier` |

   Each defaults to `''`.
4. `cwd`: if it is missing or empty, use `workspacePaths` or `workspace_roots`, taking element `[0]` if it is a non-empty list. Otherwise use `os.getcwd()`.
5. `add_session_name`, only if `transcript_path` is set:
   - **`session_root`**: read the first **16384 bytes** of the transcript, split into lines, and take the `cwd` of the first JSON line that has a truthy one.
   - **`session_title`**: seek to max(0, size − **65536**) and read to the end. If the start is not 0, drop the first (partial) line. Scan the lines in reverse; the first one containing the bytes `"custom-title"` supplies `customTitle`, if truthy. The scan stops at that line either way.
   - Any exception is ignored.
6. Event name: `raw = payload.hook_event_name or arg_event`, then `hook_event_name = normalize_event(raw)`.
7. `normalize_tool_fields`, described below.

**`normalize_event` mapping.** Any name not listed passes through unchanged.

| Incoming name(s) | Normalised |
|---|---|
| `BeforeTool`, `BeforeToolSelection`, `pre_tool_use`, `preToolUse` | `PreToolUse` |
| `AfterTool`, `AfterModel`, `PostInvocation`, `post_tool_use`, `postToolUse` | `PostToolUse` |
| `BeforeAgent`, `PreInvocation`, `user_prompt_submit`, `userPromptSubmitted` | `UserPromptSubmit` |
| `AfterAgent`, `stop`, `agentStop` | `Stop` |
| `startup`, `session_start`, `sessionStart` | `SessionStart` |
| `exit`, `session_end`, `sessionEnd` | `SessionEnd` |
| `notification` | `Notification` |
| `permissionRequest` | `PermissionRequest` |

**`normalize_tool_fields`:**
- **`tool_name`**, if absent: use `toolName` (Copilot). Otherwise use `toolCall.name` (when `toolCall` is a dict), or `payload.tool`. It is set only if truthy.
- **`tool_input`**, if absent: use `toolArgs` if it is a dict. Otherwise, if `toolCall.args` is a dict, copy it and add aliases: `CommandLine→command`, `FilePath→file_path`, `Path→path`, `Url→url`, `Query→query`, `Pattern→pattern`. The original keys are kept.
- **`session_id`**, if absent: the first truthy value of `conversationId`, `conversation_id`, `sessionId`, `GEMINI_SESSION_ID` in the payload, else the environment variable `GEMINI_SESSION_ID`.
- **`cwd`**: if `cwd` is empty and `workdir` is set, use `workdir`. This never fires in practice, because step 4 has already set `cwd`.

**Socket and framing.**
- Socket paths: `~/Library/Application Support/NotchBuddy/nb.sock` (GitHub) and `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock` (App Store).
- Each message is `json.dumps(payload) + "\n"` on a new AF_UNIX stream connection.
- Fire-and-forget sends use `settimeout(0.3)`, then connect, send everything, close. Errors are ignored.
- Blocking replies are read in 4096-byte `recv` chunks until EOF or until a chunk contains `\n`. The result is decoded, stripped and parsed as JSON. Only `permissionDecision` is read, plus `mode` and `answers`.

**Output after non-blocking events.** This is printed whether or not the socket send worked. `agent` here means the `--agent` argument only.
- Agent `antigravity` and event `PreToolUse`: prints `{"decision":"ask"}`.
- Agents `gemini`, `antigravity`, `muse`, `copilot`: print `{}`.
- Everyone else (Claude, Codex, OpenCode, Amp, Hermes, claude-desktop): no output.

**`--ask` mode** (Claude Code's `PreToolUse` with `matcher:"AskUserQuestion"`):
- If `tool_name != 'AskUserQuestion'`, it returns with no output.
- Otherwise it sets `coucou_kind='ask_user_question'` and adds the same terminal-identity, cwd and session-name fields. It does not run agent parsing or normalisation.
- It sends with **settimeout(125)** and waits.
- If the reply has `permissionDecision=='answer'`, it prints:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":<tool_input.questions>,"answers":<answers>}}}`
- For anything else (`ask`, a timeout, no app), it prints nothing.

## 2. Blocking `PermissionRequest`: relay output per agent

The relay sends with **settimeout(118)**. `decision` is the reply's `permissionDecision`.

**Hermes** (`agent=='hermes'`): it maps `allow` to `once`. If the result is one of `once`, `always`, `deny`, it prints `{"choice":"<x>"}`. Otherwise it prints nothing. It exits right after.

**Copilot or Muse:**
- `allow` or `always` → `{"permissionDecision":"allow"}`
- `deny` → `{"permissionDecision":"deny"}`
- `answer` and `change_plan` fall into the Claude-format branches below.

**Claude Code, Codex and others:**
- `allow` → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
- `always` when the agent is not Codex: the same, plus `"updatedPermissions": payload.permission_suggestions`, which defaults to `[]`. For Codex, `always` gives a plain allow.
- **ExitPlanMode**: when `tool_name=='ExitPlanMode'` and the output uses `hookSpecificOutput`, add `decision.updatedInput = tool_input`. If the reply has `mode` set to `auto` or `default`, set `decision.updatedPermissions = [{"type":"setMode","mode":<mode>,"destination":"session"}]`. This replaces any suggestions.
- `deny` → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}`
- `answer` (legacy AskUserQuestion) → `...decision:{"behavior":"allow","updatedInput":{"questions":...,"answers":...}}`
- `change_plan` → `...decision:{"behavior":"deny","interrupt":true,"message":"The user wants to change the plan and will type the changes in the terminal."}`

**No decision** (`ask`, unknown value, timeout, app not running): no output, so the agent asks in its own interface. The exception is **Copilot**, which always gets `{"permissionDecision":"ask"}`.

**Antigravity and Gemini** have no PermissionRequest mapping. **OpenCode** sends `PermissionRequest` from `permission.asked`, fire-and-forget through spawn. The app answers it `ask` right away, since it is not a card agent. **Amp's** `tool.call` handler returns `{action:'allow'}` and only displays events.

**App-side reply lines.** The app answers with one JSON line followed by `\n`:

| App decision | Line written to the relay |
|---|---|
| `allow` | `{"permissionDecision":"allow"}` |
| `always` | `{"permissionDecision":"always"}` |
| `ask` | `{"permissionDecision":"ask"}` |
| `plan_auto` | `{"permissionDecision":"allow","mode":"auto"}` |
| `plan_default` | `{"permissionDecision":"allow","mode":"default"}` |
| `plan_change` | `{"permissionDecision":"change_plan"}`, then the terminal app is activated |
| anything else | `{"permissionDecision":"deny"}` |
| question answered | `{"permissionDecision":"answer","answers":{"<question text>":"<label>" or ["a","b"] for multiSelect}}` |

Unanswered requests:
- **Approval timeout**: the connection closes with no line (EOF), and the card shows the "Still waiting in X." note. The timeout is 110 s for Copilot and Muse, 115 s for everyone else.
- **Question timeout**: after 120 s the app sends `ask`.
- **Question card leaves the screen** (`releaseQuestionFD`): sends `ask`.
- **"Reply in terminal"** button: sends `ask`.

## 3. Statusline forwarding

**Relay (`--statusline`):**
- It sends `{"coucou_kind":"statusline","session_id":payload.session_id or "","rate_limits":payload.rate_limits or {}}` fire-and-forget with a 0.3 s timeout.
- It then looks for `statusline-previous.json` in the script's own folder (`dirname(abspath(__file__))`). If the file has a `command`, it runs `['/bin/sh','-c',cmd]` with the **raw stdin bytes** as input, `capture_output`, and **timeout=10**. Stdout bytes are written back unchanged, ANSI codes included. Stderr is dropped.

**Installer:**
- The command is `"<nb-hook path>" --statusline`. It is quoted and has no `/bin/sh` prefix.
- Python must be available: `xcode-select -p` must succeed, or the installer fails with "Command Line Tools are required…".
- If a `statusLine` exists whose command does not contain `nb-hook`, only `command` is replaced. The original object is saved as pretty-printed, sorted-keys JSON to `supportDir/statusline-previous.json`, written only after `settings.json` is written successfully.
- If it is already ours, the command is refreshed.
- If there is none, it creates `{"type":"command","command":...}`.

**Uninstall:** only if the current command contains `nb-hook`. It restores the saved object and deletes the file. Without a saved file it removes the `statusLine` key.

**App parsing:**
- `rate_limits.five_hour` and `rate_limits.seven_day` each carry `used_percentage` (Int or Double) and `resets_at` (epoch seconds).
- A percentage outside 0–200 is rejected; values from 100 to 200 are clamped to 100.
- `resets_at` must be > 0 and at most now + 400 days.
- The payload is ignored if both windows are missing.
- An update is published only if a value changed, or if 30 s or more have passed since the last one.

## 4. Socket server

**Path.** `supportDir/nb.sock` (GitHub) or `NSHomeDirectory()+"/nb.sock"` (App Store). The path must be at most 103 bytes. Any old socket file is removed first.

**Setup:** `socket(AF_UNIX, SOCK_STREAM)`, `bind`, `chmod 0600`, `listen(fd, 32)`.

**Accept loop, on a background thread:**
- `getpeereid` must succeed and `euid == getuid()`, otherwise the connection is closed.
- A connection counter is capped at **32**; above that the connection is closed.
- Each client gets a detached thread.

**Client handling:**
- `SO_RCVTIMEO` is **5 s**.
- `recv` reads 4096-byte chunks until the first `\n` (anything after it is dropped), or until `n<=0`, or until the buffer passes **1,048,576** bytes.
- Empty input, or anything that is not a JSON object: reply `{"ok":true}` and close.
- `coucou_kind=="statusline"`: process it, reply `{"ok":true}`, close.
- `coucou_kind=="ask_user_question"`: `AskQuestion.parse(tool_input)` must succeed (rules in section 5). Then the fd is kept open. If parsing fails, reply `{"permissionDecision":"ask"}` and close.
- `hook_event_name=="PermissionRequest"`: the fd is kept open.
- Anything else: `processEvent` runs on the main actor; reply `{"ok":true}` and close.

**Held connections:**
- A main-queue `DispatchSource.makeReadSource(fd)` watches each one. Any readable event, normally EOF because the agent answered elsewhere, drops the request and shows "Handled in Cursor/Codex/Copilot CLI/Muse Code/Hermes/<host>.".
- The fd is closed only in the source's cancel handler.
- Replies are written with a `send` loop (text plus `\n`), then the source is cancelled.

**Approval queue:** FIFO, **max 5** waiting at once. A 6th request is answered `ask`. The card shows the oldest. A click carries the request id; a click for a request that is no longer at the head is ignored.

**Only one question at a time.** A new question displaces the old one, which is answered `ask`.

## 5. Event routing in the app

**Session id:** `session_id ?? conversation_id ?? "unknown"`. For recaps, when the id is `"unknown"` or empty, the key is `"<pillId>+<cwd>"`.

**Display name:**
1. `session_title`
2. else the last path component of `session_root`, or of `cwd` if there is no root
3. else `"Session"`

The aliases `notch-buddy`, `notchbuddy` and `notch_buddy` all become "Notch Buddy".

**Agent validation:** `^[a-z0-9-]{1,24}$`, and `"claude"` is rejected.

**Pill selection, first match wins:**
1. **`coucou_agent=="codex"`** (GitHub build only) → `agent_codex`, treated as a workspace pill.
2. **Any other valid agent** → `agent_<name>`, an external pill. Its name is the agent name, and it is inserted after `integration_claude`. This includes `claude-desktop` → `agent_claude-desktop`.
3. **Cursor**: `bundle_id.lowercased()=="com.todesktop.230313mzl4w4u92"` → `agent_cursor`.
4. **VS Code**: not Cursor, and `term_program` or `bundle_id` (lowercased) contains `"vscode"` → `integration_claude`, with `hostApp=nil`.
5. **Known terminal** (`ClaudeHost.terminal`) → `integration_claude`, with `hostApp` set to that terminal's bundle id. Matching is by bundle id first, then by `TERM_PROGRAM` (lowercased).
   - Bundle ids: `dev.warp.Warp-Stable`, `dev.warp.Warp-Preview`, `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`, `co.zeit.hyper`, `dev.zed.Zed`, `com.cmuxterm.app`, `com.stablyai.orca`, `com.conductor.app`.
   - `TERM_PROGRAM` values: `warpterminal`, `apple_terminal`, `iterm.app`, `ghostty`, `kitty`, `alacritty`, `wezterm`, `hyper`, `zed`.
6. **Anything else** is ignored and logged.

When `hostApp` is the frontmost app, Stop and StopFailure play no sound and do not open the island; the pill only gets a badge.

**Who gets cards:**
- **PermissionRequest cards** go to codex, copilot, muse, Cursor and VS Code. Hermes gets one only if the `UserDefaults` key `hermesApprovalsEnabled` is on and the payload has `coucou_has_transport==true`. Terminal sessions get one only if `UserDefaults` `terminalCardsEnabled` is on.
- Every other case gets an immediate `ask`, including any other valid `coucou_agent`, and `tool_name=="AskUserQuestion"`.
- The card's command line is `tool_input.command`, falling back to the tool name. For ExitPlanMode it is the plan's first non-empty line with leading `#` and spaces removed, or "Plan".
- **Question cards** go to codex, Cursor, VS Code, and terminals with the setting on.
- `AskQuestion.parse` requires 1–4 questions. Each needs a non-empty `question` and 2–4 options with non-empty `label`. `header` is cut to its first 12 characters and `multiSelect` defaults to false.

**Waiting approvals and other events:**
- An event removes waiting approvals from the same pill and session:
  - `PostToolUse` or `PostToolUseFailure` removes those with the same tool and the same `inputKey` (the `tool_input` serialised with sorted keys);
  - `Stop`, `StopFailure`, `UserPromptSubmit`, `SessionEnd` or `Interrupt` removes all of them.
- Removed requests show the "Handled in…" note.
- After that, any event from a session that still has an approval waiting is **dropped**.
- When the pill still has approvals, it goes back to the `.approval` state after each event.

**What each event does.** "Steps" are the ticker lines; at most **20** are kept.

| Event | Effect |
|---|---|
| `SessionStart` | Creates or updates the pill without marking it working; clears `finalLine`; opens the overview; plays sound `work`. For Hermes, if `platform` is set and not `cli`, adds the platform name (first letter capitalised) as a step. |
| `UserPromptSubmit` | Marks working; clears `finalLine`; state `.thinking`; adds a step with the first **60** characters of `prompt`. |
| `PreToolUse` | Clears `finalLine`; skipped if the tool is `AskUserQuestion`. Otherwise marks working. A tool named `ask_question` or ending in `:ask_question` sets `.question`, plays sound `question` and opens the overview; any other tool sets `.working`. Adds the step label below. |
| `PostToolUse` | State `.working`. If a diff can be built, stores it and adds a diff step. |
| `PostToolUseFailure` | State `.working`; adds step `⚠ failed`. |
| `Notification` | If the lowercased `message` contains `rate limit` or `limite d`: state `.ratelimit`, sound `rate`, no step. Else if the message ends with `?`: state `.question` and the message becomes a step. |
| `Stop` | Ends the session's turn. Final text is `last_assistant_message ?? message`, passed through `DiffEngine.toOneLine` (first non-empty paragraph, markdown removed, max **200** characters), and added as a step when not empty. If no other session on this pill is mid-turn: state `.finished`, `finalLine` set to the text, sound `finish`, then either open the island to the finished view or set badge `.finished`. **5.2 s** later, if no session on the pill is working, an external pill is removed and any other pill goes idle with its badge cleared. |
| `StopFailure` | Ends the turn. If no other session is mid-turn: state `.error`; `finalLine` = `stopFailureDetail` (see below); sound `error`; open to the error view or set the error badge. |
| `Interrupt` (Codex) | Ends the turn. If no other session is mid-turn: state idle, badge cleared. |
| `SessionEnd` | Only when it is the last live session on the pill: clears `finalLine` and the diffs, then `removeTask`. A pill that is declared in the catalog and active, or is the main pill, is reset to idle (name back to the catalog name) instead of removed. |
| `SubagentStart` | Step `+ subagent`. |
| `SubagentStop` | Step `• subagent done`. |

**`stopFailureDetail`:**
- The first non-blank value of `error_message`, `error_details`, `message`, or `error.message`.
- Otherwise a sentence chosen by `error_type`, or by `error` when it is a string: `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `billing_error`, `server_error`, `max_output_tokens`, `model_not_found`.
- Otherwise `last_assistant_message` if it contains "error" (case-insensitive).
- Otherwise the `kind` string itself, if it is longer than 3 characters, not a number, and not "unknown". Else nil.

**Ticker label for `PreToolUse`:**
- Base labels:

  | Label | Tools |
  |---|---|
  | `Runs` | `Bash` |
  | `Reads` | `Read` |
  | `Writes` | `Write` |
  | `Edits` | `Edit`, `MultiEdit`, `apply_patch` |
  | `Searches` | `Glob`, `Grep` |
  | `Searches the web` | `WebSearch` |
  | `Fetches` | `WebFetch` |
  | `Tasks` | `TodoWrite`, `update_plan` |
  | `Agent` | `Task`, `spawn_agent` |
  | `Lists` | `LS` |
  | `Notebook` | `NotebookEdit` |
  | `Needs input` | `ask_question`, or any tool ending in `:ask_question` |

  An unknown tool shows its own name.
- **MCP tools:** `mcp__server__tool` shows as `"server · tool"`. Any extra parts are joined with `__`. If there is only one part, the label is that part.
- **`Bash`:** `"<bashVerb> · <oneLine(command)>"`. The verb comes from the first word of the command:
  - `cat`, `bat`, `head`, `tail`, `less`, `more`, `nl` → `Reads`
  - `rg`, `grep`, `find`, `fd`, `ls`, `tree`, `wc` → `Searches`
  - otherwise, if the command contains any of `pytest`, `vitest`, `jest`, `npm test`, `npm run test`, `cargo test`, `go test`, `swift test`, `make test`, `xcodebuild test`, `unittest` → `Tests`
  - otherwise `Runs`
- **`apply_patch`:** `tool_input.command` is scanned for the first line starting with `*** Update File: `, `*** Add File: ` or `*** Delete File: `. The label becomes `"Edits · <file name>"`, or just `Edits` if none is found.
- **ask_question tools:** `"Needs input · <oneLine(questions[0].question)>"`.
- **Everything else:** the label plus ` · ` and the first field present, in this order: `command` (one line), `path` (file name), `file_path` (file name), `query` (one line). If none is present, just the label.
- `oneLine` joins lines and tabs with a single space and cuts at **60** characters, adding `…`.

**Diffs, on `PostToolUse` only:**
- `Edit` needs `old_string`, `new_string` and `file_path`.
- `MultiEdit` needs `file_path` and `edits[]`, each with `old_string` and `new_string`. The totals are summed and the hunks combined.
- `Write` needs `file_path` and a non-empty `content`; every line counts as added.
- A diff with 0 lines added and 0 removed is dropped.
- **`apply_patch` produces no diff**; it only changes the ticker label.
- Limits: if old + new exceeds **200 KiB**, or **4000** lines combined, or the product of the two line counts exceeds **1,000,000**, only counts are stored (`tooLarge`). Hunks keep **3** lines of context.
- At most **50** diffs are kept per pill, oldest dropped first. All of them are cleared **3600 s** after the last diff was added, or at SessionEnd.
- The step string is `"\u{E001}<filename>\t<added>:<removed>:<diffId>"`.

**Several sessions on one pill (`PillSessionRegistry`):**
- The name, cwd and terminal shown on the pill come from one owning session: the oldest session that is mid-turn, else the one that worked most recently, else the oldest.
- Sweeps: a session silent for **12 h** is dropped; a mid-turn session silent for **30 min** stops counting as working.
- `Stop`, `StopFailure` and `Interrupt` affect the whole pill only when no other session is working.

## 6. Constants

| What | Value |
|---|---|
| Relay timeout, fire-and-forget | 0.3 s |
| Relay timeout, PermissionRequest | 118 s |
| Relay timeout, `--ask` | 125 s |
| Previous statusline command timeout | 10 s |
| Transcript head read | 16384 B |
| Transcript tail read | 65536 B |
| Server max payload | 1,048,576 B |
| Server receive timeout (`SO_RCVTIMEO`) | 5 s |
| Max concurrent connections | 32 |
| `listen` backlog | 32 |
| `recv` chunk size | 4096 |
| Approval queue max | 5 |
| Approval timeout | 115 s (Copilot/Muse 110 s) |
| Question timeout | 120 s |
| Finished-state reset | 5.2 s |
| Note display before collapse | 3 s |
| Steps kept per pill | 20 |
| Prompt step length | 60 chars |
| `oneLine` cut | 60 chars |
| Final line (`toOneLine`) | 200 chars |
| Agent name length | ≤ 24 |
| Question header | ≤ 12 chars |
| Questions per card | 1–4 |
| Options per question | 2–4 |
| Statusline publish throttle | 30 s |
| Session sweep (silent) | 12 h |
| Turn sweep (mid-turn silent) | 30 min |
| Diff limits | 200 KiB / 4000 lines / 1e6 line product |
| Diffs kept per pill | 50 |
| Diff expiry | 1 h |

**Hook timeouts written by the installers:**
- **Claude** (`~/.claude/settings.json`): all events 10 s, `PermissionRequest` 120 s. The command has no event argument. A separate `PreToolUse` entry with `matcher:"AskUserQuestion"` runs `<cmd> --ask` with a 130 s timeout. The GitHub command is the quoted path; the App Store command is `/bin/sh "<path>"`.
- **Codex** (`~/.codex/hooks.json`): `--agent codex` with no event argument. 10 s, except `Interrupt` and `SessionEnd` at 3 s and `PermissionRequest` at 120 s with `statusMessage` "Waiting for your answer in the notch (Coucou)".
- **Gemini** (`~/.gemini/settings.json`): timeouts in ms, matcher `*`, and the event argument is already normalised. `SessionStart` and `SessionEnd` 10000, the others 5000.
- **Antigravity** (`~/.gemini/config/hooks.json`, under the `"coucou"` key): 10 s each.
- **Copilot** (`~/.copilot/hooks/coucou.json`): entries use `bash` and `timeoutSec`, with the camelCase event name as argument; the file also gets `"version":1`. 10 s, except `permissionRequest` 120 s and `sessionEnd` 3 s.
- **Muse** (`~/.config/muse/settings.json`): timeouts in ms. `SessionStart` 10000, `PermissionRequest` 120000, `SessionEnd` 3000, others 5000.
