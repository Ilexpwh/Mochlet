# Mochlet

A glossy little slime that lives in the MacBook notch. It watches your local coding agents
(Claude Code, Codex, Gemini CLI and friends), splits off a mini slime per session, answers
approvals and questions from the notch, eats files and links into a local knowledge base,
listens when you hold it, takes meeting notes and gathers daily AI signals.

This is the v2 rewrite (native Swift 6, SwiftUI + AppKit, macOS 26). The previous
implementation is kept in git history under the tag `v1-final`.

## Talking to the slime

Everything starts from the character, not from forms:

| Gesture | What happens |
|---|---|
| hover | it looks at the pointer; the island grows a little |
| click | `?` bubble with suggestions and the ask field |
| double-click | quick menu (terminal, sessions, projects, knowledge, signals, meetings, settings…) |
| triple-click | meeting note-taker on/off |
| five clicks | it splits into droplets and pulls itself back together |
| hold ≥ 250 ms (or `⌃⌥V`) | push-to-talk: speak, release; the words show as they form and the request is carried out (see Voice) |
| drag anywhere | take it out of the notch: drop it in any corner or edge of any screen and it lives there (eyes on the cursor, same clicks) until you drag it back onto the notch |
| ⌥ drag onto a window | attach that window as context |
| right-click | the full menu |
| drop a file, folder, link or text on it | it chews it into the knowledge base |

The desktop position is remembered across launches ("Let me out" / "Back to the notch" in the menu).

## Watching your coding agents

Install the hooks from Settings → Agents (Claude Code, Codex, Gemini CLI; any other agent can call
the relay, see `docs/AGENTS.md`). Every session you run in a terminal, Cursor or Claude Desktop
becomes a mini slime next to the notch with a one-line ticker; edits become diff chips; permission
requests and AskUserQuestion prompts become cards you answer from the notch (or hand back to the
terminal); the finished turn makes the slime jump; `⌃⌥T` jumps to the exact terminal tab or tmux
pane; plan-usage pills show how much of your Claude and Codex subscription is used.

## Projects and chat

Drop a folder on the slime (or say "make ~/path a project", "clone git@github.com:you/repo.git") and
it lands in `~/Mochlet/projects.json`, a plain file you can edit. Then:

- "work on <project>: <task>" opens a new terminal window (iTerm, Ghostty, Warp, kitty, WezTerm,
  Alacritty or Terminal.app) in that folder running Claude Code, Codex or Gemini with the task; the
  hooks turn it into a mini slime named after the project. With "run tasks in the background" on,
  the agent runs headless instead and reports into the same card.
- "resume <project>" reopens the last session of that agent; "open <project> in cursor".
- Anything else you type is a chat: Claude Code (your subscription), Codex, Gemini, or an API
  provider (Anthropic, OpenRouter, OpenAI, DeepSeek, Qwen, Moonshot, Google, Ollama, LM Studio)
  with a key kept in your keychain. Threads are kept in `store.sqlite`; `⌘K` starts a new one.
- ⌥-drag the slime onto a window, or Attach window in the menu: its title, URL (browsers) and,
  optionally, a screenshot become context for the next message. Dropped text files and links do too.

## Knowledge base

Drop a file, a link or some text on the slime and it chews it into `~/Mochlet/Knowledge/`, an OKF
Markdown bundle (open it in Obsidian). PDFs (with OCR for scanned pages), Word/RTF/ODT, PowerPoint
(slides and speaker notes), images (OCR plus a description when the brain can see), audio and video
(on-device transcription), code and plain text are read in full; links are rendered in a hidden web
view and reduced to the article (arXiv, GitHub repos and files, and YouTube have their own readers).
The brain writes a `report` page (summary, key points, entities, action items, open questions, quotes),
the source is mirrored next to it, a router picks the project (asking you when unsure, with a 10 s
default), and an integrator revises the entity and concept pages the source touches. The ingest card
shows every stage, offers Open / Ask / Move / Re-chew, and a chewing ring sits on the compact strip.
Quick menu → Knowledge (or type `kb: <question>` into the ask bubble) asks the base: the answer streams
with `[n]` citations whose chips open the page at the line, and "File this answer" keeps it as a
`syntheses/` page with backlinks. Lint lists orphans, broken links and pages never integrated. Search is
BM25 over Chinese bigrams and English words plus on-device Apple embeddings. Coding agents reach the same
pages through MCP:

```sh
claude mcp add mochlet -- "$HOME/Library/Application Support/Mochlet/bin/mochlet-mcp"
```

Details in [docs/KNOWLEDGE.md](docs/KNOWLEDGE.md); `scripts/smoke-ingest.sh` exercises the engine
without the app through `mochlet-cli`.

## Voice

Hold the slime (or `⌃⌥V`), talk, let go. Speech stays on this Mac: Apple's `SpeechAnalyzer` writes the
words into the bubble as they form (grey while still changing), the model for your language downloads on
first use (Settings → Voice & Meetings: automatic, 简体, 繁體, 粵語, English, 日本語), and `esc` cancels. What
you said is routed, not just transcribed:

| You say | It does |
|---|---|
| "记一下，明天给老王打电话" · "note to self: buy oat milk" | appends to `Knowledge/notes/YYYY/MM/DD.md` under the minute |
| "work on mochlet: fix the build" · "让咕咕帮我跑一下测试" · "resume coucou" | opens a terminal with the agent on that project |
| "read https://arxiv.org/abs/2404.16130" · "把这个链接存起来" (a link on the clipboard) | chews it into the knowledge base |
| "what did I save about Vision Pro" · "知识库：头显价格" | asks the knowledge base, with citations |
| "open settings" · "start taking meeting notes" · "what's hot in AI today" | the obvious thing |
| anything else | goes to chat; with the chat open, it is dictated into the box instead |

Clear phrasings are matched by rules in a millisecond. The rest, and "which project did you mean", go
to a typed decision: a TypeSafe Jev key if you add one (Settings → Voice & Meetings, with a probe
button), else Apple's on-device model when it is available, else the brain. A missing project is asked
for with chips; say its name or tap, within 20 s. "Speak short replies" answers "Noted" / "On it" aloud.

## Meetings

Triple-click the slime in a call (or say "start taking meeting notes"): it records your microphone and
what the Mac plays through a Core Audio process tap (macOS asks once for System Audio Recording; you keep
hearing the call), transcribes both sides on this Mac as the call runs, and shows the last lines with
level meters, a Mark button and a note field in the island; the compact strip carries a red REC pill.
Stop, and it writes `~/Mochlet/Meetings/<date>-<slug>/`: `transcript.md` in the form Lark Minutes
exports (header, keywords, `Name HH:MM:SS.mmm` turns), `summary.md` (overview, decisions, action items,
open questions, topics with timestamps, your marks), `meta.json`, `diarization.json`, and a
`Knowledge/meetings/` page with the summary and the full transcript, so "what did we decide about
pricing?" has an answer with a timestamp. You are "Me"; the others are told apart on the system channel
(a light on-device diarizer; the echo of their voices in your microphone is removed) and come back as
"Person 2, 3…" with the brain's name suggestions to accept, or rename and merge them on the card. Calls
are noticed on their own: when a known app (Zoom, Teams, Meet, Lark, Webex, Discord, FaceTime…) holds
the microphone, the slime asks "Capture this meeting?" with Not now / Always / Never per app, quiet
hours, and a 30-minute snooze; a call that ends is stopped on its own. Audio retention is yours to
choose (delete, a 7-day AAC mixdown, or keep the WAVs), and a recording cut short by a crash is
finished on the next launch.

## Signals

Mochlet gathers AI news the way AIHOT does, on this Mac, with no server: `~/Mochlet/signals/sources.json`
(AIHOT's format, so its `industry/sources.json` imports unchanged; 21 feeds to start, from OpenAI,
DeepMind, Hugging Face, arXiv cs.AI, Hacker News, The Verge, 量子位, Simon Willison, Import AI and
others) is fetched every minute where due, three sources at a time, 15 min to 3 h apart depending on
what each yields. New items are deduplicated (canonical URL, simhash within 72 h), pass a no-model
prefilter from `rubric.md` (deny list; T2 sources need an industry term), get two independent 0–100
scores from the brain against the rubric, and the ones above their tier's threshold (T1 60, T1.5 65,
T2 76; the rubric's frontmatter overrides them) are written in Chinese and English, embedded on device,
grouped into events (title overlap and centred embeddings propose pairs, the brain confirms them), and
ranked by hotness: independent sources in 48 h, weighted by tier, halving every 24 h. The Signals card
(double-click → Signals, or "what's hot") shows today's count and the top events; a story that is
suddenly everywhere (hotness ≥ 3 while new) makes the slime excited, once an hour at most and never in
quiet hours. At 08:00 (Settings → Signals) the day's digest goes to `Knowledge/signals/YYYY-MM-DD.md` as
a `digest` page: 热点/Hot · 精选/Selected · 简讯/Briefs, one line per event with footnotes to the
sources, an overview from the brain, so it is searchable and Claude Code can read it through the
`signals_latest` MCP tool. Add a source by URL (feeds and list pages are detected, with a preview),
import an AIHOT `sources.json`, push items from other programs (`POST /api/ingest/items` on the local
server with a bearer token, AIHOT's shape, ≤ 50 per call) or drop JSON files into
`~/Mochlet/signals/inbox/`. `x_search` sources need a SocialData key; WeChat accounts need AIHOT's
relay and import disabled. A daily budget caps brain calls (T2 waits first).

## Permissions, logs and housekeeping

Mochlet asks for each macOS permission the first time a feature needs it (microphone for
push-to-talk, system audio for meetings, Accessibility for window titles, Screen Recording only
if you turn window screenshots on, Automation when it talks to a terminal or browser). Settings →
General → Permissions shows where each one stands with Ask and Open buttons. Diagnostics on the
same tab exports the last two hours of Mochlet's log (`~/Library/Logs/Mochlet/`), opens the data
folders, measures them and cleans up derived files (daily by itself; never anything under
`~/Mochlet`). A What's new card appears once per version after the greeting.

## Layout

- `Package.swift` – the SwiftPM app build: executable target `Mochlet` (sources in `App/`),
  tests in `Tests/App`. `project.yml` is the XcodeGen project for Xcode/release builds.
- `Packages/SlimeKit` – the character: soft-body physics, face, states, emotes, click grammar,
  the stage (main slime, one mini per session, split droplets, drag-out ghost) and the sound
  table with synthesised recipes (`SlimeKit`); the CoreGraphics renderer, metaball contours,
  the display-link `NSView`, filmstrips and the Emote Lab (`SlimeKitUI`); the AVAudioPlayer
  pool over the generated WAVs (`SlimeKitAudio`); and `slimekit-tools`.
- `Packages/MochletCore` – pure app logic (notch FSM and layout, hooks, sessions, projects,
  knowledge, signals, meetings) and headless services.
- `App/` – the notch app shell: `Notch/` (panel, window controller, SwiftUI island),
  `Desktop/` (the slime loose on the desktop), `Interaction/` (hit view, drag-out, drops),
  `Slime/` (the only caller of SlimeKit), `Settings/`, `Debug/` (debug URL channel).
- `Helpers/mochlet-hook` – the hook relay (Foundation only, embedded in the app bundle, copied to
  `~/Library/Application Support/Mochlet/bin/` on launch). `mochlet-mcp` and `mochlet-cli` follow.

## Developing

```sh
scripts/build-app.sh debug        # → build/debug/Mochlet.app (SwiftPM; no Xcode project needed)
scripts/build-app.sh release      # → build/release/Mochlet.app (hardened runtime, ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=mochlet scripts/release.sh   # signed, notarised zip + DMG
scripts/dev-run.sh                # build debug and launch; USE_XCODE=1 builds with xcodebuild instead
scripts/test.sh                   # SlimeKit + MochletCore + app tests
scripts/bootstrap.sh              # installs xcodegen, generates Mochlet.xcodeproj (optional)

cd Packages/SlimeKit
swift run slimekit-tools render-filmstrip --state greeting --out ../../out/greeting
swift run slimekit-tools lab              # live Emote Lab window with sliders and every state
swift run slimekit-tools play finish      # audition one synthesised sound
swift run -c release slimekit-tools bench # engine + draw cost
```

Look at `out/<state>/contact.png` and `trace.json` to review motion frame by frame. Sounds can
be replaced per file in `~/Library/Application Support/Mochlet/Sounds/<name>.wav`.

### Driving a debug build without a mouse

Debug builds answer `mochlet://debug/...` URLs, so the app can be exercised and photographed
from a terminal (no screen-recording permission needed; it captures its own windows):

```sh
T="token=$(cat ~/Library/Logs/Mochlet/debug/token)" # per-launch secret, required on every command
open "mochlet://debug/state?$T"                    # ~/Library/Logs/Mochlet/debug/state.json
open "mochlet://debug/shot?name=home&$T"           # …/debug/home.png (+ home-desktop.png when out)
open "mochlet://debug/fsm?input=reveal&$T"         # reveal | collapse | hide | click | launch | …
open "mochlet://debug/view?name=menu&$T"           # home | ask | menu | greeting | …
open "mochlet://debug/pointer?sx=735&sy=940&$T"    # warp the cursor (screen pts); away=1 to leave
open "mochlet://debug/click?count=2&$T"            # 1 ask · 2 menu · 3 meeting · 5 split
open "mochlet://debug/hold?seconds=1.2&$T"
open "mochlet://debug/drag?sx=1400&sy=60&$T"       # drag the slime out (or back onto the notch)
open "mochlet://debug/desktop?sx=1400&sy=60&$T"    # fly out / move; on=0 flies home
open "mochlet://debug/emote?name=love&$T"          # agent?state=working · mini?id=a&state=waiting · split
open "mochlet://debug/hookfile?path=$PWD/Tests/Fixtures/hooks/claude-session.jsonl&$T"   # replay hook events
open "mochlet://debug/approve?decision=allow&$T"   # answer?pick=Label · answer?other=text · session?id= · jump
open "mochlet://debug/settings?tab=agents&shot=1&$T"
open "mochlet://debug/project?add=$PWD&name=Mochlet&$T"   # remove=slug · offer=/path · open=1
open "mochlet://debug/voice?text=记一下，买牛奶&$T"          # route words as if spoken; file=/path.aiff replays audio through the transcriber
open "mochlet://debug/voice?pick=mochlet&$T"               # answer "which project?" (pick=cancel) · start=1 / stop=1 · cancel=1
open "mochlet://debug/meeting?mic=/path/me.wav&sys=/path/them.wav&title=Planning&$T"   # two recordings processed as a meeting
open "mochlet://debug/meeting?start=1&$T"                  # stop=1 · mark=text · detect=1 (what the call detector sees) · rename=p2:Alice · merge=p3:p2
.build/debug/mochlet-cli diarize call.wav                    # who speaks when on one recording, with the similarity matrix behind it
open "mochlet://debug/signals?run=1&$T"                    # fetch every source and run the pipeline; digest=1 · detect=https://… · add=feed|list · import=/path/sources.json
open "mochlet://debug/signals?pushtest=1&$T"               # POST two items to the local endpoint with the stored token (newtoken=1 makes one); push=1 reads inbox/*.json
open "mochlet://debug/diag?perms=1&$T"                     # permission states → result.txt; logs=1 exports the log, clean=1 runs housekeeping, whatsnew=1 shows the card
open "mochlet://debug/ask?text=work%20on%20mochlet%3A%20say%20hi&$T"   # what the ask bubble would do
open "mochlet://debug/workon?project=mochlet&task=say%20hi&headless=1&$T"
open "mochlet://debug/chat?text=hello&$T"               # chat?new=1 · chatstop · attach
open "mochlet://debug/kb?add=$PWD/Tests/Fixtures/knowledge/vision-pro.md&$T"   # kb?find=… · ask=… · file=1 · lint=1 · url=… · text=…
open "mochlet://debug/kb?add=$PWD/Tests/Fixtures/ingest/sample.pptx&force=1&question=1&$T"   # re-chew, always ask; pick=inbox · move=slug · window=1 · retry=1
```

How the pieces fit is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the manual pass before a
release is [docs/VERIFY.md](docs/VERIFY.md).

`scripts/replay-hooks.sh <fixture> [delay] [--ask]` sends the same fixtures through the real relay
and socket; `scripts/test-hook.sh` checks the relay against a fake socket (`scripts/fake-socket.py`).

Rendering is one CoreGraphics path driven by a display link; it only redraws frames that
visibly differ, and it pauses entirely while the island is hidden.
