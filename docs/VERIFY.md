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
   (a project cloned by Mochlet first opens a terminal instead until you choose "Trust for background runs"
   in its ⋯ menu, because a fresh clone may carry project-level agent hooks);
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

## Knowledge base (M6)

1. First launch creates `~/Mochlet/Knowledge/` with `SCHEMA.md`, `CLAUDE.md`, `AGENTS.md`, `index.md`, `log.md` and the
   type folders; Settings → Knowledge shows the page count and "Listening on 127.0.0.1:<port>".
2. Drop `Tests/Fixtures/knowledge/vision-pro.md` on the slime: it chews, the Knowledge card opens with
   "Filed: Apple Vision Pro 与空间计算", `inbox/apple-vision-pro-….md` exists with the source mirrored under
   `inbox/references/`, `log.md` has an `ingest |` line and the root `index.md` lists the report.
3. Drop the same file again: "Already chewed". Drop a PDF: it is mirrored with a stub report (full reading is M7).
   Drop a link: a draft report with the URL as `resource`.
4. Ask on the card (or `kb: what does the Vision Pro cost?` in the ask bubble): the answer streams through the chat
   backend with `[1]` citations; the chips open the report at the cited line (Cursor/VS Code when running);
   `头显多少钱` works the same way in Chinese.
5. "File this answer": `syntheses/<question-slug>.md` appears with the citations as `sources[]`, the cited report gains a
   `## Mentioned in` backlink, `log.md` gets a `query |` line, the slime looks proud.
6. Lint: the toast gives the count; `meta/lint-<date>.md` lists orphans / broken links / reports never integrated;
   copy `Tests/Fixtures/knowledge/bundle/` into the folder first to see an orphan and a broken link reported.
7. Edit a page in Obsidian or any editor: the index picks it up within a few seconds (Settings → Knowledge counts
   or `kb?find=`), while Mochlet's own writes never trigger a reindex.
8. `claude mcp add mochlet -- "$HOME/Library/Application Support/Mochlet/bin/mochlet-mcp"`, then in Claude Code:
   "use the mochlet find tool for Vision Pro price" returns the passage with its path; `tree`, `read`, `grep` and
   `add_resource` work the same way. Quit Mochlet: the tool returns "Mochlet is not running".
9. Settings → Knowledge → "Keep history with git": a commit appears in `~/Mochlet/Knowledge/.git` after the next drop.
10. Embeddings: the first index run downloads the language assets; the Search section counts vectors; the toggle off
    keeps keyword search working.

Scripted version:

```sh
scripts/smoke-ingest.sh                                      # CLI: bootstrap, ingest, find (en + zh), dedupe, lint
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/kb?add=$PWD/Tests/Fixtures/knowledge/vision-pro.md&$T"; sleep 2; cat ~/Library/Logs/Mochlet/debug/result.txt
open "mochlet://debug/kb?find=Vision%20Pro%20price&$T"; sleep 2; cat ~/Library/Logs/Mochlet/debug/result.txt
open "mochlet://debug/kb?ask=What%20does%20the%20Vision%20Pro%20cost%3F&$T"; sleep 15; open "mochlet://debug/state?$T"
open "mochlet://debug/kb?file=1&$T"; open "mochlet://debug/kb?lint=1&$T"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find","arguments":{"query":"Vision Pro"}}}' \
  | ~/Library/Application\ Support/Mochlet/bin/mochlet-mcp
```

## Ingestion (M7)

1. Drop `Tests/Fixtures/ingest/sample.pptx` on the slime: it chews (bites, progress ring on the compact
   strip), the card shows reading → extracting → analysing · Claude Code → routing → filing → integrating,
   then the title, the one-liner, "Wiki: n new, m revised" and Open / Ask / Move / Re-chew. The report
   under `projects/<slug>/` or `inbox/` has slides and speaker notes in its mirror, entities and tags in
   the frontmatter; `entities/` and `concepts/` gained or changed pages; `log.md` has `ingest |` and
   `integrate |` lines.
2. Drop a scanned PDF, a `.docx`, a `.png` with text and an `.m4a`: OCR, Office, image description (when
   the brain can see) and transcription each show in `mochlet.extractors`.
3. Paste `https://arxiv.org/abs/2404.16130`, a GitHub repository URL and a news article into the ask
   bubble: the arXiv report cites the paper's PDF mirror, the GitHub one the README, the article a
   `.html` snapshot and a readable `.md` next to it.
4. With two or more projects registered, drop something ambiguous: the project pick card appears with
   confidence chips and a 10 s countdown; choosing another project moves the report and bumps the priors
   (`project_priors` in the index). Move from the done card does the same later.
5. Drop the same file again: "Already chewed" with Re-chew; Re-chew rewrites the same report path.
6. Save window (quick menu, or `⌘`-drag a window onto the slime): with Screen Recording allowed the
   window's text is OCRed and filed as a window report; without it a toast explains what to allow.
7. No brain configured (Settings → Chat): the report is filed from the text alone with a warning; the
   brain's own `claude -p` calls never add mini slimes.

Scripted version:

```sh
scripts/smoke-ingest.sh                                      # also: pptx extract and a non-text ingest through the CLI
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/kb?add=$PWD/Tests/Fixtures/ingest/sample.pptx&force=1&$T"      # then poll state → ingest.jobs
open "mochlet://debug/kb?url=https://arxiv.org/abs/2404.16130&$T"
open "mochlet://debug/kb?text=Notes%20about%20nothing%20in%20particular&title=Note&question=1&$T"   # forces the pick card
open "mochlet://debug/shot?name=ingest-question&$T"; open "mochlet://debug/kb?pick=inbox&$T"
open "mochlet://debug/kb?move=mochlet&$T"                    # moves the last report (mirrors follow)
open "mochlet://debug/kb?window=1&$T"                        # saves the frontmost window
open "mochlet://debug/state?$T"; python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Logs/Mochlet/debug/state.json')))['ingest'])"
```

