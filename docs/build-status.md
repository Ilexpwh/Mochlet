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

## Native knowledge and memory — 2026-11-01

- Added personal/project memory editor, provenance, local scoped search, file reveal, explicit forgetting and source-linked API answers. Inference requires an explicitly configured text-capable model and key. Empty retrieval makes no inference request. Responses with invented source IDs or unsupported certainty fail validation; authoritative revisions are checked again after inference.
- Added opt-in project/personal memory context to coding submissions, visible in workspace and notch. Correcting an existing note checks its revision and saves the previous Markdown under `revisions/`; forgetting removes both note and local revision copies. Previously submitted agent context is not retroactively erased.
- Core fixtures now include invalid citations, uncertainty, correction conflicts and forgetting history. Twelve fixture tests pass; the live Codex test remains opt-in. Native build passes.
- Native walkthrough in an isolated Debug data directory created a fixture memory and retrieved it with a Cantonese query. [Screenshot](evidence/native-memory.png). `MOCHLET_DATA_DIR` is Debug-only and allows repeatable native walkthroughs without changing the personal database.
- Complete OKF v0.2 import/export, unknown-frontmatter preservation, rich source extraction, knowledge-quality evaluation and authenticated model-answer walkthroughs remain open. Citation-ID validation is not proof that every generated claim is supported.

## File feeding — 2026-11-01

- Ported Coucou's native drop destination and attachment chip layout. Added multi-file/folder extraction for UTF-8 text, PDF text and image OCR, with source hashes, page/line labels, explicit limits and visible partial failures. Hidden folder entries, symbolic links and common build/vendor trees are skipped. Chewing tracks actual extraction activity.
- Added file selection, preview, attachment removal, optional cited summaries, explicit save-to-memory and selected file context on coding submissions. Input stays local until an explicit summary or coding request. Current attachments are session-local; selected extracted content can be retained as memory. Full visual reasoning, rich document formats and reviewed file moves remain open.
- Thirteen core fixture tests pass, one live Codex test is skipped, and native build passes. Native walkthrough imported a synthetic Markdown file through the file picker, verified its notch/workspace receipt and ready state, and saved it to isolated test memory. [Screenshot](evidence/native-files.png). Native drag/drop and image/PDF quality matrix remain pending.

## Meeting companion implementation — 2026-11-01

- Added explicit microphone / microphone-plus-application / microphone-plus-system capture, separate source tracks, metering, persistent recording indicator, pause/resume/stop and lock/sleep handling. ScreenCaptureKit registers only audio output; no screen video is saved. Audio conversion/assembly and encrypted storage run outside UI work.
- Added AES-GCM audio segments bound to meeting/segment IDs, a Keychain audio key, SQLite meeting state/event journal, recovery, seven-day per-segment expiry, orphan cleanup, keep recording and explicit deletion. Up to the current unflushed 30-second buffer can be lost on a crash; saved segments remain recoverable.
- Added sequential provisional transcription, final five-minute-part processing, atomic versioned replacement, request-local speaker identities, rename/merge display labels, source-linked notes and explicit draft/memory proposals. Final failure retains previous/provisional text. Reprocessing never silently changes model and may incur another API charge. Notes cover bounded source excerpts and disclose truncation.
- Eighteen fixture tests pass (one live Codex test skipped); native build succeeds. Fixtures cover encrypted recovery/expiry, kept and orphan audio, offset mixing, bounded parts and transaction rollback preserving transcript/speaker state.
- Native walkthrough verified the meeting workspace, explicit Start control and microphone/system/application source choices without starting recording. [Screenshot](evidence/native-meetings.png). Live microphone/system capture, permissions, device changes, authenticated provisional/final diarization, long meetings, speaker quality, retention under clock changes, disk exhaustion and sleep matrix remain unverified. Do not treat the meeting release gate as passed from these fixtures.

## GitHub issues and task workspaces — 2026-11-01

- Added native GitHub project bindings using the installed `gh` authentication, account/repository numeric identity checks, explicit origin matching, bounded paginated issue synchronization and atomic snapshot replacement. Pull requests are filtered out of issue results. Account changes, redirects, partial requests and oversized repositories fail without replacing prior data.
- Preparing an open issue refreshes it, reuses its existing task, and creates an isolated Git worktree from the registered project's committed HEAD. Workspace intent is persisted before creation, then repository/common-directory identity is verified before dispatch. Exact Codex resume uses the saved workspace directory. Primary uncommitted changes are preserved. Local review includes tracked diff against the saved base and an untracked-file status list.
- Twenty-two fixture tests pass, one live Codex test is skipped, and native build succeeds. Added tests for argument isolation/timeouts, account changes, paging/partial failures, idempotent task links, worktree isolation and routing rejection. Native walkthrough successfully bound `Ilexpwh/Mochlet` with the existing GitHub CLI account and synchronized its empty issue list. [Screenshot](evidence/native-github.png). No remote issue or PR was created for testing.
- Live issue-to-Codex editing, repository clone/fetch UI, large-repository incremental sync, PR publishing/reconciliation and task-worktree cleanup remain open. Sync currently supports github.com and at most 2,000 API issue/PR entries per complete snapshot; it does not claim a transactionally consistent server snapshot while remote issues are changing.

## Recovery, usage and keyboard polish — 2026-11-01

- Queued prompts/context/read-only policy are now saved transactionally with tasks. Starting a run atomically removes its queue entry; restart offers an explicit Resume queue control and never replays a started/interrupted run. Legacy queued tasks without a saved prompt become interrupted. Cancellation preserves task history.
- Adapted Coucou's capsule usage gauges and Carbon shortcut registration. Codex allowance windows now show consumed percentage and reset time; absent windows remain unavailable and old/expired snapshots are visibly stale. Connect/read limits does not start coding. Native walkthrough successfully read and displayed the live account's supported weekly window. Dark-mode accent contrast was corrected.
- Added global ⌃⌥Space open/fold and ⌃⌥V hold-to-talk with release handling, repeat suppression, lock/sleep cleanup and visible registration conflicts. Native settings show successful registration. Automated app-targeted key events did not produce a visible global action; physical global shortcut and audio release tests remain pending, not passed.
- Twenty-four fixture tests pass (one live Codex test skipped); the native build passes. New fixtures cover persisted queue ordering/context, duplicate rejection, no replay after run start and stale/missing usage windows.

## Reviewed file organization and independent review — 2026-11-01

- Added selected-file move previews, no-overwrite atomic moves, durable operation history, paginated older operations and unchanged-file undo. Conflicts, changed source content, symlink files and cross-volume moves fail visibly. Per-file journal reconciliation handles interruption between rename and metadata commit. AI-generated organization proposals, directory moves and cross-volume copy workflows remain open.
- Native walkthrough moved a disposable text file into a chosen folder through the review sheet and restored it using Undo. The walkthrough found an attachment-path alias issue; moved attachments now compare standardized file URLs. Picker dismissal also restores the presenting window. No personal files were moved.
- Independent read-only review found and prompted fixes for queue-cancellation races, repository/account rebind recovery, lock/sleep during recording startup, finalization skipping saved source tracks, orphan audio surviving explicit deletion, and hidden older Undo controls. Finalization now assembles original source tracks; mixes are derivative provisional inputs. Explicit audio deletion removes the entire validated session audio directory, including fresh orphan ciphertext, regardless of keep status.
- Twenty-nine fixture tests pass (one live Codex test skipped); native build succeeds. New regression cases cover cancelled queue claims, separate account-bound issue tasks, repository rename metadata, orphan deletion, source-only audio recovery and paginated move undo. Capture startup cancellation and lock/sleep were inspected in review; live timing/device tests remain required.

## Portable memory and idle measurement — 2026-11-01

- Added native import/export of individual OKF-style Markdown documents. Imports get fresh local IDs and an explicit selected scope. Editing preserves unknown frontmatter, including nested metadata. This bounded scalar parser is not a full YAML implementation or an OKF bundle/index/log importer.
- Thirty fixture tests pass (one live Codex test skipped); native build succeeds. Portable-note fixtures cover unknown metadata preservation, explicit scope isolation, stale revision detection and non-overwriting export. Native import/export walkthrough passed with a disposable Markdown note; its unknown nested metadata remained in the exported file. Memory action buttons were changed to individually exposed controls after the walkthrough found grouped accessibility rows. Picker dismissal returned to the workspace.
- A 60.01-second Apple Silicon Debug sample with the workspace closed and no active agent/audio consumed 0.43 CPU seconds: **0.72% of one core**. RSS stayed at 125.4 MiB. This meets the idle target for this sample only; latency, stalls and the two-hour mixed-workload soak remain unverified. [Measurement](evidence/idle-sample.json).

## Claude runtime and native orchestration regression — 2026-11-01

- Added the shared AgentRuntime boundary and a separately selected Claude Code adapter pinned to installed CLI 2.1.296 and SDK v0.2.176 envelopes. Tasks persist provider, canonical session directory and confirmation state. Changing the default provider cannot reassign an existing session. Unsupported versions fail visibly.
- Claude supports message activity, exact session resume, allow-once/deny, concurrent request IDs, expired controls, multi-select/free-text questions, interruption and reported API cost. Manual CLI permissions apply. Supported tools are explicitly limited; MCP and Claude background mechanisms are disabled. Result completion waits for idle; unexpected background tasks interrupt rather than pretending completion. This is not an OS sandbox and shell-created daemons remain outside that containment.
- New sessions allocate a UUID before submission and confirm it from system/init. Resumes require Mochlet's confirmed stored provider/directory binding. Claude's effective directory arrives only after prompt dispatch; no supported pre-inference verification handshake has been established. This limitation keeps the stricter routing release gate open.
- Thirty-five core fixture tests pass; two opt-in live tests are skipped by the ordinary suite. A separate live Claude read-only test passed both creation and exact resume. The native app repeated creation/resume successfully in an isolated Debug data directory. [Native evidence](evidence/native-claude.png). No tool action was approved during these live checks; real approval/denial, cancellation and question walkthroughs remain pending.
- Added a Debug-only native runtime test host to scripts/check.sh. It runs the real AppModel against disposable CLI fixtures and verifies cancelled startup sends no prompt, disconnect preserves a paused successor, and explicit Resume completes it. Independent review prompted these regressions plus completion-after-expired-control and multi-select tests.
- Pi and the Slack/Lark/Linear/Google connectors remain unimplemented. Their protocol/license research is recorded in the component reports; they are not shown as working connections.


## Pi runtime and composer correction — 2026-11-01

- Added Pi 1.4.0 as an explicitly selected native provider. Its dedicated transport verifies version, exact session/file/cwd and effective tools before user-prompt dispatch. Saved session headers are checked before resume. An original bundled extension supplies fail-closed approval for non-read tools; custom extensions/MCP/skills/slash commands are disabled. No CLI runtime or credentials are bundled.
- Added confirm/select/input/editor translation with matching IDs and expiration, authoritative output replacement, settlement-aware completion, clear-queue-before-abort, recovered draft journaling and separately labeled cumulative session usage. Missing statistics do not discard a completed turn. Weekly/subscription limits are unavailable.
- **41 core fixture tests pass** (two are parameterized across six process cases); three opt-in live tests are skipped in the ordinary suite. Native build and AppModel regression host pass, including Pi creation/resume, decline, selection, output replacement and usage isolation. Fifteen direct guard assertions pass. Real Pi 1.4.0 passes the isolated, no-inference preflight through the Swift runtime.
- Native UI walkthrough passed create/resume, decline and multiple-choice input using the deterministic Pi process fixture. It caught a stale focused field editor after Command-Return; submission now ends editing before clearing the draft and restores focus. Keyboard and mouse submission both pass. [Native approval evidence](evidence/native-pi-approval.png).
- Independent review found no actionable issues in the Pi adapter or composer correction. Live authenticated Pi generation, actual tool approval/execution and provider cancellation remain unverified. [Compatibility report](pi-compatibility.md) includes sources and reproduction commands. T24 and the broader release gates remain open; Slack/Lark/Linear/Google and PR publishing are still unfinished.

## Google read workflow — 2026-11-01

- Added pinned AppAuth 3.0.0 desktop OAuth/refresh, Keychain state, actual scopes and project grants; account-isolated bounded Gmail, Calendar/free-busy and Drive readers; explicit native task drafts, memory copies and source-linked summaries. HTTP reads reject redirects and oversized content.
- `scripts/check.sh` passes: 47 fixture test declarations (two parameterized over six cases), three opt-in live tests skipped, native Debug build and AppModel process-fixture host. New native routing checks reject destination changes/new conversation/active-task forks, preserve concurrently edited drafts and cancel source installation.
- Review findings were corrected before shipping: source provenance now remains structured through Send; delayed retrieval cannot overwrite a newer composer; cancellation is checked immediately before installing a draft. Remote source access is verified before dispatch.
- Native walkthrough checked the Google workspace, scope labels, disabled empty-client sign-in and invalid-client rejection. [Setup screenshot](evidence/native-google-setup.png). No real Google account or OAuth client was supplied; live consent, refresh, source reads and analysis quality are unverified.
- Detailed export bounds and unimplemented outbound/incremental-sync gates are in [Google integration](google-integration.md). Existing U01–U07 acceptance checkboxes remain open. AppAuth's Apache-2.0 license is included in source and app resources.

## Google reviewed delivery — 2026-11-01

- Added exact Gmail send/remote-draft previews, calendar create/update/occurrence cancellation, explicit guest notification choices and persisted remote receipts. Separate write scopes are opt-in. Existing calendar writes preserve private metadata and use ETag preconditions; inserts have stable client IDs and availability checks.
- Durable delivery claims enter `uncertain` before transport. Atomic conflict checks block duplicate unresolved intents, including two previews prepared before the first attempt and recreated calendar previews. Pre-I/O cancellation is recorded as a known rejection. Reconciliation reads remote evidence and never repeats the write.
- Review found and fixed both duplicate-intent bypasses and the pre-I/O cancellation recovery trap. Four regression tests were added. `scripts/check.sh` passes 51 fixture test declarations, three live tests skipped, native Debug build and AppModel fixture host.
- Native scope UI defaults all writes off; [evidence](evidence/native-google-write-permissions.png). Connected preview and real delivery remain unverified without configured OAuth/test recipients. No live external message or calendar mutation was made. See [Google limits](google-integration.md).

## Team source capture — 2026-11-01

- Added Keychain token connections with verified workspace/user identity for Slack, Lark/Feishu and Linear. Selected threads/issues use bounded pagination, explicit project bindings, idempotent task capture and fresh access verification before dispatch. Linked files and unrelated conversations are not retrieved. Expired credentials require explicit replacement.
- `scripts/check.sh` passes 55 fixture test declarations, three opt-in live tests skipped, native Debug build and AppModel process fixtures. Four new tests cover identity changes, incomplete/looping pages, moved collections and disconnected task sources. Independent review found no Required/Critical issues.
- Native setup walkthrough verified provider selection, token guidance and disabled empty-token submission. [Evidence](evidence/native-team-connections.png). No real team token was supplied; live access and connected task capture remain unverified. Details and official references: [Team connectors](team-connectors.md).

## Reviewed GitHub publication — 2026-11-01

- Added native committed-workspace PR review with exact head/base commits, task/issue source, editable description and validation evidence. Explicit publication uses a create-only branch lease and creates a draft PR. A captured GitHub CLI credential is shared by redirect-rejecting API requests and an isolated temporary bare Git transport; project SSH keys, helpers and URL rewrites cannot silently change the publishing account.
- Durable publication states reconcile lost create responses without another POST, recover branch-only interruption, and permit a fresh review when the target advances before PR creation. A PR creation with no visible receipt stays uncertain. Remote PR state refresh does not change local task state.
- GitHub issue drafts now carry structured source/project/task provenance. Queued/active issue snapshots cannot be replaced; dispatch rechecks the current issue and stops changed-source work before connecting an agent.
- `scripts/check.sh` passes 62 fixture declarations (two parameterized across six cases), three opt-in live tests skipped, native Debug build and AppModel fixture host. Seven publication tests include actual object transfer to a disposable bare Git repository and refusal to overwrite a raced branch. Review findings on account pinning, preflight recovery, advanced-base recovery and queued snapshot mutation were fixed and re-reviewed.
- Native walkthrough registered this source project, verified `Ilexpwh/Mochlet` against the existing CLI account, and inspected the PR setup sheet with empty submission disabled. [Evidence](evidence/native-pr-review-setup.png). No live branch/PR was created for testing; a populated native diff preview and live GitHub publication remain unverified. [Contract and limits](github-publication.md).

## Stored Codex session browser — 2026-11-01

- Added exact-project, bounded read-only session listing/history and optional ten-second refresh. Explicit import rechecks metadata and creates/reuses an interrupted task without dispatch. External client liveness is explicitly unknown; its approvals stay in that client.
- Full checks pass: 65 fixture declarations, three live tests skipped, native build and AppModel host. Independent review found no Required/Critical issues. Real read-only protocol list/read/history probes pass; native empty-list refresh displays count/freshness. No external session was resumed during validation.
- [Contract and evidence](codex-sessions.md). Populated native import and external-client overlap remain unverified.
