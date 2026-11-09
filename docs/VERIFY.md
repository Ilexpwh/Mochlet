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
   "Filed: Apple Vision Pro and spatial computing", `inbox/apple-vision-pro-….md` exists with the source mirrored under
   `inbox/references/`, `log.md` has an `ingest |` line and the root `index.md` lists the report.
3. Drop the same file again: "Already chewed". Drop a PDF: it is mirrored with a stub report (full reading is M7).
   Drop a link: a draft report with the URL as `resource`.
4. Ask on the card (or `kb: what does the Vision Pro cost?` in the ask bubble): the answer streams through the chat
   backend with `[1]` citations; the chips open the report at the cited line (Cursor/VS Code when running);
   a full question such as `how much does the headset cost` works the same way.
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
   permission and the decision stack ("Claude Code", "on-device", "Jev"). Pick a language whose model is not installed yet: the model
   downloads with a progress bar and the card note "Downloading … speech"; a toast says when it is ready.
2. Hold the slime: it leans in with a small `o` mouth and mic bars, the bubble shows "Listening…" with
   five level bars, finals in white and the still-changing words in grey, "release to send · esc cancels"
   and the locale. Release: a nod when it heard something, a shrug when it did not.
3. Say "note to self, call the dentist tomorrow": "Noted." toast, happy hop, `Knowledge/notes/<today>.md` has a `## HH:MM`
   entry, `log.md` a `note |` line; a second note in the same minute joins the entry.
4. Say "start working on the parser" with two projects registered: the `?` bubble asks "Which project?"
   with a chip per project and Cancel; say "mochlet" (or tap) → a terminal opens with the task; wait
   20 s instead → the question expires quietly.
5. Say "what did I save about GraphRAG": the Knowledge card answers with citations. Say "read" followed by
   a URL, or "save this link" with a link on the clipboard: the ingest card chews it.
6. Open the chat, hold and say anything: the words land in the chat box (dictation). Press `esc` while
   listening: the turn is dropped, nothing is sent.
7. Deny the microphone in System Settings: holding shows "Microphone access is off…" and the Voice tab
   offers "Open Privacy settings". Pick a language without a model on a Mac that cannot download it:
   "not supported" in the tab, a toast when holding.

Scripted version (no microphone needed):

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/voice?text=note%20to%20self%2C%20call%20the%20dentist%20tomorrow&$T"; sleep 1; cat ~/Library/Logs/Mochlet/debug/result.txt
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

## Signals (M10)

1. Launch with a chat backend set (Settings → Chat; the brain). Twenty seconds later the first tick
   fetches every source (`~/Mochlet/signals/sources.json` is created with the defaults, `rubric.md`
   next to it). The Signals card (double-click → Signals, or say "what's hot") shows "fetching 21
   sources", then "scoring 12 items" / "writing 10 items" / "grouping n items" as the pipeline runs;
   the count on the right is today's items and how many were kept. Each run scores at most five
   batches (60 items) and the next tick continues; Settings → Signals shows items today · kept ·
   waiting · brain calls against the daily budget, and every source with its item count, next fetch
   time or error (a source that fails backs off up to 12 h).
2. Events: when the same story is written from two sources, the card lists it with its hotness
   (0.5–1.0 per source, halving daily), `↑` when rising, `×n` sources; the row opens the top item.
   A story at hotness ≥ 3 that is less than six hours old makes the slime excited with a toast
   ("Everyone is on it: …"), once an hour, not in quiet hours.
3. Digest: Settings → Signals → Compose digest (or wait for the daily time). `Knowledge/signals/
   YYYY-MM-DD.md` appears with the overview, Hot · Selected · Briefs and `[^eN]`
   footnotes; `log.md` has `digest | AI signals … → signals/….md`; the card's Digest button opens it;
   "Ask" asks the knowledge base about it; `signals_latest` over MCP returns it.
4. Sources: type a site URL in Settings → Signals → Detect: a feed URL says "A feed: … n entries"
   (Add as RSS source); a page lists the feeds it links and, when it has a repeated list of links,
   "A list: n entries under `selector`" with samples (Add as web list). Import AIHOT… merges a
   `sources.json` (added / updated / unchanged / disabled for WeChat accounts). Toggle, change the
   tier or remove a source in the list; Open rubric.md, edit the thresholds or the deny list, Reload
   rubric.
5. Push: Create push token, Copy curl example, paste it in a terminal → `{"ok":true,"created":1}`;
   a wrong token → 401. Drop a JSON file (`{"items": [{"title", "url", "summary"}]}`) into
   `~/Mochlet/signals/inbox/`: it is read within two seconds and moved to `inbox/done/`.
6. Quiet: with no chat backend the sources are still fetched and the card says what is missing;
   items wait three days for a brain and then expire.

Scripted version:

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/signals?run=1&$T"                    # fetch all + pipeline; poll state.json → signals.running / stage / report
open "mochlet://debug/view?name=signals&$T"; open "mochlet://debug/shot?name=signals&$T"
open "mochlet://debug/signals?digest=1&$T"                 # then: cat ~/Mochlet/Knowledge/signals/$(date +%F).md; grep "digest |" ~/Mochlet/Knowledge/log.md
open "mochlet://debug/signals?detect=https://www.theverge.com/ai-artificial-intelligence&$T"   # state.json → signals.detected (two feeds, a list of 25)
open "mochlet://debug/signals?import=$PWD/Tests/Fixtures/signals/aihot-sources.json&$T"       # signals.import: "2 added, 1 updated, …, 1 disabled"
open "mochlet://debug/signals?newtoken=1&$T"; open "mochlet://debug/signals?pushtest=1&$T"; cat ~/Library/Logs/Mochlet/debug/result.txt   # push: 200 {"ok":true,"created":1} | bad token: 401
cp Tests/Fixtures/signals/inbox-items.json ~/Mochlet/signals/inbox/; sleep 3; ls ~/Mochlet/signals/inbox/done
open "mochlet://debug/settings?tab=signals&$T"; open "mochlet://debug/shot?name=settings-signals&window=settings&$T"
```

Seen on this Mac (2026-11-06): 21 feeds fetched in ~30 s; the brain (Claude Code) takes ~25 s per
scoring call and a few minutes per writing batch, so the first run of a fresh install is 10–20 minutes;
`openai.com` resolves to a 100.64/10 address on this network, which is why user-configured sources are
not gated by the public-host policy (only bodies of pushed-in items are).

## Polish and release (M11)

1. What's new: on the first launch of a version the card appears after the greeting (title, four
   lines, Got it / Settings / Guide); Got it marks the version seen. Settings → General → Version →
   What's new shows it again.
2. Permissions: Settings → General → Permissions lists Microphone, System audio recording,
   Accessibility, Screen recording, Automation (per running terminal and browser) and Launch at
   login with a coloured dot and the state (allowed / denied / not asked yet / asked when first
   needed). Ask puts the system prompt up where macOS has one; Open goes to the right System
   Settings pane; Refresh re-reads everything. After a meeting the System audio row says whether
   the tap was allowed.
3. Logs: Settings → General → Diagnostics → Export logs writes `~/Library/Logs/Mochlet/
   mochlet-<stamp>.log` (first line: version, build hash, macOS) and reveals it; the rolling
   `mochlet.log` is there as well. Open Logs folder / Open ~/Mochlet / Open support folder reveal
   the folders; Measure lists the size of each data folder; Clean up now reports what it removed.
4. Housekeeping runs a minute after launch and daily: exported logs older than 14 days, debug
   screenshots older than 7, processed inbox files older than 30, cached pages older than 30.
5. Release: `scripts/release.sh` (ad hoc) produces `build/release/Mochlet-<version>.zip` and `.dmg`;
   with `SIGN_IDENTITY` and `NOTARY_PROFILE` it signs, notarises and staples both.
6. Idle: `scripts/measure-idle.sh 120` with the island collapsed and Settings closed stays under
   1 % of a core.

Scripted version:

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/diag?whatsnew=1&$T"; open "mochlet://debug/shot?name=whatsnew&$T"
open "mochlet://debug/diag?perms=1&$T"; cat ~/Library/Logs/Mochlet/debug/result.txt     # microphone=… | systemAudio=… | …
open "mochlet://debug/diag?logs=1&$T"; cat "$(cat ~/Library/Logs/Mochlet/debug/result.txt)" | head
open "mochlet://debug/diag?clean=1&$T"; cat ~/Library/Logs/Mochlet/debug/result.txt     # removed n files, m bytes
open "mochlet://debug/settings?tab=general&scroll=bottom&$T"; open "mochlet://debug/shot?name=settings-general&window=settings&$T"
scripts/release.sh && ls build/release
```

Seen on this Mac (2026-11-06): the unified log store cannot be read back here (`log show` and
`OSLogStore` both answer "Operation not permitted"), which is why Mochlet keeps its own rolling log
file and exports from it.


## Character 2 (C0–C6)

1. Settings → Character: the preview slime follows the pointer and the emote buttons work on it.
   Pick a look (cat → loaf body with ears, tempest → horns, wings and tail, ghost → a translucent
   drop), a colour swatch or move the hue slider: the notch slime and its minis change at once
   ("Minis a shade lighter" tints only the minis). Pick an outfit set (King, Scholar, Wizard, Santa,
   Summer, Onsen, Night, Idol) or single pieces; the hat rides the body and bounces a beat after a
   landing.
2. Dress for the occasion: drop a PDF → round glasses while it reads; a meeting ask → phone in
   hand; left alone ≥ 90 s in the expanded island → it sips a mug. None of these are saved.
3. Hands: drop a file on the slime: it catches it with both hands, hugs it, bites it (crumbs,
   "hamu"), pages swirl inside while it digests, a sparkle, then the gulp. The greeting ends with a
   wave, an approval with a thumbs up, a hot signal with a cheer and a bell, an error with a
   facepalm; hold to talk → mic in hand (expanded island or desktop only).
4. Expressions: click → poked (side squish, "> <" eyes, "puni"), then the `?` grows out of the body;
   `!` on a shock, `♪` while humming; deny an approval → puff (cheeks, glare, steam); a rate limit
   or thermal pressure → melt; an error that stays > 10 s → cry; voice yes/no → nod / shake.
5. Sounds: Settings → Character → Sounds: pack picker (puni / classic), "Voice squeaks" toggle,
   the All sounds grid plays each one (tinted buttons are voice). A WAV in
   `~/Library/Application Support/Mochlet/Sounds/<name>.wav` (or `<pack>/<name>.wav`) replaces the
   sound after a relaunch.
6. Right-click menu: Look ▸ and Dress up ▸ switch presets without opening Settings.
7. Sizes: the compact notch (R 15) keeps ears, horns, the hat silhouette, eyewear and the chewing
   hands; arms for other poses, grown glyphs and surface particles appear from the expanded island
   (R ≥ 24) and the desktop (R ≥ 36).
8. Performance: `swift run -c release slimekit-tools bench` prints the per-frame draw cost of the
   expensive situations at R 56 (see below); `scripts/measure-idle.sh 120` with the island
   collapsed and a flame look stays under 1 % of a core.

Scripted version:

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/look?look=cat&palette=ruby&outfit=king&$T"; open "mochlet://debug/fsm?input=reveal&$T"; open "mochlet://debug/shot?name=c2-king&$T"
open "mochlet://debug/look?look=tempest&outfit=scholar&dress=1&occasion=reading&$T"; open "mochlet://debug/shot?name=c2-reading&$T"
open "mochlet://debug/chew?kind=pdf&$T"; sleep 1.2; open "mochlet://debug/shot?name=c2-catch&$T"; sleep 2; open "mochlet://debug/shot?name=c2-digest&$T"
open "mochlet://debug/arms?pose=wave&$T"; open "mochlet://debug/arms?pose=holdSide:phone:-1&$T"
for e in poked melt puff shock cry hum cheer hug nod shakeNo thumbsUp stretch; do open "mochlet://debug/emote?name=$e&$T"; sleep 0.4; open "mochlet://debug/shot?name=c2-$e&$T"; sleep 1.5; done
open "mochlet://debug/press?x=52&y=20&$T"; open "mochlet://debug/release?$T"; sleep 0.9; open "mochlet://debug/shot?name=c2-question&$T"
open "mochlet://debug/look?pack=classic&voice=0&$T"; open "mochlet://debug/state?$T"; python3 -c "import json; print(json.load(open('$HOME/Library/Logs/Mochlet/debug/state.json'))['sound'])"
open "mochlet://debug/look?reset=1&$T"
swift run --package-path Packages/SlimeKit slimekit-tools render-catalog --out out/catalog.png      # every look × three palettes at R 56/22/15
swift run --package-path Packages/SlimeKit slimekit-tools render-catalog --sets 1 --out out/sets.png
swift run -c release --package-path Packages/SlimeKit slimekit-tools bench --seconds 3
```

Seen on this Mac (2026-11-06, release build of the tools, CoreGraphics into a bitmap at R 56, 60 Hz):
idle 0.23 ms per frame, hover 0.25, grown `?` 0.54, melt 0.53, cheer with arms 0.91, chewing with
both arms and the file 1.28 (was 2.0 before the C6 pass: edge-local ring field, shorter blob tails,
goo contours as dense polylines with bevel joins, one silhouette clip for both arms, no path
booleans in the arm pass), tempest look idle 0.77, cat 0.68, king outfit 0.42. The goo contour alone
(28 blobs) is 0.40 ms and is reused from the cache while nothing moves more than 0.3 px. `scripts/test.sh`
green (SlimeKit 119, MochletCore 141, app 2, relay).
Idle on this Mac (release build, flame look, island collapsed, Settings closed): `scripts/measure-idle.sh 120`
averaged 4.97 % of a core with a live coding-agent session attached (the main slime and its mini stay in the
working animation at 30 redraws/s; `ps` showed 0.2 % between bursts). The no-session idle figure from M11
(≈ 0.25 % compact) could not be re-measured in that session; re-run with no agent running before a release.

## Character 3 (A0–A7): drawn like the anime

Style guide and measured numbers: `docs/CHARACTER.md`.

1. Shape: at rest (compact strip, expanded island, desktop) the body is a wide bun with a flat base
   and a soft skirt, ≈ 1.37 : 1 wide to tall, not a ball. Every look (cat loaf, ghost drop, puddle,
   spiky, tall) is still distinct.
2. Material: pale shell, a darker cloud-topped core in the lower ~70 % with two or three lighter
   windows, one hard pill highlight upper-left with trailing dots, a thin light rim band at the base,
   one thin dark ink outline (light on obsidian and other dark palettes), a soft floor ellipse. No
   horizontal "water level" band. Lemon, mint and honey still read as two tones.
3. Face: stroke eyes (a bold dash with lash ticks) 0.94 R apart, flat blush ovals, no mouth at rest.
   Emotes keep their language: ᵔ ᵔ + ω happy, > < squeeze, double rings for shock, spirals for dizzy,
   tear ribbons for cry, flat line + ∧ for annoyed and puff, ✦ for excited. Settings → Character →
   Face: "Round eyes" restores the earlier ball eyes everywhere (thumbnails, preview, minis).
4. Motion: `greet` drops in, squashes on landing and wobbles two or three times (≈ 0.45 s period);
   `happy` and `cheer` crouch for ≈ 0.12 s before the hop, stretch thin in the air, squash wide on
   landing; `shock` jumps at once; `melt` spreads in 0.35 s with the face sliding down and comes
   back with one small boing; `puff` inflates both cheeks with creases and lets go with a wobble.
   A press dents the body where the finger is and squints the eyes; the third quick press draws a
   sweat drop. Left alone it breathes, shifts its weight, glances and jiggles every 8–15 s.
5. Sizes: the compact strip (R ≈ 15) shows two tones, the pill highlight, a 1 px ink line and
   legible eye strokes; compact minis (R ≈ 7) read as a two-tone blob with a face hint; the
   expanded island (R 56) shows every detail; the app icon is the new character.
6. Performance: `swift run -c release slimekit-tools bench` stays within idle ≤ 0.25 ms, grown `?`
   ≤ 0.55, cheer with arms ≤ 0.9, chewing with arms ≤ 1.3 per frame at R 56; `idleRedrawsRarely`
   (SlimeKit tests) holds; `scripts/measure-idle.sh 120` with the island collapsed and no agent
   session stays under 1 % of a core.

Scripted version:

```sh
cd Packages/SlimeKit && swift build -c release --product slimekit-tools && T=.build/release/slimekit-tools
$T render-catalog --out ../../out/catalog-56.png --radius 56 --palettes rimuru,ruby,obsidian,lemon,mint,honey
$T render-catalog --out ../../out/catalog-15.png --radius 15 --palettes rimuru,ruby,obsidian,lemon,mint,honey
$T render-catalog --out ../../out/catalog-round.png --face round
$T render-filmstrip --script "0.05:greet" --fps 60 --frames 72 --radius 56 --out ../../out/greet
$T render-filmstrip --script "0.1:emote:happy" --fps 60 --frames 60 --radius 56 --out ../../out/happy
$T render-filmstrip --script "0.1:press,0.4:release,0.7:press,0.95:release,1.2:press,1.45:release" --fps 30 --frames 72 --out ../../out/poke
$T render-filmstrip --script "0.1:emote:melt" --fps 30 --frames 72 --out ../../out/melt
$T bench
cd ../.. && T="token=$(cat ~/Library/Logs/Mochlet/debug/token)"
open "mochlet://debug/shot?name=a-compact&$T"; open "mochlet://debug/view?name=home&$T"; open "mochlet://debug/shot?name=a-home&$T"
for e in puff melt shock cry cheer; do open "mochlet://debug/emote?name=$e&$T"; sleep 0.5; open "mochlet://debug/shot?name=a-$e&$T"; sleep 1.5; done
open "mochlet://debug/press?x=60&y=30&$T"; sleep 0.1; open "mochlet://debug/shot?name=a-press&$T"; open "mochlet://debug/release?$T"
open "mochlet://debug/look?face=round&$T"; open "mochlet://debug/shot?name=a-round&$T"; open "mochlet://debug/look?face=anime&$T"
for p in obsidian lemon rimuru; do open "mochlet://debug/look?palette=$p&$T"; open "mochlet://debug/shot?name=a-$p&$T"; done
open "mochlet://debug/agent?state=error&$T"; sleep 2.6; open "mochlet://debug/shot?name=a-error&$T"
```

Seen on this Mac (2026-11-09, release tools, R 56, 60 Hz): idle 0.16 ms per frame (was 0.23), hover
0.19, grown `?` 0.28 (0.36), melt 0.34, cheer with arms 0.72 (0.82), chewing with arms 1.03 (1.19),
tempest idle 0.55, cat 0.43, king outfit 0.37; the engine costs 0.19 ms per simulated second of an
idle stage. Greeting trace: airborne 0.05–0.42 s, landing 0.80 tall / 1.09 wide, rebound 1.17,
crossings every 0.47 s; happy hop: anticipation 0.94 / 1.07 for 0.12 s, stretch 1.25, landing
0.76 / 1.18, rebound 1.21. SlimeKit 142 tests green.
Idle on this Mac (release build, island collapsed, Settings closed, the What's new card already
seen): `scripts/measure-idle.sh 120` averaged 6.17 % of a core with one live coding-agent session
attached (the main slime and its mini in the working animation; C6 measured 4.97 % the same way).
The no-session figure cannot be taken from inside a Claude Code session, whose hooks keep a session
live; measure it with no agent running before a release. App shots in `~/Library/Logs/Mochlet/debug/
a-*.png` (compact, home, ask, puff, melt, shock, cry, cheer, press, round face, obsidian, lemon,
error) matched the catalog and filmstrips; during the cheer landing squash the raised arms reach
≈ 200 pt, a hair past the 190 pt content leading, for one beat.

## Character 3.1: long eye strokes and nub arms

Review renders (release `slimekit-tools`, gitignored under `Packages/SlimeKit/out/a8`):

```sh
cd Packages/SlimeKit && T=.build/release/slimekit-tools
$T render-catalog --out out/a8/catalog.png --palettes rimuru,obsidian,lemon --looks rimuru,plain,cat --radius 56 --face anime
for pose in cheer wave thumbsUp scratchHead facepalm cover rubEyes "point:1,-0.4" sip "holdFront:doc" "holdHigh:bell" "holdSide:phone:-1" "hug:heart" "hug:self"; do
  $T render-filmstrip --script "0.1:gesture:$pose" --fps 12 --frames 18 --radius 80 --out "out/a8/poses/${pose//[:,]/_}" --face anime
done
```

1. Catalog: each resting eye is one long stroke (0.62 R) with a 0.33 R gap between the two; the
   outer ends stop just inside the blush. At R 16 the mini shows two strokes, not dots.
2. Pose sheet (frame 16 of each strip): every gesture arm is a small sharp triangle poking out of
   the body with a concave flare at its base and no bump of goo around it; the cheer nubs point up
   and out, not straight up like ears; the thumb and pointing capsules are visible; a held prop
   (file, mug, phone, heart) hangs from a thin tentacle; the ink line along a lobe over the body
   starts a third of the way out and never at the base.
3. `swift test` in `Packages/SlimeKit`: 142 tests, `ArmTests.everyPoseStaysWithinReach` holds every
   hand within 1.6 R.
4. `bench` (release, R 56): cheer with arms 0.43 ms, chewing with arms 0.69 ms per frame (A5: 0.72
   and 1.03; the arms no longer add blobs to the contour), idle 0.14 ms.
5. App (debug): `shot?name=hero` on the home view is the README hero; `fsm?input=collapse` then a
   shot shows the long eyes in the compact strip.
