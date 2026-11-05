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
| hold ≥ 250 ms | push-to-talk |
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
```

`scripts/replay-hooks.sh <fixture> [delay] [--ask]` sends the same fixtures through the real relay
and socket; `scripts/test-hook.sh` checks the relay against a fake socket (`scripts/fake-socket.py`).

Rendering is one CoreGraphics path driven by a display link; it only redraws frames that
visibly differ, and it pauses entirely while the island is hidden.
