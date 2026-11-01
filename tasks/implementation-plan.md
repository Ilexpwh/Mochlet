# Mochlet implementation sequence

This is the approved execution map. Preserve T01–T33, R01–R03, K01–K06, G01–G07, Q01–Q05 and U01–U07 in todo.md. Completion requires recorded evidence, not the presence of a stub. `docs/build-status.md` is the running evidence ledger.

| Stage | Delivery | Gate |
|---|---|---|
| A | Technical specification, original visual system, compatibility record | Contracts and original states documented; actual toolchain identified |
| B | Native app, menu bar/notch/workspace, customization | Reproducible build, native launch and keyboard/fallback checks |
| C | SQLite projects/tasks, exact Codex sessions, human input, usage, recovery | Focused fixtures and authorized real read-only round trip |
| D | OpenRouter model profiles, push-to-talk, spoken replies, scoped knowledge | Provider contract fixtures; live speech/language evaluation remains separate |
| E | Explicit microphone/system meeting capture, periodic/final transcripts, retention | Capture/lifecycle/recovery evidence and diarization evaluation |
| F | File ingestion/operations, GitHub issues/workspaces/PR review | Existing T14–T21 and G01–G07 criteria |
| G | Claude/Pi, external observation, Slack/Lark/Linear/Google | Existing provider and connector criteria |
| H | Accessibility, performance, signing and distribution | Measured native release gates; no false notarization claim |

## Additional task IDs

- [ ] U08: Drag the companion to top/left/right edges, expand inward and restore its position. Geometry fixtures and native setting/relaunch checks pass; physical drag, multi-display, full-screen and interrupted-drag walkthroughs remain required.
- [ ] V01: Implement Keychain-backed API profiles and capability-aware OpenRouter STT discovery. Verify denied credentials and unsupported modalities.
- [ ] V02: Record a command and return editable text through the selected STT profile. Verify cancellation, silence, failures and no duplicate task.
- [ ] V03: Add optional system spoken replies, voice selection and suppression during meetings. Verify explicit playback/stop and missing voices.
- [ ] V04: Evaluate English, Cantonese, Mandarin and code-switching on consented samples; record transcription and technical-name errors.
- [ ] M01: Capture explicit microphone-only meetings with visible state and device/permission failure handling.
- [ ] M02: Add selected application/system audio with timestamped tracks; verify browser scope, echo and device changes.
- [ ] M03: Encrypt recoverable segments, implement pause/stop/lock/sleep policy and seven-day retention/keep/delete controls.
- [ ] M04: Produce bounded provisional transcription jobs with persisted identity, source offsets, backpressure and visible failed gaps.
- [ ] M05: Finalize speaker-attributed transcript revisions, preserve corrections and keep cross-part speaker identities uncertain until reviewed.
- [ ] M06: Generate source-linked meeting notes and proposed project tasks; never dispatch from recording alone.
- [ ] M07: Test long meetings, API loss, disk failure, restart recovery, retention and native workload quality.

Dependencies: V01 precedes V02; V02 precedes V04. M01 precedes M02/M03; V01 and M03 precede M04; M04 precedes M05; M05 and scoped knowledge precede M06; M02–M06 precede M07. V03 depends on the native shell and coordinates with M01. These are planned tasks until their complete acceptance evidence is recorded.

## Working discipline

Implement a usable slice, run focused checks and native build, then commit. Keep incomplete integrations out of normal user flows. Document unavailable external credentials or hardware separately from implementation defects. Do not mark performance or language quality passed from mocks.

## Native reference decision — 2026-11-01

The user requested close Coucou UI/UX and motion parity and authorized reuse of its design code. Adapt its MIT-licensed island geometry, fixed panel hosting and motion timings; retain attribution. Keep Mochlet's simple pastel character original. Track remaining detach/corner/drop/greeting/global-shortcut parity in [coucou-adaptation.md](../docs/coucou-adaptation.md); this does not mark the complete B/F release gates passed.


## Stage G provider progress — 2026-11-01

Codex, Claude Code and Pi now have separate transports behind AgentRuntime. Pi's native/process fixture workflows and real no-inference guard preflight pass; live authenticated execution remains a separate gate. [Pi evidence](../docs/pi-compatibility.md) records exact compatibility. Google account/source readers and native task/memory capture are now implemented with fixture and setup evidence; live Google and outbound/sync gates remain open. Slack/Lark/Feishu/Linear now support verified token connections and selected source capture; live access, automatic renewal and outbound writes remain open. Stored Codex history browsing and explicit exact-session import are implemented; external-client liveness and control remain open. See [session contract](../docs/codex-sessions.md). Existing unchecked release criteria are retained.

### GitHub publication evidence

G06 now has committed-workspace review, explicit push/draft-PR publication, immutable commit identities and crash reconciliation. G07 has read-only PR lifecycle refresh independent of local task state. [Publication contract](../docs/github-publication.md) records fixture/native evidence and remaining live/Projects/write-back limitations. The full milestone remains open.

Calendar incremental synchronization now has transactional per-account/calendar cursors, bounded rebuilds, cancellation-exception retention and offline native browsing. [Contract and evidence](../docs/google-calendar-sync.md). U07 remains open for Gmail history synchronization and live revocation/recovery evidence.

Gmail history synchronization now refreshes an explicit tracked set with complete-page transactions, bounded rebuilds and offline native browsing. [Contract and evidence](../docs/gmail-sync.md). U07 remains open for live account/revocation checks, backoff and broader sleep/network validation. No unchecked acceptance criteria have been removed.
