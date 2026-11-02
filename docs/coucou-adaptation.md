# Coucou interaction adaptation

Requested by the user on 2026-11-01: make Mochlet's notch UI, UX and motion closely follow Coucou; reuse suitable design code. Use a simpler, flat, cute character inspired by the minimal Grok Bot direction.

## Reused and adapted now

- `App/IslandShape.swift` is adapted from Coucou's `NotchBuddy/Sources/App/IslandRootView.swift`. The animatable geometry retains its top-edge attachment, compact concave ears and rounded bottom corners.
- Expansion uses Coucou's spring: response 0.5 seconds, damping 0.72. Collapse uses its cubic timing curve (0.45, 0, 0.2, 1), duration 0.34 seconds.
- Interaction follows `IslandStateMachine.swift`: hidden → compact on hover; click → expanded; optional hover-open; 0.6-second hover-leave grace, 15-second expanded inactivity, 60-second compact inactivity. Editing, pending inputs and pinning prevent automatic collapse. Escape folds explicitly without cancelling work or deleting the draft.
- The expanded island uses Coucou's 640-point width, black surface, compact header pills and inline attention flow. Mochlet uses a taller content region for project routing, task output and keyboard-accessible request forms. The camera region remains free of controls.
- Coucou’s fixed transparent panel hosts the animated island. Pointer events update click-through outside the visible island without an idle polling loop. Hosting size constraints are disabled; the island alone animates. Screen changes recompute geometry.

## Mochlet-specific

The companion is an original flat pastel pebble with two capsule eyes. No Coucou character art, outfits, names or audio files were copied. Native vectors support palette changes, blinking, gaze, working/chewing squashes and attention poses. Reduce Motion disables recurring character movement and surface springs.

Chat, Tasks and Attention use actual Mochlet state. Meeting/connector buttons are not exposed as functioning features before implementation. A task continues when the island folds or the workspace closes.

## Further parity work

Desktop detach/reattach, corner placement, greeting choreography, richer touch responses and audio cues remain planned. Global shortcuts, file feeding, meeting states and display selection were added after the initial adaptation; their evidence and remaining native checks are recorded below and in the build ledger.

## Attribution

Coucou code: Copyright (c) 2026 Louis Raillé, MIT. Full notice: [Coucou MIT license](../LICENSES/Coucou-MIT.txt). Reference repository: https://github.com/Louis-CFM/coucou. The Mochi character, Coucou branding and sound assets are separate from the code license and are not redistributed here.

Grok Bot visual direction reference: https://x.ai/news/designing-grok-bot. No Grok Bot assets are bundled.

## File feeding ports — 2026-11-01

`App/FileDropView.swift` adapts `FileDropNSView` from Coucou revision `b6a85f29719b5291651c092e33b3f9d4004d091e`. It preserves the AppKit drag-destination / click-through arrangement and adds actual-island hit acceptance. `AttachmentChips` adapts `ContextChip` layout from `IslandViewContent.swift`. Mochlet uses semantic colors, accessible removal and actual extraction completion. Coucou's fixed-duration simulated upload handler is not copied. Both adaptations retain the MIT attribution in source and bundled notices.

## Meeting audio ports — 2026-11-01

`Resampler16k` and the microphone tap in `App/MeetingCapture.swift` adapt Coucou's `ParakeetEngine.swift` and `NoteAudio.swift` at b6a85f2. They retain MIT attribution. Mochlet adds conversion error propagation, timestamped bounded buffering and device-change handling. System audio uses ScreenCaptureKit with explicit application/all-system selection, following Apple's capture APIs; Coucou's global Core Audio tap and plaintext recording storage are not copied.

Display selection and interrupted-drag recovery now complement top/left/right docking. [Docking contract and evidence](docking.md) distinguishes native settings checks from pending physical drag and multiple-display hardware checks.

`App/UsageCard.swift` adapts `GaugeRowView` from `ClaudePlanCardView.swift`, using semantic colors and stale-state handling instead of assuming a past reset implies zero usage. `App/HotKeyCenter.swift` adapts Carbon registration from Coucou's `HotKeyCenter.swift`, adds key-release handling and repeat suppression for push-to-talk, and retains the source/bundled MIT notice.
