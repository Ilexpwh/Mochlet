<!-- Reference notes extracted on 2026-11-05 from the Coucou source (MIT, /Users/ilex.poon/Coucou) to guide Mochlet's own implementation. Facts about Coucou, not Mochlet's design. -->

# Coucou installers and plan gauges: spec from the code

Sources read:
- `/Users/ilex.poon/Coucou/NotchBuddy/Sources/App/ClaudeSettingsFile.swift`
- `/Users/ilex.poon/Coucou/NotchBuddy/Sources/App/HookServer.swift` (installers at lines 1364–3222; shell wrapper at 3237; Python relay at 3273–3622; App Store relay copy at 3626+)
- `/Users/ilex.poon/Coucou/NotchBuddy/Sources/App/ClaudePlanGauge.swift`, `ClaudePlanCardView.swift`, `CodexPlanGauge.swift`, `ClaudeHookDetection.swift`, `AppState.swift` (lines 471–520)
- `/Users/ilex.poon/Coucou/docs/INTEGRATIONS.md` (sections 1 and 1bis), `/Users/ilex.poon/Coucou/docs/AGENTS.md`
- `/Users/ilex.poon/Coucou/windows/src-tauri/src/agents.rs`, only for Cursor and the Codex trust note

**Two direct answers first:**
- **Codex hash-bound trust in `config.toml`:** nothing in this repo has it — not the macOS app, Windows or Linux. Nothing reads or writes `~/.codex/config.toml`, and the app never checks whether the hooks are trusted. After install, the app only shows the text "Hooks installed — open Codex and run /hooks or open Hooks in app settings to approve them". Windows says: "Codex runs new hooks only once you trust them: start Codex and review them once with /hooks." Any trust detection would have to be designed from scratch.
- **Cursor on macOS:** there is no separate installer. Cursor sessions use the Claude Code hooks in `~/.claude/settings.json` and share their installed state. Only the Windows build writes `~/.cursor/hooks.json` (see §1.11).

---

## 0. The relay files every installer points at (GitHub build)

- **Folder:** `supportDir = ~/Library/Application Support/NotchBuddy/`, set to mode 0700.
- **Files:** `nb-hook` (shell wrapper, 0755) and `nb-hook.py` (Python relay, 0755). Both are rewritten at every app launch by `installHookScript()`.
- **App Store build:** writes them to `~/.claude/coucou/` instead, at the moment hooks are installed.
- **Socket:** `~/Library/Application Support/NotchBuddy/nb.sock`. Each message is one JSON line ending in `\n`.

**Hook command strings:**
- Claude Code (GitHub build): `"<hookScriptPath>"` — the path in double quotes, any `"` inside escaped as `\"`, no `/bin/sh`.
- Claude Code (App Store build): `/bin/sh "<path>"`.
- Every other agent (`hookBase()`): `/bin/sh "<hookScriptPath>"`.

**Shell wrapper `nb-hook`:**
- Runs `/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@"`, but only if `xcode-select -p` succeeds.
- Prints the Python output if there was any.
- If not, and the arguments include `copilot`: prints `{"permissionDecision":"ask"}` when the arguments also include `permissionRequest` or `PermissionRequest`, otherwise `{}`.
- Always `exit 0`.

**Python relay — argument modes:**
- `--statusline`: see §2.
- `--ask`: AskUserQuestion. Socket timeout 125 s. On an `answer` from the app it prints:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":…,"answers":…}}}`
- `--agent <name> [Event]`: sets `coucou_agent`. The positional argument is used as the event name only when the payload has no `hook_event_name`.
- If there is no `coucou_agent` and `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, it sets `coucou_agent: "claude-desktop"`.

**Python relay — payload handling:**
- Adds `term_program`, `iterm_session_id`, `term_session_id` and `bundle_id` (from `__CFBundleIdentifier`).
- Fills `cwd` from `workspacePaths[0]`, else `workspace_roots[0]`, else the process's current directory.
- Reads the transcript (if any) for `session_root` and `session_title`.
- Translates event names with `normalize_event`, and tool fields from `toolName`, `toolArgs` or `toolCall.{name,args}`. Session id comes from `conversationId`, `conversation_id`, `sessionId`, `GEMINI_SESSION_ID`, or the `GEMINI_SESSION_ID` environment variable. `workdir` becomes `cwd`.

**Python relay — PermissionRequest (blocks for the user's answer):**
- Socket timeout 118 s.
- Hermes: prints `{"choice":"once"|"always"|"deny"}` (`allow` is sent as `once`).
- Copilot and Muse: `{"permissionDecision":"allow"}` or `{"permissionDecision":"deny"}`.
- Claude Code and Codex, allow: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`.
- "Always" (every agent except Codex): adds `"updatedPermissions": <payload.permission_suggestions>`.
- `ExitPlanMode`: adds `updatedInput` (the tool input). If the app also sent `mode` (`auto` or `default`), adds `updatedPermissions:[{"type":"setMode","mode":…,"destination":"session"}]`.
- Deny: `"behavior":"deny","message":"Denied from Coucou"`.
- `change_plan`: `"behavior":"deny","interrupt":true,"message":"The user wants to change the plan and will type the changes in the terminal."`
- `ask`, no answer, or timeout: prints nothing, except Copilot, which gets `{"permissionDecision":"ask"}`.

**Python relay — every other event:**
- Fire-and-forget, socket timeout 0.3 s.
- Then prints `{"decision":"ask"}` for Antigravity on `PreToolUse`, or `{}` for gemini, antigravity, muse and copilot.

---

## 1. Per-agent installers

There are two write paths:
- **(A)** Claude Code `settings.json` uses `ClaudeSettingsFile` (§3).
- **(B)** Every other agent: at preview, take the SHA-256 of the current bytes (empty `Data` if the file is absent). At write, recompute it; on mismatch, error "`<path>` changed since preview. Refresh and try again." Then `writeJSONFile` (§3).

JSON is written with `JSONSerialization` options `[.prettyPrinted, .sortedKeys]`. Path (B) and the statusLine writer also add `.withoutEscapingSlashes`. The Claude **hooks** writer does not, so slashes in paths come out as `\/`.

Unless noted, an invalid file or a wrong-typed `hooks` key throws "…has an unexpected type — Coucou has not touched it." and nothing is replaced. In path (B) an absent file reads as `{}`, but an **empty** file is invalid JSON and throws.

### 1.1 Claude Code — `~/.claude/settings.json`

**Events and timeouts (seconds):**

| Event | Timeout |
|---|---|
| SessionStart, SessionEnd | 10 |
| UserPromptSubmit | 10 |
| PreToolUse, PostToolUse, PostToolUseFailure | 10 |
| PermissionRequest | 120 |
| Notification | 10 |
| Stop, StopFailure | 10 |
| SubagentStart, SubagentStop | 10 |

**Merge, per event:**
1. Read the existing groups.
2. Remove every group with **any** inner hook whose `command` contains `"NotchBuddy"` or `"coucou"` (case-sensitive). The script path contains `NotchBuddy`, which is how Coucou's own entries match.
3. Append this group (no matcher):
```json
{"hooks":[{"type":"command","command":"\"/Users/x/Library/Application Support/NotchBuddy/nb-hook\"","timeout":10}]}
```
4. Then also append to `PreToolUse`:
```json
{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"\"…/nb-hook\" --ask","timeout":130}]}
```

**Uninstall:**
- Runs immediately, with no preview, but is still refused if the bytes changed.
- If `hooks` is not an object, it silently does nothing.
- For every event key, drops the matching groups and deletes events left empty. `"hooks"` stays even if it ends up empty.

**Installed check:** some `SessionStart` group has a command containing `NotchBuddy` or `coucou`.

**"Outdated" check:** a Coucou `PermissionRequest` timeout below 120, or no `PreToolUse` group with `matcher:"AskUserQuestion"` that holds a Coucou command.

**Preview:** the full new file text.

### 1.2 Codex — `~/.codex/hooks.json`

Root `{"hooks":{…}}`. Groups have no matcher. Timeouts are in **seconds**. Command: `/bin/sh "<path>" --agent codex` (no event argument; Codex puts the event name in the payload).

| Event | Timeout (s) |
|---|---|
| SessionStart | 10 |
| UserPromptSubmit | 10 |
| PreToolUse | 10 |
| PermissionRequest | 120 |
| PostToolUse | 10 |
| Stop | 10 |
| SubagentStart | 10 |
| SubagentStop | 10 |
| Interrupt | 3 |
| SessionEnd | 3 |

`PermissionRequest` also gets `"statusMessage":"Waiting for your answer in the notch (Coucou)"` (Windows uses "…in the island (Coucou)").

```json
{"hooks":{"PermissionRequest":[{"hooks":[{"command":"/bin/sh \"…/nb-hook\" --agent codex","statusMessage":"Waiting for your answer in the notch (Coucou)","timeout":120,"type":"command"}]}]}}
```

- **Merge and removal:** `removeNbHookEntries` (defined in §1.3), then append. On uninstall, events left empty are deleted, and `hooks` is deleted if empty.
- **Installed check:** an inner command contains both `nb-hook` and `--agent codex`.
- **Trust:** the user runs `/hooks` in Codex. It is not detected (see the top of this report).

### 1.3 Gemini CLI — `~/.gemini/settings.json`

Timeouts are in **milliseconds**. Each group is `{"matcher":"*","hooks":[{"type":"command","command":"/bin/sh \"<path>\" --agent gemini <Normalized>","timeout":N}]}`.

| Gemini event | Normalized name in the command | Timeout (ms) |
|---|---|---|
| SessionStart | SessionStart | 10000 |
| SessionEnd | SessionEnd | 10000 |
| BeforeTool | PreToolUse | 5000 |
| AfterTool | PostToolUse | 5000 |
| BeforeAgent | UserPromptSubmit | 5000 |
| AfterAgent | Stop | 5000 |

`AfterModel` is deliberately not installed (it would flood the notch).

**`removeNbHookEntries`** (shared by Gemini, Codex and Muse):
- Drops a legacy flat group whose top-level `command` contains `nb-hook`.
- Otherwise removes inner hooks whose `command` contains `nb-hook`, keeping the user's other hooks in the same group.
- Drops groups left empty.
- It does **not** look at `--agent`.

**Installed check:** the command contains `nb-hook` and `--agent gemini`. Legacy flat entries count too.

### 1.4 Antigravity — `~/.gemini/config/hooks.json`

Everything lives under one root key, `"coucou"`, which is replaced wholesale. Timeouts are 10 (seconds).

```json
{"coucou":{
  "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/bin/sh \"…\" --agent antigravity PreToolUse","timeout":10}]}],
  "PostToolUse":[{"matcher":"*","hooks":[{…"--agent antigravity PostToolUse"…}]}],
  "PreInvocation":[{"type":"command","command":"… --agent antigravity PreInvocation","timeout":10}],
  "PostInvocation":[{…}],
  "Stop":[{…}]}}
```

- Lifecycle events (`PreInvocation`, `PostInvocation`, `Stop`) are bare handlers with no matcher.
- **Uninstall:** remove the `coucou` key.
- **Installed check:** `root["coucou"]`, serialized, contains `nb-hook`.

### 1.5 GitHub Copilot CLI — `~/.copilot/hooks/coucou.json`

A file of Coucou's own. Root is `{"hooks":{…},"version":1}`. Entries have no group wrapper: `{"type":"command","bash":"/bin/sh \"…\" --agent copilot <event>","timeoutSec":N}`.

| Event | timeoutSec |
|---|---|
| sessionStart | 10 |
| userPromptSubmitted | 10 |
| preToolUse | 10 |
| permissionRequest | 120 |
| postToolUse | 10 |
| agentStop | 10 |
| sessionEnd | 3 |
| notification | 10 |

- **Merge:** removes entries whose `bash` contains `nb-hook`, then appends.
- **Uninstall:** deletes the whole file. The preview text is `(will delete <path>)`, and the fingerprint is still checked.
- **Installed check:** `bash` contains `nb-hook` and `--agent copilot`.
- Copilot is fail-closed on permission requests, hence the relay's "always print JSON" rules in §0.

### 1.6 Muse Code — `~/.config/muse/settings.json`

PascalCase events. Each group is `{"matcher":"*","hooks":[{"type":"command","command":"/bin/sh \"…\" --agent muse <Event>","timeout":ms}]}`. Timeouts are in **ms** (seconds × 1000).

| Event | Timeout (ms) |
|---|---|
| SessionStart | 10000 |
| UserPromptSubmit | 5000 |
| PreToolUse | 5000 |
| PermissionRequest | 120000 |
| PostToolUse | 5000 |
| Stop | 5000 |
| SessionEnd | 3000 |

- If the file did not exist, also sets `"schema_version":1`.
- Removal works like Gemini.
- **Installed check:** `nb-hook` and `--agent muse`.

### 1.7 OpenCode — `~/.config/opencode/plugins/coucou.js`

A whole generated file. `HOOK` is the script path with `\` → `\\` and `'` → `\'`.

```js
// Coucou hook plugin for OpenCode — generated by Coucou.app
// Forwards every event to the Coucou notch (fire-and-forget, never blocks).
import { spawn } from 'node:child_process';
const HOOK = '<path>';
const EVENT_MAP = { 'session.created':'SessionStart','session.idle':'Stop','session.error':'StopFailure','session.deleted':'SessionEnd','permission.asked':'PermissionRequest' };
function forward(hook_event_name, payload) {
  const p = spawn('/bin/sh', [HOOK, '--agent', 'opencode'], { stdio: ['pipe','ignore','ignore'], detached: true });
  p.on('error', () => {}); p.stdin.on('error', () => {});
  p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\n'); p.stdin.end(); p.unref();
}
export const CoucouPlugin = async (_ctx) => ({
  event: async ({ event }) => { /* map event.type; session_id from event.sessionID|session_id|props.sessionID|props.session_id; cwd from event.cwd|directory|props.cwd|props.directory; props.tool→tool_name (if string); props.input→tool_input */ },
  'tool.execute.before': async (input) => forward('PreToolUse', {session_id, cwd, tool_name, tool_input: input.input ?? null}),
  'tool.execute.after': async (input, _output) => forward('PostToolUse', {session_id, cwd, tool_name}),
});
```

- **Installed check:** the file contains `nb-hook` and `opencode`.
- **Removal:** deletes the file, only if it contains `generated by Coucou`; otherwise errors "…was not generated by Coucou — not deleting it."
- **Backup:** `coucou.js.bak-yyyyMMdd-HHmmss`.

### 1.8 Amp — `~/.config/amp/plugins/coucou.ts`

Same pattern as OpenCode. The header says `// Coucou hook plugin for Amp — generated by Coucou.app`. Spawns `/bin/sh HOOK --agent amp`. `export default function (amp: any)` registers:
- `session.start` → `SessionStart`
- `agent.start` → `UserPromptSubmit`
- `tool.call` → `PreToolUse`, with `tool_name`. It always returns `{ action: 'allow' }`, inside a `finally`.
- `tool.result` → `PostToolUse`
- `agent.end` → `Stop`

`session_id` is `e.thread?.id ?? ''`.

- **Installed check:** contains `nb-hook` and `'amp'`.
- Removal and backup work as for OpenCode.

### 1.9 Hermes — `~/.hermes/plugins/coucou/` and `~/.hermes/config.yaml`

**Plugin files:**
- `__init__.py` is generated. Its header is `# Coucou hook plugin for Hermes Agent — generated by Coucou.app`.
- `_fire` runs `[HOOK, '--agent', 'hermes']` with `Popen` in a thread, `start_new_session=True`, `wait(timeout=5)`.

**Hooks registered by `register(ctx)`:**
- `on_session_start` → `SessionStart`, with `platform`.
- `on_session_end` → `StopFailure`, only when `interrupted`.
- `post_llm_call` → `Stop`, with `last_assistant_message`.
- `pre_tool_call` → `PreToolUse`, with `tool_input` taken from `args`.
- `post_tool_call` → `PostToolUse`.

**Approvals:**
- If `ctx.register_approval_transport` exists, it registers `'coucou'`, which runs the relay synchronously with timeout `max(1, timeout_seconds - 2)` and payload `coucou_agent:'hermes'`, `coucou_has_transport:true`.
- Otherwise it registers an observer, `pre_approval_request`, which sends `PreToolUse` with tool_name `⏳ Approval pending in Hermes`.

**`plugin.yaml`:**
```yaml
name: coucou
version: "1.0"
description: Coucou notch integration — generated by Coucou.app
```

**Write and remove:**
- After writing, runs `hermes plugins enable coucou` (best effort). The binary is the first that exists of `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `~/.local/bin`.
- Remove: requires `generated by Coucou`, runs `hermes plugins disable coucou`, then deletes the whole folder.
- **Installed check:** `__init__.py` contains `nb-hook` and `hermes`.

**Transport support check:**
1. Find `hermes` via `which`, else `~/.local/bin`, `~/.hermes/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.
2. Read its shebang (resolving `/usr/bin/env X` via `which`).
3. Run `<python> -c "from hermes_cli.approval_transport import ApprovalRequest"` with a 3 s timeout. Exit 0 means supported.

**`config.yaml` merge** — line-level, no YAML parser:
- **Refuses** if the file contains `{`, ` &` or `\n---`. The error tells the user to add `security: approval: transport: coucou / transport_fallback: builtin` by hand.
- Indent is taken from the first line indented by 1–8 spaces; default 2.
- **Always ensures** `plugins:` → `enabled:` → `- coucou`:
  - An inline list `[a]` becomes `[a, coucou]`.
  - `enabled: []` is expanded to a block list.
  - Sections that are missing are appended after a blank line.
- **If approvals are on and supported**, ensures `security:` → `approval:` → `transport: coucou` and `transport_fallback: builtin` (two levels of indent), replacing existing `transport:` or `transport_fallback:` lines.
- **Otherwise** deletes only lines whose trimmed text is exactly `transport: coucou` or `transport_fallback: builtin`.
- Backup: `config.yaml.bak-<stamp>`.

### 1.10 Claude Desktop

Nothing is installed. The relay tags sessions with `CLAUDE_CODE_ENTRYPOINT=claude-desktop` as `coucou_agent:"claude-desktop"`. An explicit `--agent` still wins.

### 1.11 Cursor (Windows build only, `~/.cursor/hooks.json`)

- Format: `{"version":1,"hooks":{"<event>":[{"command":CMD}]}}`, with `version` added only if missing.
- Events: `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `stop`.
- The relay prints nothing back. On macOS, Cursor uses the Claude Code hooks instead (see the top).

### 1.12 Generic agent

Command: `nb-hook --agent <name> [EventName]`. The name must match `^[a-z0-9-]{1,24}$` and must not be `claude`; anything else falls back to the Claude pill. The pill id is `agent_<name>`.

---

## 2. Claude `statusLine` chaining

- **Command:** `"<hookScriptPath>" --statusline` (path quoted, no `/bin/sh`).
- **Saved previous line:** `supportDir/statusline-previous.json`, which is the same folder as `nb-hook.py`.

**Install (preview step):**
1. Fail if `/usr/bin/xcode-select -p` exits non-zero: "Command Line Tools are required but not installed. Run: xcode-select --install".
2. If a `statusLine` exists and its `command` does **not** contain `nb-hook`: copy the object and replace only `command`, keeping `padding`, `refreshInterval` and the rest. Queue the original object (pretty-printed, sorted) to be saved as the previous line.
3. If it exists and already contains `nb-hook`: rewrite `command` only, to update the path.
4. Otherwise: `{"type":"command","command":CMD}`.

Caveat: an existing `statusLine` with no string `command` falls into case 4 and is overwritten without being saved.

**Uninstall:**
- Only if the current `command` contains `nb-hook`. Restore the object from `statusline-previous.json` if it parses (and queue that file for deletion); otherwise remove the `statusLine` key.
- If the line is not Coucou's, it is left untouched.

**Writing:**
- The settings JSON is written with `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`.
- The preview text is `"statusLine\nBefore:\n<json or (none)>\n\nAfter:\n<json or (none)>"`.
- **Side effects are committed only after `ClaudeSettingsFile.write` succeeds:** write `statusline-previous.json` (atomic) or delete it.
- **Installed check:** `statusLine.command` contains `nb-hook`.

**Relay `--statusline` mode:**
- Empty or invalid stdin is tolerated in this mode.
- Sends `{"coucou_kind":"statusline","session_id":…,"rate_limits":payload.rate_limits or {}}` to the socket, timeout 0.3 s, fire-and-forget.
- Then, if `statusline-previous.json` exists next to `__file__` and has a non-empty `command`, runs `subprocess.run(['/bin/sh','-c',cmd], input=<raw stdin bytes>, capture_output=True, timeout=10)` and writes its stdout through byte for byte, ANSI colours included.
- Prints nothing else, and swallows all errors.

---

## 3. Safe-write protocol

### `ClaudeSettingsFile` (Claude `settings.json`)

**`read`:**
- Absent → `({}, nil)`.
- Unreadable → `.unreadable`.
- Only spaces, tabs, `\n` or `\r` → `({}, bytes)`.
- Not a JSON **object** → `.invalid`.
- Never treated as empty when the contents are unknown.

**`hooks(in:)` / `hookGroups(in:event:)`:** absent → empty; wrong type → `.unexpectedHooks`.

**Preview:** the new file is computed, and both the new data and the original bytes are kept in memory.

**`write(data, to:url, expecting:original)`:**
1. Re-read the current bytes (nil if absent). If they differ from `original` (byte-exact compare) → `.changed` ("changed since the preview. Nothing was written — review it again.").
2. `target = url.resolvingSymlinksInPath()`, so a symlinked `settings.json` keeps its link.
3. If the file exists: copy `target` to the backup `<name>.bak-yyyyMMdd-HHmmss`. The locale is `en_US_POSIX`, and the backup sits next to the **link** path. If that name is taken, try `-2`, `-3`, and so on. A failed copy → `.backupFailed`. The mode is taken from the original (`& 0o777`).
4. If the file is new: mode 0600, and the parent folder is created.
5. Write a temp file `<targetName>.coucou-<pid>` next to the target (created at 0600, then chmod to the mode), then POSIX `rename(temp, target)`. On any failure, remove the temp file and throw `.writeFailed`.
6. Return the backup URL.

### Other agents (`writeJSONFile` and the plugin writers)

- SHA-256 fingerprint compare instead of a byte compare.
- Backup `<suffix>.bak-yyyyMMdd-HHmmss` with no collision counter: if the name exists, the copy throws and the write is refused.
- Parent folder created, then `Data.write(.atomic)` or `String.write(atomically:)`.
- No symlink resolution and no permission preservation (the atomic replace swaps a symlink for a regular file).
- The plugin removers (`removeOpenCodePlugin`, `removeAmpPlugin`, `removeHermesPlugin`) skip the fingerprint check and rely on the `generated by Coucou` marker.
- Copilot uninstall deletes the file after the fingerprint check.

---

## 4. Claude plan gauge

**Parsing:**
- Input: the statusline payload's `rate_limits.five_hour` and `rate_limits.seven_day`, each `{used_percentage, resets_at}`.
- Each value is accepted as a Double or an Int.
- `used_percentage` outside 0–200 → that window is rejected. Values in 100–200 are clamped to 100.
- `resets_at` is epoch **seconds**. It must be above 0 and no more than 400 days in the future (otherwise it is probably milliseconds, and is rejected).
- If both windows are absent, return nil.
- `PlanUsage{fiveHour?, sevenDay?, updatedAt: now}`.

**Derived values:**
- `effectivePct` = 0 if `resetsAt <= now`, otherwise `usedPct`.
- `dominantPct` = the larger of the two windows that are present.

**Colours:**

| Condition | Colour |
|---|---|
| No data | `#6B7079` |
| below 50 | `#22C55E` |
| below 80 | `#F59E0B` |
| otherwise | `#F4505E` |

**Header pill:** `Claude N%` (rounded), or `Claude —` without data. The `pillLabel()` helper falls back to `Claude plan` instead.

**Refresh and persistence:**
- Publish only when either window changed, or 30 s or more have passed since the last `updatedAt`.
- Persisted as JSON in UserDefaults key `claudePlanUsage` and reloaded at launch.

**Card:**
- Title "Claude plan".
- Subtitle: "Waiting for a response from Claude Code" without data; "just now" under 60 s; "N min ago"; "N h ago".
- Rows "5 hours" and "Week".
- Each row: a 50×4 pt capsule bar (track white at 8% opacity, fill in the row's colour), then `N%`, a ↻ icon, and the reset label.
- Reset label: past → "Resetting…". The week row uses date format `EEE H:mm`. Otherwise "in %d h %d" when hours > 0, else "in %d min".
- A missing window shows "—".
- The clock ticks every 30 s while the card is visible.

---

## 5. Codex plan gauge

**Finding the binary** — the first executable of:
1. `~/.local/bin/codex`
2. `/opt/homebrew/bin/codex`
3. `/usr/local/bin/codex`
4. `~/.npm-global/bin/codex`
5. `~/.volta/bin/codex`
6. `~/.bun/bin/codex`
7. `~/Library/pnpm/codex`
8. `~/.nvm/versions/node/*/bin/codex`, newest Node version first (numeric sort)

**Process:**
- Runs `codex app-server`.
- `PATH` = codex's folder:`/opt/homebrew/bin`:`/usr/local/bin`:`/usr/bin`:`/bin`:<inherited PATH>.
- stdin and stdout are pipes; stderr goes to /dev/null.
- **Timeout 15 s:** `terminate()` closes stdout and ends the read loop. `defer` also terminates the process if it is still running, on every exit path.

**Requests** — written all at once, newline-delimited, no waiting between them:
```
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"coucou","version":"1"}}}
{"method":"initialized"}
{"id":2,"method":"account/rateLimits/read"}
```

**Reading:** stdout is read line by line; every line except the one with `id == 2` (as an Int) is ignored. EOF before that → nil. A response with an error (no `result`) → nil.

**Parsing `result`:**
- `result.rateLimits.planType` (String).
- For each of `rateLimits.primary` and `rateLimits.secondary`: `usedPercent` (Double, clamped 0–100) and `resetsAt` (Double, epoch s).
  - `windowDurationMins` (Int) of 1440 or less → the 5-hour slot.
  - Otherwise, including when it is missing → the week slot.
- `result.rateLimitResetCredits.availableCount` (Int) → number of free resets.
- The earliest `expiresAt` (Double epoch) among `credits[]` entries with `status == "available"`.
- Nil if neither window is present.

**Refresh rules** (`refreshCodexPlanUsage`, called when the Codex pill appears, is tapped, or from the Claude card's Codex row):
- Skip if the data is under 60 s old.
- Skip if a fetch is already running, or the last *attempt* was under 60 s ago.
- Not persisted.

**Display:**
- Pill: `Codex N%`, or `Codex —`. Same colours as Claude, from the larger window.
- Card title "Codex plan". Subtitle "`<planType> · `just now / N min ago / N h ago", or "Asking Codex…" while loading.
- The 5-hour row appears only if that window is present; the Week row always.
- "Resets" row: `N available`, plus ` · until MMM d` when N > 0 and an expiry exists; "—" when unknown.
- On the Claude card, the Codex row shows the Codex window with the higher `effectivePct` (ties go to the 5-hour window).

---

## 6. Constants

| Constant | Value |
|---|---|
| Socket message limit | 1,048,576 B |
| Socket receive timeout | 5 s |
| Max concurrent connections | 32 |
| Relay fire-and-forget timeout | 0.3 s |
| PermissionRequest socket timeout | 118 s |
| `--ask` socket timeout | 125 s |
| Previous statusLine run timeout | 10 s |
| Claude hook timeouts | 10 s; PermissionRequest 120; AskUserQuestion 130 |
| Codex hook timeouts | 10 s; PermissionRequest 120; Interrupt and SessionEnd 3 |
| Gemini hook timeouts | 10000 / 5000 ms |
| Muse hook timeouts | seconds × 1000 |
| Copilot hook timeouts | `timeoutSec` 10 / 120 / 3 |
| Antigravity hook timeouts | 10 s |
| Hermes transport check timeout | 3 s |
| Hermes `_fire` reap timeout | 5 s |
| Hermes transport timeout | `max(1, t - 2)`, default t = 30 |
| Codex fetch timeout | 15 s |
| Codex refresh throttle | 60 s, by data age and by attempt |
| Claude publish throttle | 30 s |
| Card clock tick | 30 s |
| Gauge thresholds | 50 / 80 |
| Colours | `#22C55E`, `#F59E0B`, `#F4505E`, grey `#6B7079` |
| Reset epoch sanity cap | now + 400 days |
| Backup date format | `yyyyMMdd-HHmmss`, `en_US_POSIX` |
| Temp file suffix | `.coucou-<pid>` |
| UserDefaults keys | `claudePlanUsage`, `showPlanInNotch`, `showCodexPlanInNotch`, `hermesApprovalsEnabled`, `coucouHooksInstalled` (App Store) |
| Ownership markers | Claude: `NotchBuddy` / `coucou` in the command; other hook files: `nb-hook` (+ `--agent X` for the installed check); Antigravity: the root `coucou` key; plugins: `generated by Coucou`; statusLine: `nb-hook` |
