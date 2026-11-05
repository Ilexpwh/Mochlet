# Mochlet

A glossy little slime that lives in the MacBook notch. It watches your local coding agents
(Claude Code, Codex, Gemini CLI and friends), splits off a mini slime per session, answers
approvals and questions from the notch, eats files and links into a local knowledge base,
listens when you hold it, takes meeting notes and gathers daily AI signals.

This is the v2 rewrite (native Swift 6, SwiftUI + AppKit, macOS 26). The previous
implementation is kept in git history under the tag `v1-final`.

## Layout

- `Packages/SlimeKit` – the character: soft-body physics, face, states, emotes, click grammar,
  the stage (main slime, one mini per session, split droplets, drag-out ghost) and the sound
  table with synthesised recipes (`SlimeKit`); the SwiftUI Canvas renderer, filmstrips and the
  Emote Lab (`SlimeKitUI`); the AVAudioPlayer pool over the generated WAVs (`SlimeKitAudio`);
  and `slimekit-tools` (`render-filmstrip`, `gen-sounds`, `lab`, `play`, `bench`).
- `Packages/MochletCore` – pure app logic (notch FSM, hooks, sessions, projects, knowledge,
  signals, meetings) and headless services.
- `App/` – the notch app shell. `Helpers/` – `mochlet-hook`, `mochlet-mcp`, `mochlet-cli`.
- `docs/` – architecture, agent hook formats, knowledge layout, verification checklist.

## Developing

```sh
scripts/bootstrap.sh              # installs xcodegen, generates Mochlet.xcodeproj
cd Packages/SlimeKit && swift test
swift run slimekit-tools render-filmstrip --state greeting --out ../../out/greeting
swift run slimekit-tools render-filmstrip --state sessions --width 8 --originx 0.25 --out ../../out/sessions
swift run slimekit-tools lab              # live Emote Lab window with sliders and every state
swift run slimekit-tools play finish      # audition one synthesised sound
swift run slimekit-tools gen-sounds --out Sources/SlimeKitAudio/Resources/sounds
swift run -c release slimekit-tools bench # engine + draw cost
```

Look at `out/<state>/contact.png` and `trace.json` to review motion frame by frame. Scripts take
`t:action,…` (see `slimekit-tools help`); states include `pinch`, `sessions`, `ghost`, `split`.
Sounds can be replaced per file in `~/Library/Application Support/Mochlet/Sounds/<name>.wav`.
