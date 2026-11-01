# Coucou source porting guide for Mochlet

Research date: **1 November 2026**. Scope: native file feeding, voice input, keyboard interaction, attachments, usage presentation and panel reliability. This is port guidance, not an implementation claim or a complete audit of Coucou.

## Evidence and attribution

The local checkout `/Users/ilexpoon/Mac-notch-ai-project/coucou` is clean at **`b6a85f29719b5291651c092e33b3f9d4004d091e`**. The same revision and its license were verified against [upstream](https://github.com/Louis-CFM/coucou/tree/b6a85f29719b5291651c092e33b3f9d4004d091e). Its [MIT license](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/LICENSE) credits **Copyright (c) 2026 Louis Raillé**. Retain that copyright and the complete permission/disclaimer text for copied or substantially adapted code. Record source commit, file, symbols and local modifications in Mochlet's third-party notices; keep short attribution headers on adapted source files.

Tier 2 graph verification used project `Users-ilexpoon-Mac-notch-ai-project-coucou`, generation **2026-11-01T07:48:16Z**. Every evidence path below was checked for coverage/freshness. All reported metadata matched. Partial parser ranges in `IslandWindowController.swift`, `IslandViewContent.swift`, `HotKeyCenter.swift`, `ClaudePlanCardView.swift` and `AppState.swift` were read directly; the excluded `LICENSE` was also read directly. Graph traces produced some improbable cross-language/self-call edges, so concrete call-chain claims below were checked in source rather than inferred from graph degree. No graph mutation or source modification was performed.

## Ports with the highest value

| Priority | Source and exact symbols | Coupling and cost | Mochlet adaptation |
|---|---|---|---|
| 1 | [`FileDropView.swift:8`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/FileDropView.swift#L8): `FileDropNSView`, drag callbacks | Small AppKit view; no third-party package. Its `hitTest` returns nil while AppKit handles dragging. | Port the drag destination separately from the ingestion handler. Connect callbacks to Mochlet's attachment queue. Accept/reject based on supported URLs before showing success. |
| 1 | [`FlowKeyLogic.swift:11`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/FlowKeyLogic.swift#L11): `FlowKeyLogic`, `Phase`, `Action`, `keyDown`, `keyUp`, `otherKey`, `escape`, `tick` | Foundation-only input state machine. No audio, authorization, UI or external package dependency. | Good isolated port for hold-to-talk, double-tap lock and cancellation. Change `finish` to produce editable text in Mochlet's composer; never inherit automatic paste or send behavior. |
| 1 | [`IslandStateMachine.swift:5`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandStateMachine.swift#L5): `IslandStateMachine`, `openedExternally`, `collapse`, `userInteracted`, `isHeldOpen` | Foundation/main-actor state machine with callback and timers; no AppKit dependency. | Use the separation of presentation state from work state. Pin the panel while approvals, a draft, recording or a drag require it. Make recording lifecycle independent of panel collapse. |
| 1 | [`ClaudePlanCardView.swift:100`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/ClaudePlanCardView.swift#L100): `GaugeRowView`, plus card timestamp styling | SwiftUI, `PlanWindow`, palette/localization helpers. Small presentation extraction. | Port compact percentage bars, monospaced digits and reset labels into a provider-neutral usage card. Feed it Mochlet's supported telemetry and explicit stale/unknown states. |
| 2 | [`IslandViewContent.swift:5043`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandViewContent.swift#L5043): `ContextChip` | SwiftUI plus `PromptContext` and color helper. One context at a time upstream. | Adapt to identifiable attachment chips with filename, source, extraction state, remove action and accessible label. Use a short arrival pulse with a reduced-motion alternative. |
| 2 | [`IslandDisplayChoice.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandDisplayChoice.swift): `IslandDisplayChoice`, `IslandDisplayCandidate`, `IslandDisplayResolver.index` | Foundation-only choice serialization and resolver. | Add explicit notch/menu-bar/chosen-display settings. Persist display UUID, fall back when disconnected, and avoid moving an open editor just because the pointer crossed screens. |

## File feeding and chewing: reuse choreography, replace completion logic

The verified native wiring is `IslandWindowController.setupPanel` → `FileDropNSView` callbacks → `UploadSequenceEngine.enterZone/updateCursor/exitZone`, then `FileDropHandler.handle` → `performDrop`. The controller places the SwiftUI hosting view and drag destination as siblings in a common container. This is a useful pattern for avoiding a transparent SwiftUI drag layer blocking buttons. [Controller wiring, lines 118–186](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandWindowController.swift#L118)

[`UploadSequenceEngine.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/UploadSequenceEngine.swift) supplies `USC`, easing functions, a spring simulation and `UploadSequenceEngine.frame(at:)`. `performDrop(uploadDuration:)` resets phase time while retaining spring position/velocity. This preserves continuity after any amount of hovering. Dependencies are Foundation/CoreGraphics and the types within the file; its coordinate system is fixed to 640×176.

[`UploadCanvasView.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/UploadCanvasView.swift) supplies `drawScene`, `drawMochi`, `drawFile` and `drawProgressBar`. It uses SwiftUI `Canvas`/`TimelineView`, AppKit file icons, `AppState` and the sequence engine. Port the timeline and squash/chew ideas into Mochlet's simpler slime renderer. Replace fixed-position invisible action overlays with normal accessible controls, and stop animation scheduling when no animation is active.

**Do not transplant `FileDropHandler.handle` unchanged.** It takes only `urls.first`, runs file copying in a detached task, and animates a fixed 2.4-second progress interval independently of copy completion. A failed copy leaves the original URL and can still reach the visual success sequence. Its delayed copy completion can replace the current global attachment state. [Handler, lines 65–162](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/FileDropView.swift#L65)

For Mochlet, assign each import an ID and explicit accepted/copying/extracting/indexing/ready/failed state. Chewing can loop while work runs; the checkmark must wait for real completion. Queue multiple files, reject unsupported folders visibly, and keep cancellation and retry scoped to the import ID. Prefer an indeterminate indicator when extraction cannot report meaningful progress. These changes are Mochlet recommendations.

## Voice and push-to-talk

[`MacDictation.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/MacDictation.swift) offers useful lifecycle examples: `start(from:)` preserves the typed prefix, `finish()` stops audio and waits up to 1.5 seconds for final recognition, and `stop/tearDown` clean up requests/taps. It uses AVFoundation, Speech and Carbon, plus `DictationTranscript` and optional `FlowAudioBands`. Its Apple-recognizer implementation should remain an optional provider, not replace the approved OpenRouter selection.

[`DictationTranscript.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/DictationTranscript.swift) is a small Foundation helper with `Piece`, `absorb`, `isRestart` and temporal merging. It is useful for Apple recognizer restart behavior. Its whitespace-based restart heuristic is not evidence of Chinese-language correctness, and it should not merge separate meeting chunks or global speaker identities. Evaluate with actual Cantonese/Mandarin fixtures before porting its heuristics.

[`PromptView`, lines 1434–1618](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandViewContent.swift#L1434) demonstrates the microphone stop/start affordance, language menu, final-word wait and destination/model chip. Extract layout ideas; the full view couples to `AppState`, `ClaudeService`, chat history and its own transient draft. Mochlet should retain its durable composer and explicit project destination.

Do not import all of [`FlowDictation.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/FlowDictation.swift) for in-app PTT: it includes Accessibility checks, global key monitoring, clipboard/paste injection, Flow history/pill state and Apple/Parakeet selection. That is a much larger product feature than dictating to the slime. `FlowKeyLogic` is the useful low-cost seam. Coucou's [project configuration](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/project.yml#L16) pins FluidAudio **0.17.7** for its broader dictation/notetaker features; copying those subsystems adds that dependency and model lifecycle work.

## Shortcuts and usage: preserve semantics

[`HotKeyCenter.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/HotKeyCenter.swift) implements `start`, `registerAll`, `reregister`, `unregisterAll` and `registerOne` using Carbon `RegisterEventHotKey`. [`ShortcutLogic.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/ShortcutLogic.swift) holds `ShortcutSpec`, persistence, duplicate detection and modifier conversion separately. This is a small zero-package alternative to KeyboardShortcuts for show/hide and navigation. Rename the event signature, action IDs and preference keys; surface registration conflicts. The inspected handler registers **key-pressed events**, so it is not a complete hold/release PTT implementation by itself.

Reuse usage-card presentation but not all policy from [`ClaudePlanGauge.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/ClaudePlanGauge.swift). Its `effectivePct` returns zero when a stored reset time passes. Mochlet must mark that snapshot stale and refresh; it cannot assert zero usage without telemetry. The card's visible-only 30-second countdown is a useful efficient rendering pattern.

[`CodexPlanGauge.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/CodexPlanGauge.swift) has a compact `account/rateLimits/read` example and `CodexPlanCardView`. Prefer Mochlet's existing correlated runtime transport over its separate short-lived subprocess. Its parser groups windows into five-hour/seven-day buckets using a duration threshold and reads `rateLimits`; Mochlet should preserve actual window durations and supported limit IDs, and distinguish missing data from exhausted quota or API spending.

## Panel reliability: targeted behaviors, not the entire controller

`IslandWindowController.swift` exceeds 2,200 lines and combines voice actions, desktop dragging and integrations. Extract only the following seams, all verified in the [pinned controller](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/IslandWindowController.swift):

- `setupPanel` (104): transparent panel, all-Spaces/full-screen behavior, sibling drag destination, and becoming key only for text input.
- `relocate` (244) and the screen-change observer (226): recompute geometry when a display disconnects, resolution changes or the lid closes.
- `adjustPollRate` (449), `observeScreenForPolling` (556), `pausePollingForScreenOff` (573): reduce pointer polling away from the island and stop it when asleep/locked. Adopt the behavior after measuring; upstream constants are not proof of Mochlet's idle CPU target.
- `IslandPanel` (1587): key-capable but not main-window behavior and notch-position constraints. Validate focus restoration and settings dialogs on macOS 15 separately.

## Acceptance sequence for the ports

1. File drag: enter/exit rapidly, drop several files, cancel a large import, fail a copy and preserve an existing draft. No success pose before ingestion succeeds.
2. PTT: repeat key-down, quick tap, hold/release, double tap, Escape, microphone permission failure and cancellation during audio startup. Text stays editable before submission.
3. Usage: missing field, stale snapshot, elapsed reset, multiple limit buckets and provider disconnection. Never show invented remaining capacity.
4. Panel: switch Spaces, attach/detach displays, lock/sleep, full-screen app, keyboard navigation and interrupted open/close animation. Work and recording state survive presentation changes.
5. Accessibility/performance: VoiceOver labels for attachments and controls, reduced motion, native focus order, idle CPU and frame/stall measurements.

No Coucou component was copied or integrated by this research task. The source locations above are narrow candidates for implementation and validation within Mochlet's existing architecture.

## Meeting capture and Notetaker follow-up

The following assessment uses the same pinned revision. Additional coverage checks included `NoteAudio.swift`, `NoteTaker.swift`, `ParakeetEngine.swift`, `NoteModels.swift`, `NoteEcho.swift` and `ScreenCapture.swift`. Metadata matched; `NoteTaker.swift:505` and `ParakeetEngine.swift:178–179` were reported partial and read directly. Conclusions about missing recovery behavior below are bounded to the inspected capture/Notetaker implementation, not a claim that no other Coucou subsystem handles sleep or devices.

### Small capture components worth adapting

| Source | Verified behavior and dependencies | Port guidance |
|---|---|---|
| [`NoteAudio.swift:126`, `MicCapture`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteAudio.swift#L126) | `start(sink:)` installs a 2,048-frame `AVAudioEngine` input tap, converts samples to 16 kHz mono, and reports startup success/failure. `stop()` removes the tap and stops the engine. Depends on AVFoundation and `Resampler16k`. | A small microphone-capture seam. Add idempotent lifecycle, explicit error delivery, configuration/device-change handling and capture-generation IDs. Keep audio callbacks separate from UI and storage. |
| [`ParakeetEngine.swift:161`, `Resampler16k`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/ParakeetEngine.swift#L161) | A roughly 33-line `AVAudioConverter` wrapper producing float32 mono samples at 16 kHz. This class itself does not call FluidAudio, despite living in the Parakeet source file. | Extract with AVFoundation only. Preserve one converter per serial source; return conversion errors instead of silently returning an empty sample array. Test real 44.1/48 kHz inputs, non-interleaved formats and route changes. |
| [`NoteAudio.swift:9`, `ChannelRecorder`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteAudio.swift#L9) | Uses a serial writer queue, `OSAllocatedUnfairLock` for live samples, RMS meters and a shared uptime origin for both sources. Adds initial silence to align delayed source startup. `takeChunk` returns a time offset and samples; `close` drains writes. Depends on AVFoundation, AudioToolbox, `os` and the resampler format. | Reuse the separate-track/shared-origin concept and meter calculation. Replace plaintext continuous-WAV writing with Mochlet's encrypted segment store and journal. Bound pending buffers and write queues, propagate disk failures, and preserve explicit gap intervals. |
| [`NoteAudio.swift:155`, `SystemAudioTap`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteAudio.swift#L155) | Uses a **Core Audio process tap**, private aggregate device and `AudioDeviceCreateIOProcIDWithBlock`. Its global tap excludes an empty process list; it captures all system audio. It handles aggregate input buffers that include a headset microphone. Depends on CoreAudio, AVFoundation and the resampler. | Useful Core Audio reference, **not a ScreenCaptureKit adapter**. It does not provide the requested application/source picker. Keep Mochlet's approved ScreenCaptureKit path unless deliberately adding a separately selected whole-system backend later. |

The named `ScreenCapture.swift` in this checkout is not the Notetaker's system-audio implementation. The verified Notetaker path is `NoteTaker.start` → `MicCapture` / `SystemAudioTap` → two `ChannelRecorder` instances. No `SCStream` capture path was found in those inspected files. Building the requested ScreenCaptureKit source-selection adapter remains Mochlet work.

### Transcript and diarization reference

[`NoteTaker.startLiveLoop`, lines 212–231](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteTaker.swift#L212) polls every second and processes available microphone/system chunks through local Parakeet. Provisional labels are source categories (`me` and `others`). `ChannelRecorder.takeChunk` normally waits for at least four seconds and a quiet tail, or eighteen seconds of buffered audio; these are polling thresholds, not a hard bound while inference is slow. A failed provisional transcription is skipped through `try?`, while the complete WAV remains for final processing.

[`NoteTaker.process`, lines 236–310](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteTaker.swift#L236) retranscribes whole files at stop, then uses FluidAudio's `OfflineDiarizerManager` through `diarize` (334). For a call, system audio is diarized and microphone echo is filtered; for a room recording it can diarize the microphone. Results replace the note's speaker/line arrays. This is useful evidence for a two-track offline workflow, but is not versioned provisional-to-final reconciliation or an OpenRouter adapter.

[`NoteModels.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteModels.swift) offers Foundation-only `TimedWord`, `SpeakerTurn`, `NoteLine` and `NoteBuilder.assign/lines/build/buildRoom` as optional reference seams. `NoteTaker.rename(_:speaker:to:)` and `assign` support renaming, merging same-named speakers and correcting line attribution. [`NoteEcho.swift`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteEcho.swift) contains level/lag-based echo heuristics. Evaluate these against overlap, speakers on loudspeakers and Chinese/code-switched speech; do not treat echo-filtered text or a nearest-speaker assignment as certainty.

### Gaps against the approved Mochlet meeting contract

| Requirement | Inspected Coucou implementation | Required Mochlet behavior |
|---|---|---|
| Selected source and visible failure | [`start`, lines 113–168](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteTaker.swift#L113) starts a global system tap and logs failure while continuing microphone-only. `note.app` is descriptive frontmost-app metadata, not a capture filter. | Explicit microphone-only versus microphone+selected source. Display failed/missing source and ask for a deliberate source change; never imply the chosen app was captured. |
| Pause on lock/sleep, explicit resume | The inspected `NoteTaker` has start/stop/shutdown but no paused state, sleep/lock observer or explicit resume method. `MicCapture` and `SystemAudioTap` do not install device-change listeners. | Pause segments on lock/sleep and retain the visible paused reason. Resume only after a user action. Handle headset/output-device changes with a new source segment and a visible gap. |
| Encryption and seven-day retention | [`ChannelRecorder`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteAudio.swift#L30) writes ordinary WAV files. Successful `process` deletes both WAVs immediately; failure leaves them for retry. No seven-day/keep-recording policy appears in these inspected paths. | Encrypt local segments using a Keychain-held key, compute expiry from recording time, and implement keep/delete actions and reliable cleanup. Do not inherit delete-on-success. |
| Disk/network failure | WAV writer errors are discarded with `try?`; pending samples are an in-memory array. Local Parakeet provides no remote retry ledger. | Stop or pause visibly on persistence failure. Bound memory, persist upload/transcription attempts, and retry by segment ID without duplicate transcript entries. |
| Recovery | [`shutdown`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteTaker.swift#L172) closes writers and marks processing. [`load`](https://github.com/Louis-CFM/coucou/blob/b6a85f29719b5291651c092e33b3f9d4004d091e/NotchBuddy/Sources/App/NoteTaker.swift#L656) resumes processing from WAVs after recording/processing status. | Keep the recovery idea, backed by segment manifests and durable revisions. An interrupted recording must not restart capture automatically. Test truncated final segments and failures between audio and metadata writes. |
| Provider and source-linked output | Coucou's Notetaker selects local Parakeet and Claude/Apple/off summaries; its Claude helper can retry a different model. `NoteTodo` stores text/owner/due/done but no transcript citation IDs. | Use the selected OpenRouter profile with no silent fallback. Scope speaker IDs to each request, retain transcript revisions, and cite source segment IDs in summaries and proposed tasks. |

Recommendation: port **MicCapture + the isolated Resampler16k** first if they improve the current audio layer; borrow ChannelRecorder's timing concepts without its persistence policy. Keep meeting orchestration, ScreenCaptureKit selection, encrypted segment retention, provider scheduling and revision recovery native to Mochlet. Reusing the entire Notetaker would add FluidAudio/model downloads, Flow UI/state, Anthropic calls and incompatible lifecycle policies.

## Provider adapter follow-up: Pi RPC and Claude control transport

Verified 1 November 2026. This section describes implementable contracts, not integrated or live-tested adapters. Only installed executable discovery, `claude --version` and `claude --help` were run locally; no authentication, private sessions or remote inference were accessed. Context7 documentation was cross-checked against pinned first-party source.

| Provider | Research pin | Local evidence and license |
|---|---|---|
| Pi | [`v1.4.0`, commit `4a080252f06caf63a525d7873c5d94d3c23887e0`](https://github.com/earendil-works/pi/tree/v1.4.0) | No `pi` executable on PATH. Repository moved from `badlogic/pi-mono` to `earendil-works/pi`; [MIT](https://github.com/earendil-works/pi/blob/v1.4.0/LICENSE). Preserve notice if incorporating its extension/examples. |
| Claude | Installed `/Users/ilexpoon/.local/bin/claude`, version **2.1.296**. SDK protocol reference [`claude-agent-sdk-python v0.2.176`, commit `2146f9d8985513053e904b13200c8f744b36785a`](https://github.com/anthropics/claude-agent-sdk-python/tree/v0.2.176) | The [Python SDK license is MIT](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/LICENSE); that does not license Claude Code binaries or service access. Source-compatible envelopes still need a fixture and an authorized live check against the installed CLI before declaring support. |

### Pi: native JSONL transport

Run a long-lived `pi --mode rpc` process with `Process.currentDirectoryURL` set to the registered project root. Read stdout continuously as LF-delimited JSON; keep stderr separate. Assign unique string request IDs and register completion listeners before writing prompts. `prompt` responses acknowledge acceptance; `agent_settled` marks settlement after queued work, retries and compaction. `agent_end` alone is insufficient. A prompt disposition of `handled` does not promise a subsequent settled event. These are documented RPC contracts in [rpc.md](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc.md), with [stream events in json.md](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/json.md).

Persist the exact `sessionId` and `sessionFile` returned by `get_state`. For a new task, use a fresh process/session, or `new_session` when idle. For resumption, prefer the absolute stored session path over prefix matching:

```jsonl
{"id":"state-1","type":"get_state"}
{"id":"resume-1","type":"switch_session","sessionPath":"/absolute/mochlet-owned/session.jsonl"}
{"id":"state-2","type":"get_state"}
{"id":"prompt-1","type":"prompt","message":"Implement the confirmed change in this project."}
```

Wait for each dependent response. `new_session` and `switch_session` can return `success:true` with `data.cancelled:true` when an extension blocks them; do not dispatch after that. Recheck identity after switching. The documented `get_state` response contains no working-directory assertion: Mochlet must validate its project/session binding and launch directory itself. CLI `--session <path|id>` also supports exact paths, whereas `--session-id` creates an absent session and `--resume` opens a selector; neither is the right substitute for verified exact resume. Do not use `--no-session` from minimal examples for durable tasks. [RPC commands](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-commands.md), [CLI session options](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/cli.md#sessions).

Representative stream records:

```jsonl
{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Working…"}}
{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"bash","args":{"command":"swift test"}}
{"type":"tool_execution_end","toolCallId":"tool-1","toolName":"bash","result":{"content":[]},"isError":false}
{"type":"agent_settled","aborted":false}
```

Reconcile final content with `message_end`; do not append finalized blocks twice. Keep thinking separate from user-facing answers. Settlement is not proof of success: retain provider errors and tool outcomes. See [JSON event and message reference](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/json.md).

Cancellation is deliberately more than a signal. For “stop all queued work”, send and await `clear_queue`, preserve its returned steering/follow-up messages as canceled drafts, then send `abort`. `abort` waits for idle but does not clear the queue. Separate `abort_retry` and `abort_bash` exist for retry delays and explicit RPC bash execution. Ordinary prompt submissions while busy must deliberately specify `streamingBehavior:"steer"` or `"followUp"`; Mochlet's initial one-run queue should avoid doing this implicitly. [Command reference](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-commands.md).

### Pi: questions, approval boundary and usage

Extensions use `extension_ui_request` with a request `id`. Handle `select`, `confirm`, `input` and `editor`; respond through `extension_ui_response`, not a generic RPC response. For example:

```jsonl
{"type":"extension_ui_request","id":"question-1","method":"confirm","title":"Allow operation?","message":"Requested operation details","timeout":10000}
{"type":"extension_ui_response","id":"question-1","confirmed":false}
```

`select`, `input` and `editor` return `value`; dismissal returns `cancelled:true`. Timed requests may resolve before the user responds, so expire local cards and do not claim late delivery. `notify`, `setStatus`, `setWidget`, `setTitle` and `set_editor_text` are notifications and require no response. RPC supports the documented dialog bridge, not arbitrary terminal `ctx.ui.custom()` renderers. See [rpc-extension-ui.md](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-extension-ui.md).

**Pi's RPC dialog bridge does not automatically gate tool execution.** A Mochlet-controlled extension must intercept `tool_call`, await a dialog and return `{block:true,reason:...}` on denial. Upstream's [permission-gate.ts](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/examples/extensions/permission-gate.ts) is only a small dangerous-bash-pattern example; copying it is not a complete approval policy. Tool hooks also see nested calls made through `ctx.executeTool`. Extensions run with the process's OS permissions and can perform effects outside tool hooks, so this mechanism is not a sandbox. [Extension contract](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/extensions.md).

Recommended first supported Pi configuration: load only the app's reviewed permission extension with `--no-extensions -e <absolute-extension-path>`; this still permits explicitly specified extensions. Decide project trust visibly: `--no-approve` ignores trust-gated project-local resources and is **not** “ask before every tool”. `--tools` does not by itself remove all MCP reachability; use the documented MCP exclusion or `--no-mcp` for an initial configuration without MCP. These are deliberate compatibility settings, not an assertion that arbitrary user extensions are safely controllable. [CLI resources/tool options](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/cli.md).

`get_session_stats` exposes tokens (`input`, `output`, `cacheRead`, `cacheWrite`, `total`), estimated `cost`, message/tool counts and optional `contextUsage`. Totals span the session, including tool-reported usage and summary generation; context estimates may be null after compaction. Display these as session usage, not account balances or weekly limits. No account quota contract is established by these RPC fields. [Statistics contract](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-commands.md#get_session_stats).

### Claude: bidirectional approval transport

The official SDK spawns the CLI using `--output-format stream-json --verbose --input-format stream-json`; enabling `can_use_tool` adds `--permission-prompt-tool stdio`. Use the default permission mode for interactive approval behavior, an explicit launch directory, and `--resume=<exact-session-id>` for a resumed task. The equals form binds the value reliably even if it begins with a dash. `--allowedTools` changes auto-approval, not tool availability; broad entries can prevent the desired callback. The current SDK command builder does not add `-p` for its streaming path. [Pinned subprocess command builder](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/transport/subprocess_cli.py), [stdio permission configuration](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L2281), [permission evaluation](https://code.claude.com/docs/en/agent-sdk/permissions).

Wire sequence, with initialization completed before the user message:

```jsonl
{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize","hooks":null}}
{"type":"user","session_id":"","message":{"role":"user","content":"Implement the confirmed change."},"parent_tool_use_id":null}
```

The CLI can then request permission:

```jsonl
{"type":"control_request","request_id":"approval-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"swift test"},"tool_use_id":"tool-1"}}
```

Reply once using the **request ID**, preserving the original input for an unmodified approval:

```jsonl
{"type":"control_response","response":{"subtype":"success","request_id":"approval-1","response":{"behavior":"allow","updatedInput":{"command":"swift test"}}}}
```

Or decline:

```jsonl
{"type":"control_response","response":{"subtype":"success","request_id":"approval-1","response":{"behavior":"deny","message":"User declined this operation."}}}
```

Do not echo `permission_suggestions` into `updatedPermissions` for “allow once”; that would change permissions. `control_cancel_request` with the same request ID invalidates an outstanding card, and no response should follow it. Concurrent control requests need separate durable identities and UI states. Unknown control subtypes should return a correlated error rather than silently approve. These envelopes and cancellation behavior come directly from [query.py](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/query.py#L395) and [typed request definitions](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L2801).

`AskUserQuestion` arrives through the same permission callback. Render the original `questions` array, retaining each full question string as its answer key. Return an allow response with `updatedInput` containing the original questions plus `answers`; values can be selected labels, arrays for multi-select, or user-entered text. Keep this distinct from an action approval in the UI. [Official user-input contract](https://code.claude.com/docs/en/agent-sdk/user-input#handle-clarifying-questions).

Cancel an active turn with:

```jsonl
{"type":"control_request","request_id":"cancel-1","request":{"subtype":"interrupt"}}
```

Track `result.is_error`, `terminal_reason` and the actual session ID; `subtype:"success"` alone can coexist with an API failure. `aborted_streaming` / `aborted_tools` indicate interruption. A result ends a turn, but background tasks can keep the run alive. The pinned SDK requests `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` and tracks `system/session_state_changed` plus task lifecycle before closing stdin. A native adapter must preserve that distinction or explicitly limit unsupported background behavior; closing stdin at the first result can break later permissions. [Result model](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L1695), [run completion and interrupt implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/query.py#L454), [environment opt-in](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L850).

Claude result records provide optional `total_cost_usd`, `usage` and per-model usage. These describe inference activity and must not be presented as subscription weekly remaining capacity. Preserve unavailable values as unavailable. A native Swift transport is feasible from these first-party envelopes, but the public supported abstraction is the SDK; pin CLI compatibility fixtures and retain an explicit unsupported-version state. Do not infer a permanently stable public wire API from SDK internals. [Pinned result schema](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L1695).

### Next implementation acceptance cases

Before marking either adapter complete, verify fragmented/coalesced JSONL, out-of-order request replies, expired dialogs, process loss while approval is pending, duplicate UI responses, exact-session mismatch and cancellation with queued/background work. Pi additionally needs a deliberate approved/denied tool-call test through its controlled extension. Claude needs separate AskUserQuestion, allow-once, deny and canceled-request tests against **2.1.296**, including a result followed by background activity. Keep fixture evidence separate from authenticated live evidence and account-quota availability. No live provider validation was performed for this research.

### Claude minimal adapter: precise launch and completion constraints

Follow-up verification against installed **2.1.296** help and pinned SDK **v0.2.176**:

- `--tools Read,Glob,Grep,Edit,Write,Bash,AskUserQuestion` is the supported built-in availability syntax. The SDK joins its `tools` list into that flag. This is different from `--allowedTools`, which grants auto-approval. `--tools` does not establish control over configured MCP tools; add `--strict-mcp-config` with no configured servers, and validate the effective `system/init.tools` and `mcp_servers` fields. Some lifecycle tools may be implicit: current docs say `EndConversation` cannot be removed while other tools remain. [SDK command builder](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L592), [CLI reference](https://code.claude.com/docs/en/cli-reference).
- Installed help lists permission modes `acceptEdits`, `auto`, `bypassPermissions`, **`manual`**, `dontAsk`, `plan`. Use `--permission-mode manual` for this pinned CLI; do not pass the older literal `default` from SDK documentation. Manual mode still auto-approves some read-only calls. A `can_use_tool` check that rejects only `Bash.run_in_background` is not a complete control because auto-approved calls never reach that callback.
- Set `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in the child's environment. The official environment reference says it removes `run_in_background` from Bash/PowerShell/subagent tools and disables automatic backgrounding of subagents, timed-out shell commands and long MCP calls. **MCP tasks and Monitor remain exceptions.** Excluding those tools/MCP connections is therefore part of this minimal configuration. `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` additionally disables background sessions. These settings control Claude's background mechanisms, not arbitrary shell daemonization (`&`, `nohup`, subprocesses) and are not an OS sandbox. [Environment variable reference](https://code.claude.com/docs/en/env-vars).
- Do not add `--bare` solely for task containment: installed help confirms it changes authentication by skipping OAuth/keychain. If an isolated capability slice needs customizations disabled, `--safe-mode` preserves normal authentication but deliberately removes user/project customization. Keep this visible in the connection profile; managed policy can still apply. Do not silently change the user's normal configuration.

Keep `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` and parse the lifecycle even with the background switch. It detects deviations and avoids a premature success. The wire field is `state`, with **`running`**, **`requires_action`**, and **`idle`**, not `busy`:

```jsonl
{"type":"system","subtype":"session_state_changed","state":"running","uuid":"event-1","session_id":"session-uuid","sdk_host_only":true}
{"type":"system","subtype":"session_state_changed","state":"requires_action","uuid":"event-2","session_id":"session-uuid","sdk_host_only":true}
{"type":"system","subtype":"session_state_changed","state":"idle","uuid":"event-3","session_id":"session-uuid","sdk_host_only":true}
```

The exact shape is covered by the SDK's [session-state fixture](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/tests/test_query.py#L763). `sdk_host_only` is optional metadata, not a reason for the native host to ignore the event.

Task lifecycle records use these shapes; IDs below are illustrative:

```jsonl
{"type":"system","subtype":"task_started","task_id":"agent-1","task_type":"local_agent","description":"Review change","tool_use_id":"tool-1","uuid":"event-4","session_id":"session-uuid"}
{"type":"system","subtype":"task_updated","task_id":"agent-1","patch":{"status":"completed"},"uuid":"event-5","session_id":"session-uuid"}
{"type":"system","subtype":"task_notification","task_id":"agent-1","status":"completed","output_file":"/output/path","summary":"Review finished","uuid":"event-6","session_id":"session-uuid"}
```

The SDK tracks only `task_type` **`local_agent`** and **`local_workflow`** for deferred run completion. Remove IDs idempotently on `task_notification`, or `task_updated.patch.status` in **`completed`, `failed`, `stopped`, `killed`**. There is no required `task_completed` event. A terminal update may have no notification. The SDK deliberately does not reconcile this ledger with `background_tasks_changed`: that snapshot omits foreground agents which later become background and can contain observers without matching lifecycle records. It also excludes shell tasks from its wait-for-agent ledger because a server or `tail -f` might never complete. [Task schema](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L1543), [tracking implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/query.py#L870).

Implement completion as a state machine: remember each result, keep stdin open through `running` and `requires_action`, and settle only after a result plus `idle` with no tracked agents or unanswered controls. Idle can arrive before the result; evaluate after either. New work reopens the run. A result with an empty task ledger is insufficient because a completed agent may still owe its parent a follow-up turn. If the CLI supplies no state events, the SDK falls back to result+ledger; Mochlet should label that weaker compatibility and not promise full background support. A timeout must report interruption/uncertainty, not successful completion. [SDK result handling](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/query.py#L454), [state handling](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/_internal/query.py#L924).

### Claude session identity: handshake versus persisted session

The `initialize` **control response** is a capability/commands/output-style handshake, not a documented session-ID guarantee. Do not wait for `response.session_id` there before sending the first user message. The separate **`system` / `init`** event carries `session_id`, `cwd`, `tools`, `mcp_servers`, model and version at the start of each turn. The result also carries `session_id`, including an error result. Capture both and reject disagreement. [get_server_info](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/client.py#L540), [SystemInitData](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L1461), [session guide](https://code.claude.com/docs/en/agent-sdk/sessions#capture-the-session-id).

For a new Mochlet task, generate and journal a fresh UUID before launch, pass `--session-id=<uuid>`, then mark the binding confirmed only when the CLI reports that ID. Merely allocating a UUID is not proof of a saved session; an early crash may leave nothing resumable. Leave persistence enabled (omit `--no-session-persistence`). On later runs use only `--resume=<confirmed-uuid>`, not `--session-id` as an attempted resume and not `--continue`. Do not combine `--resume` with `--session-id` unless intentionally forking; the SDK explicitly documents that restriction. Resuming without forking preserves session identity and history; a missing session must surface an error rather than create unrelated work. [SDK session options](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.176/src/claude_agent_sdk/types.py#L2398), [session persistence/resume](https://code.claude.com/docs/en/agent-sdk/sessions).

Current CLI ID lookup can search other projects, so an exact UUID alone does not prove project-root agreement. Validate Mochlet's existing binding and canonical launch root before dispatch, then verify `system/init.cwd` and session ID as soon as received. That event is turn-start metadata, **not a verified pre-prompt routing handshake**. This research did not establish a supported no-inference preflight call that verifies the resumed cwd. If pre-dispatch effective-directory proof is mandatory, keep that acceptance gate open rather than claiming `initialize` provides it. No authenticated launch or persistence probe was run.
