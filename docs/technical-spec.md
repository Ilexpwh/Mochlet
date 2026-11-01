# Mochlet technical specification

Approved baseline: 2026-11-01. Product: personal first, Apple Silicon, macOS 15+, Swift 6, SwiftUI/AppKit. Full Xcode is selected per build command. This specification describes the target; `docs/build-status.md` records verified implementation.

## Ownership and interfaces

The app owns native windows, observation, microphone/system permissions, Keychain and rendering. SlimeCore owns value models, SQLite persistence, project resolution, protocol framing, source retrieval and provider HTTP contracts. Long-lived controllers outlive views. UI work is MainActor-isolated; I/O and database operations execute asynchronously.

`AgentRuntime` owns initialize/start/resume/turn/answer/cancel/events/usage. `ModelService` owns model discovery and recorded-audio transcription. Neither protocol implies that all adapters support every operation. Capability errors are visible and never trigger silent provider substitution.

Projects have stable IDs, canonical roots and aliases. Tasks belong to projects; runs are attempts; session bindings hold provider thread identity and effective cwd. The selected UI project cannot retarget an active run. Exact aliases resolve deterministically; conflicting or ambiguous destinations block dispatch. A file attachment is input, not a destination. Session resume verifies cwd before sending a turn.

One coding run is active at a time; persisted queued tasks retain their original destination. App-server JSON-RPC uses bounded newline frames over stdio, explicit executable/argument arrays and separate stderr. Request IDs correlate replies and human input. Unknown events are tolerated; malformed/oversized frames terminate the connection. Loss of transport makes active work interrupted, never silently retried. Record significant events before reflecting success in UI. Pending requests expire on turn/session termination.

Codex baseline is CLI 0.155.1. Use installed schema generation as compatibility evidence; do not conflate exec-server and app-server protocols. Query actual model and account capabilities. Rate limits have source, measurement time and unknown/stale states. No credentials or full environment dumps appear in diagnostics.

## Storage

GRDB 7.11.1 manages versioned SQLite migrations. Application data lives under `~/Library/Application Support/Mochlet/`; data never defaults into the current code repository. Tables separate projects, tasks, runs, events, settings, knowledge and meetings. Journal and domain changes share transactions where required. Restarts mark formerly active work interrupted. Schema changes are additive; failed migrations preserve the original database and report an error.

Keychain stores provider keys and the audio encryption key. Knowledge uses Markdown with OKF-compatible frontmatter and a derived full-text index. Sources retain scope, source reference, revision/hash and ingestion time. Personal material joins a project only through an explicit grant. Deletion removes documents and derived retrieval records. Generated summaries do not become verified memory automatically.

## Native surfaces and state

A fixed transparent NSPanel hosts a compact companion and animated black island attached to the screen edge, adapting Coucou’s licensed island shape and transition timings. Pointer events update click-through outside the visible island. Expanded controls clear the camera area. Camera geometry comes from NSScreen, never a fixed notch width. A status item and normal resizable workspace remain usable on displays without a notch. Background events do not steal focus. Escape closes the panel, and explicitly cancels any active command recording. Context menus expose workspace, preferences and quit.

SwiftUI vector paths form the original flat pastel pebble body with two capsule eyes; expressive elements share its transform. See coucou-adaptation.md for exact reused code, timings and pending parity work. Motion responds to actual recording, intake, attention and execution state. Reduced motion uses static poses. Text labels accompany state. Hide unnecessary animation when occluded. Existing native-quality.md defines measurement targets; these are not assumed results.

## Speech and meeting pipeline

The user selects an OpenRouter API key and model profiles. Discover STT models through `/api/v1/models?output_modalities=transcription`. Recorded audio uses `/api/v1/audio/transcriptions`, with inline bytes and model-specific capabilities; `diarize` requires supported verbose output. Default meeting profile is `nvidia/nemotron-3.5-transcribe`. A successful authenticated sample must establish endpoint support; catalog presence alone is insufficient. No mandatory local 30B model or CUDA runtime.

Push-to-talk yields an editable transcript; text submission and microphone submission share routing. macOS speech synthesis is optional and suppressed during meeting capture. English, Cantonese and Mandarin are evaluation targets, not unmeasured quality promises.

Meeting mode is explicitly started/stopped/paused. AVFoundation captures microphone samples. ScreenCaptureKit captures selected application/system audio without storing video. Preserve separate timestamped tracks before resampling/mixing derivatives; disclose browser-wide capture. On lock or sleep, pause and require explicit resume. Device loss and denied permissions are visible, not silent empty recordings.

Produce provisional transcript parts approximately every 30 seconds, subject to API latency. Final recorded-audio processing produces speaker attribution and replaces provisional revisions. Speaker IDs are request-local; never merge identities solely because numbers match. Longer recordings split at verified duration/byte boundaries. Audio processing preserves source offsets and flags gaps. User edits and speaker names survive revision replacement through explicit reconciliation.

Encrypt audio at rest using CryptoKit AES-GCM and a Keychain key. Default expiry is seven days from recording, including failed jobs; offer explicit keep/delete controls. Transcripts/notes persist until removed. A retention sweep runs at startup and periodically while open. API failures retain recoverable segments until expiry and never resend an uncertain paid job indefinitely.

Meeting summary claims cite transcript segments. Action items become proposals; no automatic agent launch, message send or memory promotion from recorded speech.

## Connectors and files

Follow the existing GitHub and Google designs. Metadata sync, source checkout, file operations and knowledge refresh are separate. Authentication scope is distinct from per-project authorization. Remote content cannot authorize tools. Outbound writes use an action ledger and reconcile uncertain outcomes. File organization validates a concrete preview against current path/hash/collision preconditions; it does not contain arbitrary CLI writes.

## Verification

Core fixtures cover routing, durable state, framing, question identity, recovery, retrieval scope and provider failures. Native checks cover focus, screen changes, recording permissions, accessibility and motion. Live CLI/API checks require available credentials and selected non-sensitive fixtures. A runnable development app is not a notarized public release. See implementation-plan.md and build-status.md for measured evidence.
