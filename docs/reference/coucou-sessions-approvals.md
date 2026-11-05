<!-- Reference notes extracted on 2026-11-05 from the Coucou source (MIT, /Users/ilex.poon/Coucou) to guide Mochlet's own implementation. Facts about Coucou, not Mochlet's design. -->

## Coucou reference spec: session registry, approvals, AskUserQuestion, diffs, terminal jump, window context

The main thing to know first: **the macOS app has no tab- or session-level terminal jump.** It only brings an app to the front. Nothing in `NotchBuddy/Sources` contains `osascript`, Terminal/iTerm AppleScript, tmux, `wezterm cli`, kitty @, or `code -r`/`cursor -r`. The hook script does collect `iterm_session_id` and `term_session_id`, but the app never reads them. The per-tab AppleScript appears only as a plan in `/Users/ilex.poon/Coucou/docs/INTEGRATIONS.md` (section 5).

Also, the tests are not in `NotchBuddy/Tests` (that folder only has `HermesConfigMergerTests.swift`). They are in `/Users/ilex.poon/Coucou/tests/`.

Main files:
- `/Users/ilex.poon/Coucou/NotchBuddy/Sources/App/HookServer.swift` (4009 lines): event state machine, approval and question flow, embedded `nb-hook.py`
- `PillSessionRegistry.swift`, `ApprovalQueue.swift`, `AskQuestion.swift`, `TerminalTarget*.swift`, `ClaudeHost.swift`, `WindowContextCapture.swift`, `ScreenCapture.swift`, `AppState.swift` (lines 419–455), `IslandViewContent.swift` (lines 357–649, 700–745, 2461)
- `/Users/ilex.poon/Coucou/NotchBuddy/Sources/CoucouKit/DiffEngine.swift`, `QuestionPayload.swift`, `IslandTypes.swift`

---

### 1. Session registry (`PillSessionRegistry`, a value type with mutating calls)

**Keying.** A **pill** is chosen from the client that sent the event, never from the session. Several sessions can sit behind one pill. Pill routing, from `processEvent`, checked in order:
1. `coucou_agent == "codex"` → `agent_codex`
2. Any other valid `coucou_agent` → `agent_<name>`, an external agent. Valid means `[a-z0-9-]`, 1–24 chars, and not `"claude"`.
3. `bundle_id.lowercased() == "com.todesktop.230313mzl4w4u92"` → `agent_cursor`
4. `term_program` or `bundle_id` contains `"vscode"` → `integration_claude` with `hostApp = nil`
5. `ClaudeHost.terminal(termProgram:bundleId:)` matches → `integration_claude` with `hostApp = host.bundleId`
6. Anything else is ignored and logged.

**Session id.** `session_id`, else `conversation_id`, else `"unknown"`. The recap key for an empty or `"unknown"` id is `"\(pillId)+\(cwd)"`.

**Models.**
- `Display { session, projectName, cwd, hostApp: String?, bundleId = "" }`
- private `Session { projectName, cwd, hostApp?, bundleId, isWorking, lastSeen: Date, lastWorked: Date = .distantPast }`
- `Pill { order: [String] /* oldest first */, sessions: [String: Session] }`
- `pills: [String: Pill]`

**`note(pill, display, working, now)`**
- Runs the sweep first.
- Appends to `order` if the session is new.
- Always overwrites `projectName`.
- Updates `cwd` only if non-empty, `hostApp` only if non-nil, `bundleId` only if non-empty.
- If `working`: `isWorking = true` and `lastWorked = now`. A non-working note never clears `isWorking`, so the flag stays set for the whole turn.
- Always sets `lastSeen = now`.

**`endTurn(pill, session)`** (used for Stop, StopFailure, Interrupt)
- Sweeps, then sets `isWorking = false` and `lastSeen = lastWorked = now`, but only if the session is known.
- An unknown session stays untracked.
- Returns `.sessionOnly` if any session is still working, else `.pill`.

**`endSession`** removes the session. It returns `.pill` only if no live sessions remain (and drops the pill entry), else `.sessionOnly`.

**`displayOwner`**, picked in this order:
1. The first session in `order` with `isWorking`
2. Otherwise the session with the greatest `lastWorked`. `max(by:)` keeps the first of equal values, so with no turn seen yet this is the oldest.

`ownsDisplay(pill, session)` is true when there is no owner yet or the owner is this session. Only the owner may write the task's name, cwd, `hostApp` and `sessionBundleId`. `applyDisplayOwner` re-applies these after Stop, StopFailure, Interrupt and a non-last SessionEnd.

**Sweep** (runs inside every mutation):
- `now - lastSeen > maxSilence` (12 h = 43200 s) → remove the session.
- Else if working and silence > `maxTurnSilence` (30 min = 1800 s) → `isWorking = false`.

**Event → effect** (in `HookServer.processEvent`):

| Event | Effect |
|---|---|
| SessionStart | `note(working: false)`; clear `finalLine`; sound `"work"` |
| UserPromptSubmit | `note(working: true)`; state `.thinking`; step = `prompt.prefix(60)` |
| PreToolUse | Skipped entirely if tool is `AskUserQuestion`. Else `note(true)`; state `.working`, or `.question` if tool is `ask_question` or ends with `:ask_question`; append localized step |
| PostToolUse | `note(true)`; `.working`; build diff and append it as a diff step |
| PostToolUseFailure | `note(true)`; `.working`; step `"⚠ failed"` |
| Notification | `note(false)`. Message contains "rate limit" or "limite d" → `.ratelimit`. Message ends with `?` → `.question` plus a step |
| Stop | `endTurn`. `finalText = DiffEngine.toOneLine(last_assistant_message ?? message)` is always appended as a step. If scope is `.pill`: state `.finished`, set `finalLine`, sound/expand, or a badge if the terminal is frontmost or the alert is not shown |
| StopFailure | `endTurn`. If `.pill`: `.error` with `finalLine = stopFailureDetail(payload)` |
| Interrupt (Codex) | `endTurn`. If `.pill`: `.idle` and clear the badge |
| SessionEnd | Only when it was the last session: clear `finalLine`, clear the pill's diffs, remove the task |
| SubagentStart / SubagentStop | Steps `"+ subagent"` / `"• subagent done"` |

**Finished → idle.** There is no merge step, only this timer:
- 5.2 s after a `.pill`-scope Stop, if `workingCount == 0`:
  - external agent → remove the task
  - otherwise → `.idle` and clear the badge
- `terminalInFront` means `hostApp != nil` and the frontmost app's bundle id equals `hostApp`. When true there is no sound and no expand, only a badge.

**Caps**
- Steps: 20 per task, dropping the oldest (`appendStep`); `stepIndex = count - 1`.
- Diffs: 50 per pill, dropping the oldest. A per-pill inactivity timer clears them after **3600 s** and is reset on every append. `nextDiffId` is global and never reset.
- Step text uses `oneLine` with limit 60 plus `"…"`.

**Approval interaction.** While an approval is pending for the same pill and session, events from that session are **dropped**, after being checked for resolution. A `defer` puts the pill back into `.approval` if entries for it still exist.

**Project name**: `session_title` (from `/rename`), else the last path component of `session_root` (first `cwd` in the transcript), else of `cwd`, else `"Session"`. An alias map turns `notch-buddy`/`notchbuddy`/`notch_buddy` into "Notch Buddy".

### 2. Approval queue

**`QueuedApproval`** fields: `id: UUID`, `fd: Int32`, `sessionId`, `pillId`, `projectName`, `cwd`, `tool`, `command`, `inputKey`, `hostApp?`, `bundleId`, `received: Date`.

**Queue rules**
- FIFO; the head is the card on screen.
- `maxPending = 5`. Beyond that the newest gets `{"permissionDecision":"ask"}` and the socket closes.
- `inputKey` = `JSONSerialization` of `tool_input` with `.sortedKeys`, or `""` if empty.
- `command`: for `ExitPlanMode` it is `planTitle(plan)`, the first non-blank line with leading `#` and spaces stripped, else `"Plan"`. Otherwise `tool_input["command"]`, else the tool name.

**Who gets a card**
- Codex, Copilot, Muse, Hermes (only with `hermesApprovalsEnabled` and `coucou_has_transport == true`), Cursor and VS Code always do.
- Terminal sessions only when UserDefaults `terminalCardsEnabled` is on (off by default).
- Any other valid `coucou_agent`, or a terminal with the setting off, gets an immediate `"ask"`.
- A `PermissionRequest` for `AskUserQuestion` gets `"ask"`.

**Resolution** (`resolved(byEvent:)`), checked on every non-PermissionRequest event:
- `PostToolUse` / `PostToolUseFailure`: same `pillId`, `sessionId`, `tool_name` **and** `inputKey`.
- `Stop`, `StopFailure`, `UserPromptSubmit`, `SessionEnd`, `Interrupt`: same `pillId` and `sessionId`.
- Anything else (including PreToolUse) resolves nothing.
- A resolved entry is removed with no answer written; the fd closes and a note shows: `"Handled in <Cursor|Codex|Copilot CLI|Muse Code|Hermes|hostName>."`.

**Other removal paths**
- A DispatchSource read event on the fd (client hung up) → removed with the same "Handled in …" note.
- Timeout: **115 s**, or **110 s** for Copilot/Muse → note `"Still waiting in …"`. The note view shows for 3 s.

**Decisions** (`sendApprovalDecision(decision, for: shownId)`). A click whose id is not the current head is ignored.

| Decision | Socket line |
|---|---|
| allow | `{"permissionDecision":"allow"}` |
| always | `{"permissionDecision":"always"}` |
| ask | `{"permissionDecision":"ask"}` |
| plan_auto | `{"permissionDecision":"allow","mode":"auto"}` |
| plan_default | `{"permissionDecision":"allow","mode":"default"}` |
| plan_change | `{"permissionDecision":"change_plan"}`, then `ClaudeHost.activate(hostApp)` |
| default | `{"permissionDecision":"deny"}` |

Buttons: Deny / Allow / Always. "Always" is hidden for `agent_codex`, `agent_copilot` and `agent_muse`. Plan cards show "Change plan" / "Auto mode" / "Manual". The card header shows `1/N` when the queue holds more than one request.

**nb-hook.py translation** (socket timeout 118 s; Claude hook timeout 120 s):
- allow, or always on Codex:
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
- always (not Codex):
  `…"decision":{"behavior":"allow","updatedPermissions": payload.permission_suggestions}`
- `ExitPlanMode` allow: adds `updatedInput = tool_input`. When `mode` is `auto` or `default`, also adds `updatedPermissions=[{"type":"setMode","mode":mode,"destination":"session"}]`.
- deny: `…{"behavior":"deny","message":"Denied from Coucou"}`
- change_plan: `…{"behavior":"deny","interrupt":true,"message":"The user wants to change the plan and will type the changes in the terminal."}`
- Copilot/Muse: flat `{"permissionDecision":"allow"|"deny"}`.
- Hermes: `{"choice":"once"|"always"|"deny"}`.
- ask, timeout or unknown: **no output**, so the terminal asks itself. Copilot is the exception: it always gets `{"permissionDecision":"ask"}`.

**Codex specifics** (`~/.codex/hooks.json`; command `<base> --agent codex`):
- Events and timeouts: SessionStart 10, UserPromptSubmit 10, PreToolUse 10, PermissionRequest 120 (with `statusMessage: "Waiting for your answer in the notch (Coucou)"`), PostToolUse 10, Stop 10, SubagentStart 10, SubagentStop 10, Interrupt 3, SessionEnd 3.
- Codex is never gated by the terminal setting.
- Codex has no "Always" option.
- `apply_patch` step label is taken from `*** Update File: ` / `*** Add File: ` / `*** Delete File: `.
- `mcp__server__tool` is shown as `"server · tool"`.

**Claude settings hooks**: every event has timeout 10 except PermissionRequest at 120. There is also an extra PreToolUse entry `{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"<cmd> --ask","timeout":130}]}`.

### 3. AskUserQuestion

**Transport.** The `--ask` PreToolUse hook only acts when `tool_name == "AskUserQuestion"`. It sends `coucou_kind: "ask_user_question"` and waits on a socket with a 125 s timeout.

**Parsing** (`AskQuestion.parse`). Any failure replies `"ask"` immediately.
- `questions` must be a non-empty array with at most 4 entries.
- Each question needs a non-empty `question` string and `options` with 2–4 entries.
- Each option needs a non-empty `label`; `description` defaults to `""`.
- `header` is cut with `prefix(12)`; `multiSelect` defaults to `false`.

**Routing.** Codex → `agent_codex`, Cursor → `agent_cursor`, else `integration_claude`. The same terminal gate applies. Only one question is pending at a time; a new one sends `"ask"` to the previous one.

**Answer.** `buildAnswers` maps question text to `String` (single-select) or `[String]` (multi-select). Questions with no selection are omitted.
- Socket: `{"permissionDecision":"answer","answers":{...}}`, serialized `.withoutEscapingSlashes`.
- Hook output: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":<original>,"answers":{...}}}}`.

**"Other…"** is always offered. The typed text replaces that question's selection (`selections[qi] = [text]`), so a multi-select question sends `[text]`. "Send" is disabled while the text is empty.

**UI behavior**
- Single-select: a click answers and advances to the next question or sends.
- Multi-select: toggles, then a Send/Next button.
- Number keys 1–4 pick options.

**Ending without an answer**
- "Reply in terminal", the view disappearing, or the 120 s app timeout all send `{"permissionDecision":"ask"}`, which produces no hook output.
- If the client hangs up, the card is dismissed.

**Island height**: per question, `20 + lines(q, 7pt) * 17 + 64`, where a line wraps at 500 pt.
- +14 if there is a header.
- With descriptions: `34 + descLines(6.4pt) * 14` per option, plus 40 for the Other row.
- Without descriptions: +74 for 3 or more options, else +40.
- +34 for multi-select.
- The result is clamped to 160–560.

**iPhone** (`QuestionPayload`): fingerprint = SHA256 hex of each question's `[question, "multi"|"single", labels…]` joined by `\u{1F}`, with questions joined by `\u{1E}`. `accepts` requires one pick per single-select question and every label to be a known option.

### 4. Diff engine

Model:
- `DiffLine { kind: context|added|removed, text, origLine (1-based, -1 for an add), newLine (-1 for a remove) }`
- `DiffHunk { origStart, newStart, lines }`
- `FileDiff { id, path, added, removed, hunks, tooLarge, isNewFile; name = lastPathComponent }`

**Caps**
- `maxBytes = 200*1024`, measured on old plus new UTF-8 bytes.
- `maxLines = 4000`, old plus new.
- `m*n > 1_000_000` also counts as too large.
- When too large, `countFallback` splits on `\n` and counts non-empty lines that are not in the other side's set, with no hunks.
- For `fromNew`, too large means `added = line count`.

**Line splitting.** CRLF becomes LF, the text is split on `\n`, and one trailing empty element is dropped.

**Algorithm.** A full O(m·n) LCS DP table. Backtracking from (m, n): on equal lines take the match; else if `dp[i-1][j] >= dp[i][j-1]` then `i--`, else `j--`. Between consecutive matches it emits **all removes first, then adds**, then the context line, then trailing removes and adds.

**Hunks.** Each changed line is expanded by ±**3** lines of context. Ranges merge when `r.start <= last.end + 1`. `origStart` / `newStart` are the first positive line number in the hunk, else 1.

**Inputs from tool calls**
- `Edit`: `old_string`, `new_string`, `file_path`. Discarded if both strings are empty or nothing changed.
- `MultiEdit`: each `edits[]` entry is diffed on its own; hunks are concatenated, counts summed, and `tooLarge` set if any edit was too large. Line numbers are relative to each snippet.
- `Write`: `content` becomes a single hunk of all-added lines (`origStart 0, newStart 1`) with `isNewFile = true`.
- `apply_patch` produces **no diff**, only a step.

**Rendering.** The step string is `"\u{E001}<filename>\t<added>:<removed>:<diffId>"`.

`toOneLine(text, maxChars 200)` takes the first paragraph. Paragraphs break at a blank line, a horizontal rule of 3+ `-`, `*` or `_`, or a line starting with `|`. It strips `**`, `__`, backticks, leading `#`, and bullet markers (`- `, `* `, `• `, `N. `), then collapses whitespace.

### 5. Terminal jump (what the app actually does)

**`TerminalTarget.knownTerminals`**, in this order: `com.apple.Terminal`, `com.googlecode.iterm2`, `net.kovidgoyal.kitty`, `com.mitchellh.ghostty`, `com.cmuxterm.app`, `dev.warp.Warp-Stable`, `com.github.wez.wezterm`, `org.alacritty`.

- `candidates(sessionBundleId)` = the session's own trimmed `bundle_id` (from `__CFBundleIdentifier`) first, then the known terminals without a duplicate.
- `pick` = the first candidate that is running.
- `activate` = `NSRunningApplication.activate(options: .activateIgnoringOtherApps)`.

**`ClaudeHost` terminals** (bundle id → name): Warp-Stable/Preview "Warp", Terminal, iTerm, Ghostty, kitty, Alacritty, WezTerm, `co.zeit.hyper` Hyper, `dev.zed.Zed` Zed, `com.cmuxterm.app` cmux, `com.stablyai.orca` Orca, `com.conductor.app` Conductor.

The `TERM_PROGRAM` fallback map: `warpterminal`, `apple_terminal`, `iterm.app`, `ghostty`, `kitty`, `alacritty`, `wezterm`, `hyper`, `zed`. The bundle id is checked first, which is how cmux and tmux-in-Ghostty are told apart. `ClaudeHost.activate` brings a running app forward, or launches it.

**Strategy order**
- **Card "Open terminal"** (`openSessionApp`):
  1. If the task is `integration_claude`, `ClaudeHost.activate(hostApp)`
  2. Else `TerminalTarget.activate(sessionBundleId)`
  3. Else open `/System/Applications/Utilities/Terminal.app`
- **⌃⌥T** (`performJumpToTerminal`): TerminalTarget, then Terminal.app. With no focused task it plays an error sound.

**Per pill**
- `agent_cursor`: open `com.todesktop.230313mzl4w4u92`.
- `agent_codex`: open `com.openai.codex`.
- `agent_claude-desktop`: open `com.anthropic.claudefordesktop`.
- Gemini, Antigravity, Copilot, Muse, OpenCode, Amp: `TerminalTarget.activate(nil)`.
- VS Code button: tries `com.microsoft.VSCode`, `com.microsoft.VSCodeInsiders`, `com.vscodium.codium`. With a `sessionCwd` it opens that folder in the app (`NSWorkspace.open([cwd], withApplicationAt:)`); otherwise it activates or launches the app. There is no `code -r`.

**Permissions.** Activation needs none, and no Automation or Accessibility prompts happen for the jump.

**The documented plan that was never built** (`docs/INTEGRATIONS.md`):

| Captured context | Planned action |
|---|---|
| `Apple_Terminal` + tty | Terminal AppleScript: select the tab whose `tty` matches, activate |
| `iTerm.app` + `ITERM_SESSION_ID` | iTerm AppleScript: select the session, activate |
| `vscode` | Open `cwd` in VS Code or Cursor, depending on bundle id |
| Ghostty, Warp, other | Activate the app |
| Conductor | Activate the app |
| Nothing (Claude app) | Activate Claude |

The plan notes that macOS asks for Automation permission the first time. Its claim that the tty is found by walking parent processes is not implemented in the script.

**Linux port only** (`/Users/ilex.poon/Coucou/windows/src-tauri/src/platform/linux_focus.rs`): it walks up to 16 ancestors from `/proc`. For kitty it reads `KITTY_LISTEN_ON` (only `unix:` paths of plain characters, ≤107 chars) from the shell's `/proc/<pid>/environ` and runs `kitten @ --to <addr> focus-window --match pid:<shellpid>` with a 2 s limit. Otherwise it uses KWin, then EWMH. The final fallback is `code <dir>`, but only for an absolute path to an existing folder.

### 6. Window context capture

- **App**: `state.lastExternalApp`, the last app in front before Coucou.
- **Title**: `AXUIElementCreateApplication(pid)`, then `kAXFocusedWindowAttribute`, then `kAXTitleAttribute`. It is `""` on failure, with no permission prompt.
- **URL**: run through `NSAppleScript`; any error gives nil.

| Bundle id | AppleScript |
|---|---|
| `com.apple.Safari` | `tell application "Safari" to return URL of current tab of front window` |
| `com.google.Chrome` | `tell application "Google Chrome" to return URL of active tab of front window` |
| `company.thebrowser.Browser` | `tell application "Arc" to return URL of active tab of front window` |
| `org.mozilla.firefox` | `tell application "Firefox" to return URL of active tab of front window` |
| `com.microsoft.edgemac` | `tell application "Microsoft Edge" to return URL of active tab of front window` |

- **Result**: `PromptContext.window(appName:, title:, url:)`. The App Store build returns nil.
- **Screenshot**: not part of this capture. It is a separate ⌘⇧S feature (`ScreenCapture`):
  - Checks `CGPreflightScreenCaptureAccess`, else calls `CGRequestScreenCaptureAccess`.
  - Runs `/usr/sbin/screencapture -i -x -o <tmp>/CoucouCaptures/Capture yyyy-MM-dd 'at' HH.mm.ss.png`.
  - Keeps the last 20 captures; the images are not downscaled.
  - The annotate window fits 1100×720 (minimum width 420).
  - Pasting uses ⌘V, or ⌃V in a terminal.

### 7. Constants

**Hook server and socket**
- `maxPayload` 1,048,576 bytes; `SO_RCVTIMEO` 5 s; `maxConnections` 32; `listen` backlog 32.
- Socket `~/Library/Application Support/NotchBuddy/nb.sock` at mode 0600, directory 0700, same-UID check via `getpeereid`.
- `sun_path` limit 103 bytes.

**Registry and pills**
- `maxSilence` 43200 s; `maxTurnSilence` 1800 s.
- Finished→idle 5.2 s; note view 3 s.
- Steps 20; diffs 50 per pill; diff expiry 3600 s.

**Approvals and questions**
- `ApprovalQueue.maxPending` 5.
- Approval timeout 115 s (110 s for Copilot/Muse); question timeout 120 s.
- nb-hook socket timeouts: permission 118 s, ask 125 s, other events 0.3 s.
- Hook timeouts: 10 s, 120 s for PermissionRequest, 130 s for the AskUserQuestion matcher.
- AskUserQuestion limits: 1–4 questions, 2–4 options, header 12 chars.

**Diffs**
- 200 KB, 4000 lines, m·n 1,000,000, context 3, `toOneLine` 200 chars, step one-line 60 chars, prompt step 60 chars.

### Tests (`/Users/ilex.poon/Coucou/tests/`)

**PillSessionRegistryTests.swift**
- *Single session*: Stop → `.pill`; still live between turns; SessionEnd → `.pill`.
- *Two sessions*: A's Stop and SessionEnd → `.sessionOnly` while B works; B's then → `.pill`.
- *Resting sibling*: does not block A's Stop; A's SessionEnd still spares B.
- *Display ownership*: oldest owns; B can't rename; B inherits name/cwd after A ends.
- *Name follows working session*: an idle notification doesn't steal the name; the last-worked session keeps it when all are idle.
- *No turn yet*: oldest owns.
- *Partial payloads*: empty cwd kept; working flag sticky.
- *Separate pills*: independent.
- *Untracked*: a ghost Stop/End → `.pill` on an empty pill, `.sessionOnly` otherwise.
- *Turn silence*: just under / over `maxTurnSilence`.
- *Silence sweep*: past `maxSilence`.
- *Terminal of the owner*: `hostApp`/cwd follow the owner.

**ApprovalQueueTests.swift**
- FIFO head, 1-based positions, non-head removal, removing twice is a no-op.
- Cap rejects the newest and leaves the queue unchanged.
- PostToolUse matches only the same session + pill + tool + key.
- Stop matches session + pill.
- PreToolUse resolves nothing.
- `hasMixedSources`; `hasEntries(forPill:)`.

**AskQuestionTests.swift**
- Parse fields; header truncated to 12; multiSelect.
- 4 questions OK; 5 → nil; 1 option → nil; missing question / empty array / missing key / empty label → nil.
- Multi-select → `[String]`, single → `String`; unanswered omitted; all empty → `{}`.
- `hasDescriptions`; 160 pt floor; tallest question wins, ≤ 560.

**DiffEngineTests.swift**
- Additions, removals, replacement; `fromNew`; MultiEdit.
- `tooLarge` above 200 KB; CRLF; no trailing newline.
- 3-line context gives one hunk with ≥3 context lines.
- 1001×1001 lines → `tooLarge` with no hunks; `fromNew` too large.
- Diff step round-trip, including multi-digit ids and rejecting non-diff steps.
- `toOneLine`: bold, heading, truncation, blank / `---` / `***` / `|` stops, bullets, ordered lists, empty-paragraph fallthrough.

**TerminalTargetTests.swift** (run via `scripts/test-terminal-target.sh`)
- The session's own app wins (cmux, Conductor, VS Code); Conductor is not in `knownTerminals`.
- Falls back to known terminals in order; nil or blank bundle id → known list.
- Nothing running → nil; no duplicates.

**ClaudeHostTests.swift**
- Warp by bundle id and by TERM_PROGRAM; Terminal; iTerm.
- tmux-in-Ghostty and cmux: bundle id wins.
- Orca, Conductor; VS Code / Cursor / unknown → nil.
- `name` and `pillName` mapping; `terminalCardsEnabled` off by default.
