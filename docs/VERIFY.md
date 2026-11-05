# Verifying Mochlet by hand

Everything below has a scripted counterpart (`scripts/test.sh`, `scripts/test-hook.sh`,
the `mochlet://debug/…` channel in debug builds). This is the list to walk through on a real
machine before a release.

## Character and notch (M1–M3)

- Launch: the slime drops into the notch, greets, collapses after a moment.
- Hover: it looks at the pointer. Click: ask bubble. Double-click: quick menu. Triple-click: meeting
  note-taker (later milestone). Five clicks: it splits and pulls itself back together. Hold: push-to-talk.
- Drag it out of the notch to any corner; drag it back. "Let me out" / "Back to the notch" in the menu.
- Idle CPU in Activity Monitor: about 1–2 % compact, under 0.5 % hidden (`scripts/measure-idle.sh`).

## Agent observation (M4)

1. Settings → Agents → Claude Code → Install…: the preview shows the whole new `~/.claude/settings.json`;
   the existing `statusLine` command is kept inside the relay chain. Confirm; a `.bak-…` appears next to it.
2. In iTerm: `claude -p "echo hi"`. A mini slime pinches off, the ticker shows the project, the final line
   appears, the slime does its happy jump, the mini merges back about six seconds after the turn.
3. Interactive `claude`, ask it to run a shell command: the approval card appears in the notch; Allow runs it,
   Deny stops it, "Reply in terminal" hands the prompt back; pressing Esc in the terminal removes the card
   with "Handled in iTerm."
4. Ask Claude a question that triggers AskUserQuestion (for example "ask me which colour I prefer with the
   AskUserQuestion tool"): the question card appears; pick a chip; the answer reaches the terminal.
5. `/plan` → ExitPlanMode: the plan card offers Auto mode / Manual / Change plan.
6. Open two sessions in two iTerm tabs; `⌃⌥T` selects the tab of the focused session (the one whose mini
   you clicked last). tmux panes are selected first when the session lives in tmux.
7. Codex: Settings → Agents → Codex → Install…, then `/hooks` inside `codex` and trust; `codex exec "say hi"`
   shows a Codex mini (◎). The Codex plan pill shows the week usage (needs `codex app-server`).
8. Gemini: install, then `gemini -p "hi"` shows a Gemini mini (✦).
9. The Claude plan pill appears after the first statusline refresh; both pills can be hidden in Settings → Agents.
10. Remove the hooks: the settings file goes back to the previous content, including the old statusLine.

Scripted version of 2–5 without any agent:

```sh
scripts/build-app.sh debug && open build/debug/Mochlet.app
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
scripts/replay-hooks.sh Tests/Fixtures/hooks/claude-session.jsonl 0.4
scripts/replay-hooks.sh Tests/Fixtures/hooks/approval.json 0 &      # then on the card, or:
open "mochlet://debug/approve?decision=always&$T"
scripts/replay-hooks.sh Tests/Fixtures/hooks/question.json 0 --ask &
open "mochlet://debug/answer?pick=SQLite%20FTS5&$T"
open "mochlet://debug/shot?name=card&$T"                             # ~/Library/Logs/Mochlet/debug/card.png
```

## Projects and chat (M5)

1. Drop a folder on the slime: it chews, the Projects card asks "Make <name> a project?"; Yes writes
   `~/Mochlet/projects.json` (the git remote is recorded when there is one). "Add folder…" and
   Settings → Projects do the same; editing the file by hand is picked up live.
2. Click the slime and type `work on <project>: say hello`: a new iTerm (or your preferred terminal) window
   opens in the project folder running `claude 'say hello'`; the hooks turn it into a mini slime labelled
   with the project's name; `last_sessions.claude` in projects.json gets the session id.
3. On the Projects card the row now offers Resume: a terminal opens with `claude --resume <id>`.
   `open <project> in ghostty` / Cursor / VS Code open the folder without an agent.
4. Settings → Chat → "Run tasks in the background", then `work on <project>: say hello` again: no window;
   a mini appears with the Claude glyph and transport headless; the session card shows the reply and
   "done"; Stop in the card ends it.
5. Type anything else in the ask bubble: the Chat card opens and Claude Code (your subscription, through
   `claude -p`) streams the answer; the thread is kept in `~/Library/Application Support/Mochlet/store.sqlite`
   and listed under the clock icon; `⌘K` starts a new thread; the provider menu switches to Codex, Gemini,
   or any API provider whose key you saved under Settings → Chat (model lists load from the API).
6. Quick menu → Attach window with Safari in front: a chip "Safari · <title>" appears above the input and
   the URL is sent as context; with "Attach a screenshot" on (Screen Recording granted) an image is sent to
   providers that accept images.
7. Drop a text file or a link on the slime: it becomes a chat attachment and the Chat card opens.
8. `say "what are my sessions doing"` while an agent works: the answer names the live sessions (the system
   prompt carries them) and the main slime looks thinking while a reply streams.
9. Settings → Agents lists all nine agents; Install… on Copilot creates `~/.copilot/hooks/mochlet.json`,
   on OpenCode `~/.config/opencode/plugins/mochlet.js`; Remove deletes only files Mochlet generated.

Scripted version:

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/project?add=$PWD&name=Mochlet&$T"
open "mochlet://debug/ask?text=work%20on%20mochlet%3A%20say%20hello&$T"        # opens a terminal
open "mochlet://debug/workon?project=mochlet&task=say%20hello&headless=1&$T"   # background run
open "mochlet://debug/chat?text=Reply%20with%20pong&$T"; sleep 10; open "mochlet://debug/state?$T"
open "mochlet://debug/attach?$T"                                               # frontmost window → chip
```
