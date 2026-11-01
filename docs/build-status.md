# Build status

Implementation started 2026-11-01. This document is the evidence ledger; unchecked roadmap tasks remain open until all their criteria pass.

## Environment

- Apple Silicon, macOS 27.0 on the development Mac.
- Xcode 27.2 at `/Applications/Xcode.app`; use per-command `DEVELOPER_DIR`.
- Swift 6.4; deployment target macOS 15.
- Codex CLI 0.155.1 at `/opt/homebrew/bin/codex`.
- No user API credentials are copied into the repository.

## Evidence

- A: Technical specification and implementation sequence written. Visual system and native implementation in progress.

## Outstanding release evidence

macOS 15 hardware/OS validation, multilingual speech evaluation, authenticated STT/diarization samples, live meeting-app matrix, accessibility review, resource measurements, two-hour soak and distribution signing/notarization remain required.

## Native and Codex development slice — 2026-11-01

Implemented:

- SwiftUI/AppKit app, workspace, menu-bar access and native vector companion with four pastel palettes.
- Coucou MIT island shape, fixed transparent panel hosting, opening spring and closing timing curve. Hidden/compact/expanded interaction policy; optional hover-open, pinning, Escape fold and idle dismissal. Drafts/pending requests prevent automatic dismissal. Pointer events maintain click-through outside the island; no idle polling timer.
- Chat/Tasks/Attention tabs backed by local state, project-folder registration and SQLite task/run persistence. Closing UI does not stop the runtime.
- Codex app-server initialization, start/resume with cwd verification, streamed replies, request-ID-based approvals/questions, cancellation and supported account-limit reads. One active run, in-memory queue with queued task records. Relaunch marks active work interrupted; automatic queue restoration is not implemented.
- A core Markdown knowledge vault and scoped SQLite FTS index with revision hashes, external-edit refresh and deletion tests. Knowledge UI, context injection, complete OKF interoperability and memory revision history are not yet implemented.

Verification:

- `./scripts/check.sh`: native Apple Silicon Debug build succeeds. Seven fixture tests pass; the opt-in live test is skipped by the ordinary command.
- An explicit `MOCHLET_LIVE_CODEX=1` read-only Codex smoke test passed against CLI 0.155.1: initialized, created a thread, received `MOCHLET_OK`, and resumed its exact thread with matching cwd. No live approval/denial or project-edit walkthrough has yet been claimed.
- Native UI walkthrough: workspace launch, simplified character, notch opening, Chat/Tasks/Attention tabs, pin/unpin, keyboard Escape, and draft preserved across collapse/reopen. Saved [native screenshot](evidence/native-notch.png).
- The walkthrough caught a window-constraint crash and missing redraws in an initial resizing-panel approach. Replaced it with Coucou's fixed host and disabled automatic hosting size constraints; repeated the triggering draft/fold/reopen/pin sequence successfully.
- Coucou's MIT notice is retained in `LICENSES/` and copied into app resources. Character and sound assets from Coucou are not bundled.
- Build emits a local iOS Simulator version mismatch warning; this macOS build succeeds and does not use iOS Simulator.

Still pending: full-screen/multiple-display hardware walkthrough, VoiceOver user testing, reduced-motion system-setting walkthrough, actual CPU/latency/soak measurements, global shortcut registration, detach/corner/drop/greeting parity, voice/meeting/provider/connector slices and release signing. A passing native walkthrough does not complete those release gates.

## Edge docking — 2026-11-01

- Implemented compact/header dragging, nearest top/left/right edge selection, inward expansion, screen-coordinate clamping and saved display/edge/position. Appearance offers edge selection and centering without dragging.
- Core geometry tests pass for all three edges, clamping, negative display origins and invalid saved fractions. `./scripts/check.sh` succeeds with 10 fixture tests passed and one opt-in live Codex test skipped.
- Native walkthrough verified the Left preference survives relaunch, changed placement to Right through Appearance, and inspected inward-expanded left/right layouts, including pinning. The UI automation service cannot complete coordinate drags on the borderless companion panel (`noWindowsAvailable`); physical drag, multi-display and full-screen walkthroughs remain pending. This is not recorded as a passed end-to-end drag test.

## Provider foundation and component research — 2026-11-01

- Added a separate `ModelService` contract, OpenRouter catalog/transcription/text transport and Keychain credential actor. Transcription supports text-only responses and request-scoped speaker labels. No automatic provider fallback is requested. These are core components, not a completed voice UI.
- Provider fixtures cover authentication failure, empty input, multilingual text responses and request-scoped diarization. No live API credential, paid inference, microphone recording or language-quality evaluation was used. Native profiles, capture and playback remain pending.
- [Component research](component-research.md) evaluates native shortcuts, local speech alternatives, canonical OKF, GitHub transport, Google authorization, provider adapters and update delivery. It records current upstream licenses and adoption gates; no researched dependency has been added merely because it appears in the report.

## Native voice workflow — 2026-11-01

- Added Speech & Models with Keychain key entry/removal, live transcription catalog, separate analysis model and installed macOS voice selection. Added microphone/stop/transcribe/cancel controls to both composers; transcripts append to an editable draft and never dispatch automatically.
- Captures at 16 kHz mono PCM, caps command recording at two minutes, checks catalog audio capability before microphone authorization, deletes temporary command audio after processing/cancellation, and cancels on lock/sleep/quit. Active voice work holds the island open and blocks accidental text submission. Optional spoken completion replies stay silent during capture; manual preview/stop is available.
- Native build and core fixtures pass. Native walkthrough verified the missing-key recording gate, settings controls and a successful live public catalog refresh returning Nemotron 3.5 Transcribe. No microphone recording or authenticated transcription was performed; live audio, language accuracy, device loss and permission walkthroughs remain pending. This slice currently uses explicit click-start/click-stop; hold-to-talk shortcut work remains open.
- [Coucou porting research](coucou-porting-research.md) records exact reusable sources and adaptations, verified against pinned upstream revision b6a85f2.
