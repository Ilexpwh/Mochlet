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

## Voice (M8)

1. Settings → Voice & Meetings shows the language, whether its speech model is installed, the microphone
   permission and the decision stack ("Claude Code", "on-device", "Jev"). Pick 中文（简体）: the model
   downloads with a progress bar and the card note "Downloading … speech"; a toast says when it is ready.
2. Hold the slime: it leans in with a small `o` mouth and mic bars, the bubble shows "Listening…" with
   five level bars, finals in white and the still-changing words in grey, "release to send · esc cancels"
   and the locale. Release: a nod when it heard something, a shrug when it did not.
3. Say "记一下，明天给老王打电话": "Noted." toast, happy hop, `Knowledge/notes/<today>.md` has a `## HH:MM`
   entry, `log.md` a `note |` line; a second note in the same minute joins the entry.
4. Say "start working on the parser" with two projects registered: the `?` bubble asks "Which project?"
   with a chip per project and Cancel; say "mochlet" (or tap) → a terminal opens with the task; wait
   20 s instead → the question expires quietly.
5. Say "what did I save about GraphRAG": the Knowledge card answers with citations. Say "read" followed by
   a URL, or "把这个链接存起来" with a link on the clipboard: the ingest card chews it.
6. Open the chat, hold and say anything: the words land in the chat box (dictation). Press `esc` while
   listening: the turn is dropped, nothing is sent.
7. Deny the microphone in System Settings: holding shows "Microphone access is off…" and the Voice tab
   offers "Open Privacy settings". Pick a language without a model on a Mac that cannot download it:
   "not supported" in the tab, a toast when holding.

Scripted version (no microphone needed):

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/voice?text=记一下，明天给老王打电话&$T"; sleep 1; cat ~/Library/Logs/Mochlet/debug/result.txt
open "mochlet://debug/voice?text=start%20working%20on%20the%20parser&$T"; sleep 12   # decision via the brain when no on-device model
open "mochlet://debug/shot?name=voice-question&$T"; open "mochlet://debug/voice?pick=cancel&$T"
open "mochlet://debug/voice?file=$HOME/Mochlet/Knowledge/projects/mochlet/references/<sha12>-speech.aiff&$T"   # any wav/aiff/m4a
sleep 3; open "mochlet://debug/shot?name=voice-listening&$T"
open "mochlet://debug/state?$T"; python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Logs/Mochlet/debug/state.json')))['voice'])"
```

## Meetings (M9)

1. Triple-click the slime during a call: the card says "Starting the microphone…" while macOS asks for
   the microphone and then for System Audio Recording (allow both; without the second the microphone
   alone is recorded and a toast says so). A debug build is ad-hoc signed, so every rebuild asks again;
   the app stays responsive while the prompts are up and Cancel gives up. The island then shows
   the title, a blinking REC dot, the elapsed time, mic and mac meters, then the last three lines as they
   are transcribed ("Me" in blue, "Them" in orange); the compact strip shows the REC pill; the slime is in
   its recording pose. Mark adds a timestamp (wink + blip); a note typed into the field is kept with it.
2. Stop: the card walks through "transcribing your microphone → transcribing the others → telling the
   voices apart → writing the summary → filing", then shows the title, the overview, the speakers and
   Summary / Transcript / Ask / Folder / Done. `~/Mochlet/Meetings/<date>-<slug>/` has `transcript.md`
   (Lark form), `summary.md`, `summary.json`, `meta.json` (status ready, speakers, retention),
   `diarization.json`; `Knowledge/meetings/<id>.md` carries the summary and the transcript; `log.md` has a
   `meeting |` line. With the retention "7-day mixdown", `audio.m4a` replaces the WAVs.
3. Speakers: tap "Person 2 → Yifei?" to accept the brain's suggestion, tap a name to rename it; the
   transcript, summary and knowledge page are rewritten. `meeting?merge=p3:p2` merges two voices.
4. Ask the knowledge base "what did we decide about pricing": the meeting page answers with a timestamp.
5. Detection: join a Google Meet in Chrome (or a Zoom/Lark call). Within ~10 s of the app holding the
   microphone the slime asks "Capture this meeting in Google Meet?" with Capture / Not now / Always /
   Never for it. Always → the next call starts on its own; Never → Settings → Voice & Meetings lists the
   app with its mode. Quiet hours keep it silent. Leaving the call for 60 s stops the recording.
6. Quit the app while recording, relaunch: the folder is finished and filed (recovery).

Scripted version (no call needed; three `say` voices stand in for the people):

```sh
S=/tmp/call; mkdir -p $S
say -v Samantha -o $S/mic.aiff "[[slnc 2000]] Hi everyone. [[slnc 6000]] Let's ship on Friday."
say -v Daniel -o $S/sys.aiff "[[slnc 500]] Hello. [[slnc 5000]] Should we ship on Friday? [[slnc 6000]] Great."
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/meeting?mic=$S/mic.aiff&sys=$S/sys.aiff&title=Release%20planning&$T"
# poll state.json → meeting.state: processing (stage, progress) → review; then
open "mochlet://debug/shot?name=meeting-review&$T"
open "mochlet://debug/meeting?rename=p2:Daniel&$T"; open "mochlet://debug/meeting?detect=1&$T"; cat ~/Library/Logs/Mochlet/debug/result.txt
```
