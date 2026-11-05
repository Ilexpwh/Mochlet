# Mochlet

A glossy little slime that lives in the MacBook notch. It watches your local coding agents
(Claude Code, Codex, Gemini CLI and friends), splits off a mini slime per session, answers
approvals and questions from the notch, eats files and links into a local knowledge base,
listens when you hold it, takes meeting notes and gathers daily AI signals.

This is the v2 rewrite (native Swift 6, SwiftUI + AppKit, macOS 26). The previous
implementation is kept in git history under the tag `v1-final`.

## Layout

- `Packages/SlimeKit` – the character: soft-body physics, face, states, emotes, click grammar,
  sounds (`SlimeKit`), the SwiftUI Canvas renderer (`SlimeKitUI`) and `slimekit-tools`
  (`render-filmstrip`, `gen-sounds`).
- `Packages/MochletCore` – pure app logic (notch FSM, hooks, sessions, projects, knowledge,
  signals, meetings) and headless services.
- `App/` – the notch app shell. `Helpers/` – `mochlet-hook`, `mochlet-mcp`, `mochlet-cli`.
- `docs/` – architecture, agent hook formats, knowledge layout, verification checklist.

## Developing

```sh
scripts/bootstrap.sh              # installs xcodegen, generates Mochlet.xcodeproj
cd Packages/SlimeKit && swift test
swift run slimekit-tools render-filmstrip --state greeting --out ../../out/greeting
```

Look at `out/<state>/contact.png` and `trace.json` to review motion frame by frame.
