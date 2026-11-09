# How Mochlet is put together

Mochlet is a macOS 26 app written in Swift 6 (strict concurrency) with SwiftUI and AppKit, built
with SwiftPM (`scripts/build-app.sh`) or Xcode (`project.yml` → XcodeGen). Three local packages
hold everything that does not need a window; the app shell is deliberately thin.

```
 coding agents (Claude Code, Codex, Gemini, …)        your files, links, voice, meetings, feeds
        │ hooks (stdin JSON)                                   │
        ▼                                                      ▼
  mochlet-hook (relay, ≤ 300 ms)  ──1 JSON line──▶  ~/Library/Application Support/Mochlet/mochlet.sock
                                                               │
  ┌──────────────────────────── Mochlet.app (LSUIElement) ─────┴──────────────────────────────┐
  │ AppCoordinator — one owner of the stores and controllers, wired at launch (App/AppCoordinator) │
  │   stores: Settings · Notch · Plan                 controllers: Sessions · Approvals · Questions │
  │   Hooks · Installers · Terminal · Projects · Chat · Headless · Knowledge · Ingest · Voice       │
  │   Meetings · Signals · Permissions                                                               │
  │ NotchWindowController (NSPanel over the notch, pointer poll, drag-out) ─▶ NotchRootView (SwiftUI) │
  │ SlimeBridge — the only caller of SlimeKit: main slime, one mini per session, ghost, droplets     │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘
        │ files                                              │ loopback HTTP: MCP + ingest endpoint
        ▼                                                    ▼
  ~/Mochlet/{Knowledge, Meetings, Projects, projects.json, signals/}     mochlet-mcp (stdio shim)
```

## Packages

- **SlimeKit** (`Packages/SlimeKit`): the character. `SlimeKit` is pure (Foundation, simd,
  CoreGraphics): a soft-body ring of Verlet points with anchor, edge, bend and pressure forces,
  a fixed 1/240 s step with render interpolation, eyes projected on a sphere, a blink scheduler,
  gaze smoothing, the state and emote tables, the click grammar, the stage (main, minis, droplets,
  ghost) and the sound table with synthesised recipes. Character 2 added the appearance model
  (`SlimeAppearance` = `SlimeLook` species traits and rest profile, `SlimeTheme` palette or a
  derived hue, `SlimeOutfit`, glyph style, arms), polar rest profiles so a cat is a loaf and a
  ghost a drop, `ArmRig`/`Props` (pseudopod arms published as goo blobs plus hand anchors, props
  on a spring), the chewing v2 timeline, grown glyphs, body morphs, 24 emotes, and two sound packs
  (`SoundPack.puni` squish + formant squeaks, `.classic` chimes; 44 sounds). Character 3 (the
  anime pass, `docs/CHARACTER.md`) made the rest shape a wide flat-based bun (`RestProfile`
  defaults, skirt bumps), the jelly lightly damped with a near-critically damped volume mode
  (`SoftBodyParams.anchorStiffness/damping/bulkDamping`), added `Impulse.poke`, anticipation and
  landing squash in the engine, `FaceStyle` (`anime` stroke tables in `FaceTable`, `round` as the
  earlier ball eyes), `SlimeTheme.material(tint:)` (shell, inner, window, ink line, rim light, glow
  for any palette), sweat accessories, creases and a lagging core. `SlimeKitUI` renders a
  `SlimeFrame` with CoreGraphics in layers (back traits, goo contour of ring + arms + stalks via
  metaballs with a contour cache, two-layer cel body fill: shell, cloud-topped core with windows,
  rim band, hard highlights, ink outline; brush-stroke face via `BrushStroke`, wrap, headwear on a
  lagging spring, front traits, props, glyphs, accessories, particles), picks a detail level from
  pixels per R (full ≥ 36, medium ≥ 24, tiny below), and hosts the Emote Lab, filmstrip and catalog
  tools. `SlimeKitAudio` plays the
  generated WAVs of the chosen pack (user overrides first). Everything is seeded and
  time-injected so filmstrips and tests are reproducible.
- **MochletCore** (`Packages/MochletCore`): two libraries. `MochletCore` is pure logic with no
  AppKit: notch FSM and layout, hook normalisation and session reducer, approval queue, diff engine,
  the config-file editor and one hook spec per agent, terminal jump and launch planners, project
  registry and intent parser, chat protocol parsers, the OKF reader/writer and knowledge index
  (SQLite FTS5 with pre-segmented CJK tokens, retrieval fusion), ingest models, voice intent rules,
  meeting models and the Lark-style transcript, and the signals pipeline pieces (feed parser,
  rubric, hotness, clustering helpers, digest composer, store). `MochletServices` wraps Apple
  frameworks headlessly: `SpeechAnalyzer` transcription, Core Audio process tap and mic capture,
  the lite diarizer, PDF/Office/image/media extractors, `NLContextualEmbedding`, the loopback HTTP
  server, FoundationModels decisions and a folder watcher.
- **App** (`App/`): the shell. `Notch/` (panel, window controller, island views), `Desktop/` (the
  slime loose on the desktop), `Interaction/` (hit view, gestures, drag-out, drops), `Slime/`
  (SlimeBridge, mood policy), `Hooks/` (socket server, relay installer, agent installers),
  `Sessions`-related stores, `Terminal/`, `Projects/`, `Chat/` (providers and headless runners),
  `Knowledge/` (engine, ingest, web reader, MCP routes, host policy), `Voice/`, `Meetings/`,
  `Signals/`, `Services/` (keychain, hot keys, LLM client, permissions, diagnostics, file log),
  `Settings/` (one view per tab) and `Debug/` (the `mochlet://debug` channel, debug builds only).
- **Helpers**: `mochlet-hook` (the relay: Foundation only, always exits 0, holds the socket for
  blocking hooks), `mochlet-mcp` (stdio ⇄ loopback MCP), `mochlet-cli` (reindex, find, lint,
  ingest, diarize). All three ship inside `Mochlet.app/Contents/Helpers` and are copied to
  `~/Library/Application Support/Mochlet/bin/` when their version differs.

## Rules that keep it honest

- **No god object.** `AppCoordinator` only wires; each controller is a `@MainActor @Observable`
  class with one concern and a `start()`/`stop()`. Engines that do real work (`SignalsEngine`,
  `KnowledgeEngine`, the hook socket) are actors.
- **Reducers return effects.** The notch FSM and the session reducer are pure functions returning
  `(state, [Effect])`; timers and I/O happen in the host. Tests drive them with an injected clock.
- **Nothing per-frame goes through SwiftUI.** The character runs on engine time inside one
  CoreGraphics view driven by a display link; it redraws only frames that differ and pauses while
  hidden.
- **Observe, never pin.** Agents are watched through their own hook systems; CLI flags are
  feature-detected from `--help`, parsers tolerate unknown events, and a run that yields no text
  shows a drift banner instead of failing.
- **The user's folders are the truth.** Everything under `~/Mochlet` is human-editable Markdown,
  JSON or audio; everything under `~/Library/Application Support/Mochlet` (indexes, caches,
  `signals.sqlite`, `store.sqlite`) can be deleted and is rebuilt.
- **Lazy permissions.** Each macOS permission is requested by the feature that first needs it,
  with a card explaining why; Settings → General lists them all with Ask/Open buttons
  (`PermissionCenter`). Ad-hoc signed debug builds re-prompt after every rebuild.
- **Secrets stay in the Keychain** (service `com.ilexpwh.Mochlet`), never in logs or defaults, and
  are read off the main thread at launch.
- **Agent-initiated fetches are gated.** Links a coding agent or a feed hands Mochlet go through
  `HostPolicy` (public names and addresses only, redirects checked by the address actually
  connected); only URLs the user typed or configured may reach private hosts.

## Data on disk

| Path | What |
|---|---|
| `~/Mochlet/Knowledge/` | OKF bundle: `inbox/`, `entities/`, `concepts/`, `syntheses/`, `projects/`, `meetings/`, `notes/`, `signals/`, `references/`; `index.md`, `log.md`, `SCHEMA.md` |
| `~/Mochlet/Meetings/<date>-<slug>/` | `transcript.md`, `summary.md`, `meta.json`, audio per retention |
| `~/Mochlet/projects.json`, `~/Mochlet/Projects/` | project registry and cloned repos |
| `~/Mochlet/signals/` | `sources.json`, `rubric.md`, `inbox/` (+ `done/`) |
| `~/Library/Application Support/Mochlet/` | `mochlet.sock`, `bin/`, `index.sqlite`, `store.sqlite`, `signals.sqlite`, `mcp.json`, `Sounds/` overrides, `statusline-previous.json` |
| `~/Library/Logs/Mochlet/` | `mochlet.log` (rolling, 5 MB × 3), `mochlet-<stamp>.log` exports, `debug/` (debug builds) |

## Logging and diagnostics

`MochletLogger(category:)` writes every line to the unified log and to the rolling file; values
marked `privacy: .private` are redacted in both. Settings → General → Diagnostics exports the last
two hours, opens the folders, measures storage and runs the housekeeping that otherwise runs daily
(old exports, debug screenshots, processed inbox files, cached pages). Nothing under `~/Mochlet`
is ever removed by housekeeping; meeting audio follows its own retention rule.

## Building and releasing

`scripts/build-app.sh debug|release` assembles `build/<config>/Mochlet.app` from the SwiftPM
products (Info.plist from `Resources/`, icon, helpers, resource bundles; `CFBundleVersion` is the
commit count, `MochletGitHash` the short hash). Release builds use the hardened runtime and
`Mochlet.entitlements` (audio input, Apple events). `scripts/release.sh` signs with
`SIGN_IDENTITY` (Developer ID), notarises with `NOTARY_PROFILE`, staples, and writes a zip and a
DMG under `build/release/`; without an identity it produces an ad-hoc build for local testing.
`scripts/test.sh` runs SlimeKit, MochletCore, the app tests and the relay checks.
