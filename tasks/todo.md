# Implementation checklist: Mochlet

Status: implementation in progress. Unchecked tasks retain their complete acceptance gates; implemented slices and verification evidence are tracked in docs/build-status.md. Updated 2026-11-01 for knowledge/memory, project-aware Codex sessions, GitHub and native experience quality.

Existing T01–T33 IDs and acceptance criteria are retained, with dependencies strengthened where necessary. New R/K/G/Q/U tasks extend the same plan. **The order below, not numeric ID order, is the default delivery sequence.** Project context and connector foundations are deliberately pulled forward.

All paths describe intended responsibilities, not an existing implementation. Existing T-task paths use the proposed project tree. New shortened `Knowledge/`, `Projects/`, `Runtime/`, `Providers/` and `Connectors/` paths mean modules under `Packages/SlimeCore/Sources/SlimeCore/`; `Tests/` means core/native tests as applicable; `Surfaces/` means `App/Surfaces/`. `App/`, `Design/`, `docs/` and `scripts/` paths are project-relative. Keep patches focused and split an oversized task further.

**Verification commands:** T02 establishes the real project scheme and `scripts/check.sh`. Use the affected build/focused tests and each task's specific checks. Do not claim live provider or native behavior from mocks or the HTML preview.

**Completion record:** when checking a task, append build/test results, native/manual evidence and compatibility limitations. Checkpoints are evidence reviews, not automatic permission prompts.

## M0: Feasibility and native design

### T01: Record the supported development path

- [ ] Complete T01.

**Dependencies:** None.
**Scope:** Small; one focused implementation slice.
**Likely files:** `docs/compatibility.md`, `docs/architecture.md`.

**Acceptance criteria:**
- [ ] Record target OS/hardware, toolchain and installed CLI versions without starting a model run.
- [ ] Record the initial Codex operations, auth-dependent capabilities and a fixture source/refresh strategy.
- [ ] Resolve or explicitly scope unsupported initial capabilities; keep provider authentication material out of the record.

**Verification:** Review the record against official documentation and locally observed version output.

### Q01: Define Mochlet visual and native profiling baselines

- [ ] Complete Q01.

**Dependencies:** T01.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `docs/native-quality.md`, `docs/design-decisions.md`, `Design/character-studies/`, `docs/performance-baseline.md`.

**Acceptance criteria:**
- [ ] Produce original silhouette/pose studies and compact/expanded/attention surface designs at real notch size.
- [ ] Choose provisional timing/interaction rules and record supported OS/hardware/display measurement conditions.
- [ ] Treat Mochlet as a working name and record asset provenance; do not present the HTML concept as production acceptance.

**Verification:** Review still frames and flow storyboards for legibility, original identity, focus behavior and reduced-motion equivalents.

#### Checkpoint after Q01 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M1a: Routed native companion

### T02: Open a native notch and menu-bar shell

- [ ] Complete T02.

**Dependencies:** T01.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `SlimeApp.xcodeproj/project.pbxproj`, `App/SlimeApp.swift`, `App/Surfaces/NotchController.swift`, `Packages/SlimeCore/Package.swift`, `scripts/check.sh`.

**Acceptance criteria:**
- [ ] Build and launch a native app with a menu-bar item and an empty expandable panel.
- [ ] Open/close the panel without terminating the app or stealing focus on background events.
- [ ] Provide a reproducible build/core-test entry point and a working no-notch fallback.

**Verification:** Build with the recorded toolchain; check focus, panel close and fallback placement on the target Mac.

### T03: Render and customize the slime

- [ ] Complete T03.

**Dependencies:** T02, Q01.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Character/SlimeView.swift`, `App/Character/SlimeState.swift`, `App/Surfaces/ProfileSettings.swift`, `Packages/SlimeCore/Sources/SlimeCore/Domain/SlimeProfile.swift`.

**Acceptance criteria:**
- [ ] Choose a name and palette and retain them across launches.
- [ ] Render idle, working, listening, asking and error states with equivalent text labels.
- [ ] Reduced-motion mode removes continuous motion while preserving status meaning.

**Verification:** Exercise every state in previews and the running app; verify keyboard settings and preference persistence.

### T04: Persist a task and its execution history

- [ ] Complete T04.

**Dependencies:** T02.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Domain/Task.swift`, `Packages/SlimeCore/Sources/SlimeCore/Domain/Run.swift`, `Packages/SlimeCore/Sources/SlimeCore/Persistence/TaskStore.swift`, `App/Surfaces/TaskHistoryView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/TaskStoreTests.swift`.

**Acceptance criteria:**
- [ ] Create a task, append an attempt and reopen the history after relaunch.
- [ ] Keep task completion separate from run success and preserve runtime snapshots.
- [ ] Use a versioned schema with a tested initial migration and meaningful storage-error UI.

**Verification:** Round-trip fixture tasks through a temporary database; test restart, migration and write failure.

#### Checkpoint after T04

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T05: Implement bounded structured process transport

- [ ] Complete T05.

**Dependencies:** T01, T04.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Runtime/ProcessTransport.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/AgentEvent.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/Capabilities.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/TransportTests.swift`, `Packages/SlimeCore/Tests/Fixtures/transport.jsonl`.

**Acceptance criteria:**
- [ ] Launch a fixture executable with explicit arguments and working directory.
- [ ] Parse split/multiple frames, separate stderr and reject oversized or malformed frames safely.
- [ ] Bound buffering and translate exit/disconnection into a terminal or interrupted state.

**Verification:** Run deterministic fixture cases for framing, noisy stderr, output pressure and process death; no real CLI required.

### T13: Attach tasks to a project context

- [ ] Complete T13.

**Dependencies:** T04.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Domain/Project.swift`, `Packages/SlimeCore/Sources/SlimeCore/Persistence/ProjectStore.swift`, `App/Surfaces/ProjectView.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/ContextBuilder.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ProjectTests.swift`.

**Acceptance criteria:**
- [ ] Create a project with stable ID, explicit roots, instructions and resource references; routing metadata is extended in R01.
- [ ] Select the project when starting a task and record the context snapshot used for its run.
- [ ] Handle inaccessible/moved roots without broadening access silently.

**Verification:** Persist and reopen two projects; verify selected roots/instructions reach only their intended runs.

### R01: Register project identities and workspace bindings

- [ ] Complete R01.

**Dependencies:** T13.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Projects/ProjectRegistry.swift`, `Projects/RepositoryBinding.swift`, `Surfaces/ProjectRegistrationView.swift`, `Tests/ProjectRegistryTests.swift`.

**Acceptance criteria:**
- [ ] Persist unique project IDs, aliases, verified roots and explicit preferred workspace.
- [ ] Bind stable repository/host identities and optional board IDs without equating a board to one repository.
- [ ] Detect duplicate aliases, relocated roots and conflicting checkout identities before dispatch.

**Verification:** Use two projects with duplicate aliases, forks and moved roots; verify no fallback to home cwd.

#### Checkpoint after R01

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### R02: Resolve a command before choosing its runtime

- [ ] Complete R02.

**Dependencies:** R01, T05.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Projects/ProjectResolver.swift`, `Runtime/DispatchIntent.swift`, `Surfaces/DestinationStrip.swift`, `Tests/ProjectResolverTests.swift`.

**Acceptance criteria:**
- [ ] Resolve explicit project/issue/task context deterministically and reject conflicting destinations.
- [ ] Treat an attached file as input rather than an implicit target project.
- [ ] Show the resolved project/root/agent and require a selection only when destination is genuinely ambiguous.

**Verification:** Run ROUTE-01–03 and verify ambiguous requests emit no runtime start/turn command.

### T06: Run one managed Codex task

- [ ] Complete T06.

**Dependencies:** T04, T05, R02.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Providers/Codex/CodexAdapter.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/RunCoordinator.swift`, `App/Surfaces/ChatView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/CodexAdapterTests.swift`, `Packages/SlimeCore/Tests/Fixtures/codex-run.jsonl`.

**Acceptance criteria:**
- [ ] Send typed input to the selected project and stream normalized activity into the task view.
- [ ] Persist provider session/turn IDs and map completion to the correct run exactly once.
- [ ] Queue a second task while one is active; show missing CLI, authentication and unsupported-version failures.

**Verification:** Pass recorded protocol fixtures, then demonstrate one separately authorized live task in a temporary project.

### T07: Route approvals and questions correctly

- [ ] Complete T07.

**Dependencies:** T06.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Domain/PendingInput.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/PendingInputStore.swift`, `App/Surfaces/PendingInputView.swift`, `Packages/SlimeCore/Sources/SlimeCore/Providers/Codex/CodexAdapter.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/PendingInputTests.swift`.

**Acceptance criteria:**
- [ ] Display exact action context and supported text/choice questions with run/session/turn/request identity.
- [ ] Deliver approve, decline and answer responses once and show delivery failures.
- [ ] Remove resolved/expired requests; simultaneous requests cannot receive one another’s answers.

**Verification:** Replay interleaved requests, duplicate clicks, late answers, cancellation and provider resolution fixtures.

#### Checkpoint after T07

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T08: Cancel and reconcile interrupted work

- [ ] Complete T08.

**Dependencies:** T06, T07.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Runtime/RunCoordinator.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/RecoveryService.swift`, `Packages/SlimeCore/Sources/SlimeCore/Persistence/RunJournal.swift`, `App/Surfaces/RecoveryView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/RecoveryTests.swift`.

**Acceptance criteria:**
- [ ] Cancel an owned run through its supported control path and clear its pending input.
- [ ] After relaunch, identify resumable or interrupted attempts without silently rerunning the task.
- [ ] Closing the panel preserves work; quitting with active runs follows an explicit stop/detach policy.

**Verification:** Use kill/relaunch and disconnected-session fixtures; manually verify panel close versus app quit behavior.

### T09: Show trustworthy Codex usage

- [ ] Complete T09.

**Dependencies:** T06.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Domain/UsageSnapshot.swift`, `Packages/SlimeCore/Sources/SlimeCore/Providers/Codex/CodexUsage.swift`, `App/Surfaces/UsageView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/UsageTests.swift`.

**Acceptance criteria:**
- [ ] Display only returned account windows/reset times with source and freshness.
- [ ] Keep account quota snapshots separate from run token/cost records and deduplicate account buckets.
- [ ] Render absent, expired, API-key-only and disconnected data as unknown or stale, never fabricated zero.

**Verification:** Test null/partial data, multiple buckets and repeated snapshots; compare with an authorized live account response if available.

### T10: Choose a speech path through a bounded spike

- [ ] Complete T10.

**Dependencies:** T01, T02.
**Scope:** Small; one focused implementation slice.
**Likely files:** `docs/speech-evaluation.md`, `App/Voice/TranscriptionService.swift`, `App/Voice/TranscriptionProbe.swift`.

**Acceptance criteria:**
- [ ] Compare candidate engines on target hardware using chosen languages and short non-sensitive audio samples.
- [ ] Record latency, resource use, accuracy limitations, offline/network behavior and redistribution constraints.
- [ ] Select an engine or document a concrete fallback and expose a replaceable transcription interface.

**Verification:** Record reproducible sample results and a decision; no claim of offline transcription without a disconnected test.

#### Checkpoint after T10

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T11: Submit a task through push-to-talk

- [ ] Complete T11.

**Dependencies:** T06, T10.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Voice/VoiceController.swift`, `App/Surfaces/VoiceInputView.swift`, `App/Surfaces/ChatView.swift`, `App/Info.plist`, `Packages/SlimeCore/Tests/SlimeCoreTests/VoiceInputStateTests.swift`.

**Acceptance criteria:**
- [ ] Start recording only after an explicit gesture, show microphone state and stop/cancel clearly.
- [ ] Place an editable transcript into the same task submission flow as typed text.
- [ ] Handle permission denial, silence and transcription failure without creating duplicate tasks.

**Verification:** Use a fake transcription service for state tests, then manually test permission and chosen-language audio on the target Mac.

### T12: Unify attention and completion notifications

- [ ] Complete T12.

**Dependencies:** T03, T07, T08, T09, T11.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Surfaces/AttentionInbox.swift`, `App/Character/AttentionState.swift`, `App/Surfaces/NotificationSettings.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/AttentionTests.swift`.

**Acceptance criteria:**
- [ ] Collect pending approvals/questions and actionable failures in one inbox linked to tasks.
- [ ] Use a badge and text status without forcing focus; support quiet/reduced-motion behavior.
- [ ] Dismiss resolved items while keeping reviewable outputs and task history accessible.

**Verification:** Demonstrate the M1 journey from text and voice through approval/question to persisted result; test simultaneous and expired attention items.

### R03: Start or resume the exact project task session

- [ ] Complete R03.

**Dependencies:** T06, T08, R02.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Projects/SessionRegistry.swift`, `Providers/Codex/CodexAdapter.swift`, `Surfaces/SessionPicker.swift`, `Tests/ProjectSessionTests.swift`.

**Acceptance criteria:**
- [ ] Persist task/project/provider/account/thread/workspace identity and resume by exact compatible thread ID.
- [ ] Validate the effective returned cwd before sending a turn and refuse silent cross-project retargeting.
- [ ] Handle active, missing, corrupted or ambiguous sessions through live view, explicit choice or visible continuity loss.

**Verification:** Run ROUTE-04–06 with interleaved fixtures and an authorized live start/resume check in a temporary registered project.

#### Checkpoint after R03

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### Q02: Build interruptible production character motion

- [ ] Complete Q02.

**Dependencies:** T03, Q01.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `App/Character/SlimeRenderer.swift`, `App/Character/MotionController.swift`, `App/Character/ExpressionReducer.swift`, `Tests/CharacterStateTests.swift`, `Design/character-assets/`.

**Acceptance criteria:**
- [ ] Implement coordinated body/eyes/mouth/accessory motion with stable anchoring and truthful state transitions.
- [ ] Interrupt/reverse transitions from current visual state, coalesce rapid events and preserve input responsiveness.
- [ ] Provide static/reduced-motion equivalents and pause unnecessary work when hidden or resting.

**Verification:** Capture native idle/listen/feed/chew/ask/success/error transitions at real scale and under streamed output; measure hitch/frame behavior.

### Q03: Harden the native service and panel lifecycle

- [ ] Complete Q03.

**Dependencies:** T08, R03, T12.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `App/Surfaces/NotchController.swift`, `App/Services/AppLifecycle.swift`, `Runtime/RunCoordinator.swift`, `Tests/NativeLifecycleTests.swift`.

**Acceptance criteria:**
- [ ] Keep run ownership and pending requests independent of surface lifetime and correctly reconcile sleep/wake.
- [ ] Handle display/Space/full-screen changes and no-notch fallback without stealing focus or trapping input.
- [ ] Bound background queues/reconnects and show explicit stop/quit behavior; do not promise unimplemented helper persistence.

**Verification:** Exercise panel churn while running, display relocation, sleep/relaunch and lost control channels; detect duplicate/orphaned processes.

### Q04: Finish voice, drag/drop and keyboard interaction feel

- [ ] Complete Q04.

**Dependencies:** Q02, Q03, T11.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `App/Surfaces/CompanionPanel.swift`, `App/Voice/VoiceController.swift`, `App/Surfaces/DropFeedback.swift`, `docs/native-walkthrough.md`.

**Acceptance criteria:**
- [ ] Acknowledge clicks/recording/drop acceptance immediately and keep composer layout stable.
- [ ] Give unsupported payloads, permission failures, partial work and pending input clear text plus character feedback.
- [ ] Provide keyboard/VoiceOver operation, quiet/privacy modes and no animation-dependent delay before an action.

**Verification:** Record the native walkthrough in the quality contract and check acknowledgement latency; mock file progress until T15 then repeat with real intake.

#### Checkpoint after Q04 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M1b: Personal knowledge and memory

### K01: Implement the portable scoped knowledge vault

- [ ] Complete K01.

**Dependencies:** T04, R01.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Knowledge/KnowledgeDocument.swift`, `Knowledge/OKFCodec.swift`, `Knowledge/VaultStore.swift`, `Tests/OKFCodecTests.swift`, `docs/okf-compatibility.md`.

**Acceptance criteria:**
- [ ] Pin and validate the selected OKF revision; round-trip standard and unknown extension fields.
- [ ] Store personal/shared/project bundles with stable app IDs, source references and explicit scope metadata.
- [ ] Use atomic writes and recoverable document/index bookkeeping; reject path traversal and unsafe YAML constructors.

**Verification:** Round-trip the example bundle, malformed/frontmatter cases and renamed concepts; verify no dependency on a running vector service.

### K02: Build scoped lexical retrieval and source expansion

- [ ] Complete K02.

**Dependencies:** K01.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Knowledge/KnowledgeIndex.swift`, `Knowledge/Retriever.swift`, `Knowledge/SourceLocator.swift`, `Tests/ScopedRetrievalTests.swift`.

**Acceptance criteria:**
- [ ] Rebuild a SQLite FTS index from authorized documents and source revisions.
- [ ] Filter by granted scopes before ranking and before returning results; expand summaries to supporting source spans within a budget.
- [ ] Expose index lag, broken/missing sources and result provenance instead of silently returning stale matches.

**Verification:** Use exact terms, aliases, multilingual fixture terms, duplicate filenames and cross-project secrets; record query latency.

### K03: Review, correct and forget durable memories

- [ ] Complete K03.

**Dependencies:** K01, T04.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Knowledge/MemoryRevision.swift`, `Knowledge/MemoryLifecycle.swift`, `Surfaces/MemoryReviewView.swift`, `Tests/MemoryLifecycleTests.swift`.

**Acceptance criteria:**
- [ ] Accept explicit remember/update requests while keeping inferred candidates separate from reviewed memory.
- [ ] Represent corrections, contradictions and supersession with evidence and reversible history where retained.
- [ ] Forget removes active retrieval copies/caches; identify independently retained transcripts, sources and backups.

**Verification:** Run KNOW-04/06/07 and cyclic/missing replacement cases; verify no model output becomes human-reviewed automatically.

#### Checkpoint after K03

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### K04: Answer from a bounded evidence packet

- [ ] Complete K04.

**Dependencies:** K02, K03, T06, R02.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Knowledge/EvidencePacket.swift`, `Knowledge/GroundedAnswer.swift`, `Surfaces/AnswerEvidenceView.swift`, `Tests/GroundedAnswerTests.swift`.

**Acceptance criteria:**
- [ ] Assemble project-scoped source passages and relevant reviewed preferences with stable citation locators.
- [ ] Distinguish current, stale, contradictory and missing evidence; unsupported questions yield uncertainty or a useful clarification.
- [ ] Validate citation resolution and display sources/revisions without treating link validity as factual proof.

**Verification:** Run answerable, unanswerable and stale/conflicting source fixtures; manually score claim support against source passages.

### K05: Supply project knowledge to new and resumed runs

- [ ] Complete K05.

**Dependencies:** K04, R03.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Runtime/ContextBuilder.swift`, `Knowledge/KnowledgeToolProvider.swift`, `Runtime/RunContextManifest.swift`, `Tests/KnowledgeDispatchTests.swift`.

**Acceptance criteria:**
- [ ] Inject bounded current knowledge and requirement-file references into the resolved task session.
- [ ] Record which evidence/revisions were supplied; avoid indiscriminate replay of the full personal vault or duplicate memory on every turn.
- [ ] Offer scoped read/proposal operations while keeping write authority and project selection outside retrieved content.

**Verification:** Verify knowledge isolation across two project sessions, source revision refresh and a malicious instruction embedded in retrieved content.

### K06: Establish the answer-quality and memory regression corpus

- [ ] Complete K06.

**Dependencies:** K05.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Tests/Fixtures/knowledge-corpus/`, `Tests/KnowledgeEvaluationTests.swift`, `docs/knowledge-evaluation.md`.

**Acceptance criteria:**
- [ ] Create frozen answerable/unanswerable, contradiction, stale-source, multilingual and scope-isolation cases with human reference evidence.
- [ ] Report retrieval recall, supported-claim ratio and abstention separately; pass all routing/access/deletion cases and the proposed fixture-quality gate.
- [ ] Compare optional embeddings only against the same lexical baseline; record the implementation and model versions for each run.

**Verification:** Execute the corpus and publish denominators/errors; do not report benchmark success for unrun models or treat it as universal accuracy.

#### Checkpoint after K06 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M2: Project boards and files

### T14: Manage tasks in a board and detail view

- [ ] Complete T14.

**Dependencies:** T13.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Surfaces/TaskBoard.swift`, `App/Surfaces/TaskDetail.swift`, `Packages/SlimeCore/Sources/SlimeCore/Domain/Task.swift`, `Packages/SlimeCore/Sources/SlimeCore/Persistence/TaskStore.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/TaskWorkflowTests.swift`.

**Acceptance criteria:**
- [ ] Edit status, priority, profile assignment, due date and project; filter the board.
- [ ] Represent parent/dependency references and prevent self/cyclic dependencies.
- [ ] Keep comments, attempts and outputs in task detail; run success does not bypass review.

**Verification:** Exercise workflow transitions and dependency validation; reopen the board to verify persisted ordering and metadata.

### T15: Inventory dropped files and folders

- [ ] Complete T15.

**Dependencies:** T13.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Surfaces/FileDropView.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/FileManifest.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/InventoryService.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/InventoryTests.swift`.

**Acceptance criteria:**
- [ ] Create a bounded manifest for an explicitly selected root with sizes, formats and progress.
- [ ] Reject escaped symlinks and report inaccessible, skipped or oversized items.
- [ ] Drive chewing state from actual ingestion progress and keep originals unchanged.

**Verification:** Use temporary folders with symlinks, permission failures, nested trees and cap boundaries; verify cancellation.

### T16: Extract text and PDF input

- [ ] Complete T16.

**Dependencies:** T15.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/TextExtractor.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/PDFExtractor.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/ExtractionResult.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ExtractionTests.swift`, `Packages/SlimeCore/Tests/Fixtures/sample-document.pdf`.

**Acceptance criteria:**
- [ ] Extract bounded text with file/page references and chunk large documents.
- [ ] Identify scanned/unsupported/encrypted or failed input without presenting empty extraction as success.
- [ ] Record extracted, skipped and failed manifest items and derivative locations.

**Verification:** Check text and PDF fixtures against known page content, limits and failure cases; OCR remains a separate follow-on if needed.

#### Checkpoint after T16

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T17: Pass supported image attachments

- [ ] Complete T17.

**Dependencies:** T06, T15.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/ImageInput.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/Capabilities.swift`, `App/Surfaces/AttachmentPreview.swift`, `Packages/SlimeCore/Sources/SlimeCore/Providers/Codex/CodexAdapter.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ImageInputTests.swift`.

**Acceptance criteria:**
- [ ] Validate image type/size and show a preview before submission.
- [ ] Pass images only through a verified compatible provider/model path.
- [ ] Show an unsupported-state fallback and make the cloud-processing boundary visible.

**Verification:** Test valid/malformed/oversized images and unsupported capabilities with fixtures; use a non-sensitive image for an authorized live check.

### T18: Produce source-linked file summaries

- [ ] Complete T18.

**Dependencies:** T14, T16, T17.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/AnalysisContext.swift`, `App/Surfaces/AnalysisResultView.swift`, `Packages/SlimeCore/Sources/SlimeCore/Domain/Artifact.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/AnalysisResultTests.swift`.

**Acceptance criteria:**
- [ ] Create an analysis task from selected manifest items and preserve the exact input set.
- [ ] Present file/page references and generated artifact locations with the result.
- [ ] Keep incomplete processing and unverified model claims distinguishable from source-backed output.

**Verification:** Run the sample-folder journey; open every referenced fixture source and verify partial-analysis labeling.

### T19: Preview a validated file-operation plan

- [ ] Complete T19.

**Dependencies:** T18.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/FilePlan.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/PlanValidator.swift`, `App/Surfaces/FilePlanView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/FilePlanTests.swift`.

**Acceptance criteria:**
- [ ] Parse schema-validated copy/move/rename proposals with source, destination and reason.
- [ ] Check granted roots, collision policy, cycles and source identity before execution.
- [ ] Present a reviewable diff; analysis/preview does not execute the proposed operations, and the provider read-only limitation is explicit.

**Verification:** Use temporary-file plans for traversal, duplicate destinations, changed sources and collisions; verify no executor is invoked by preview.

#### Checkpoint after T19

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T20: Apply journaled same-volume file changes

- [ ] Complete T20.

**Dependencies:** T19.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/FileExecutor.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/OperationJournal.swift`, `App/Surfaces/FileOperationResultView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/FileExecutorTests.swift`.

**Acceptance criteria:**
- [ ] Apply only the authorized validated plan with rechecked preconditions.
- [ ] Journal each operation and result; reject overwrite collisions and stop on uncertain state.
- [ ] Expose per-file success/failure and preserve the previous state needed for recovery.

**Verification:** Execute only inside temporary roots; test mid-plan failures and assert unrelated files remain unchanged.

### T21: Recover and conditionally undo file operations

- [ ] Complete T21.

**Dependencies:** T20.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Files/FileExecutor.swift`, `Packages/SlimeCore/Sources/SlimeCore/Files/OperationRecovery.swift`, `App/Surfaces/FileOperationHistoryView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/OperationRecoveryTests.swift`.

**Acceptance criteria:**
- [ ] Use copy/verify/remove semantics for cross-volume moves and journal intermediate states.
- [ ] Reconcile an interrupted operation without deleting the only valid copy.
- [ ] Undo only when recorded postconditions still match; show changed-file/destination conflicts for manual resolution.

**Verification:** Inject failures between operation steps; test reversals and modified destinations, with a real second volume check before claiming cross-volume support.

#### Checkpoint after T21 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M2g: GitHub-driven project work

### T26: Build scoped connector configuration

- [ ] Complete T26.

**Dependencies:** T13.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Connectors/Connection.swift`, `Packages/SlimeCore/Sources/SlimeCore/Connectors/ToolGateway.swift`, `App/Surfaces/ConnectionSettings.swift`, `App/Services/CredentialStore.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ConnectorScopeTests.swift`.

**Acceptance criteria:**
- [ ] Store connection metadata separately from Keychain credentials and declare supported read/write actions.
- [ ] Bind tool access to account/project/run without injecting secrets into prompts.
- [ ] Handle revoked/missing credentials and disabled capabilities with actionable states.

**Verification:** Use fake services and a test credential namespace; verify denied scopes, revocation and log redaction.

### G01: Connect GitHub and bind repositories to projects

- [ ] Complete G01.

**Dependencies:** T26, R01.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Connectors/GitHubConnection.swift`, `Connectors/GitHubBindings.swift`, `Surfaces/GitHubConnectionView.swift`, `Tests/GitHubBindingTests.swift`, `docs/connectors/github.md`.

**Acceptance criteria:**
- [ ] Select a supported authentication path and verify repository versus Projects permission requirements without bundling app secrets.
- [ ] Map host/account/repository IDs and optional board IDs to registered projects and verified local checkouts.
- [ ] Show missing/revoked access and unmapped resources without silently creating or switching a working directory.

**Verification:** Use fake account/repository metadata, transfers and duplicate names; verify one authorized read-only connection when available.

### G02: Synchronize repository issues into a durable mirror

- [ ] Complete G02.

**Dependencies:** G01, T14.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Connectors/GitHubIssueSync.swift`, `Connectors/GitHubMirrorStore.swift`, `Surfaces/GitHubIssueList.swift`, `Tests/GitHubIssueSyncTests.swift`.

**Acceptance criteria:**
- [ ] Page and cache issues/comments/labels with stable identities and revisions; distinguish PR records where applicable.
- [ ] Maintain a first-sync baseline, overlapping incremental reads, deduplication and last-complete watermarks.
- [ ] Expose partial/offline/rate-limited/revoked states and reconcile closures or transfers without deleting on partial evidence.

**Verification:** Run GH-01/04/05 with more than one page, timestamp ties, duplicate records and failure midway through a refresh.

#### Checkpoint after G02

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### G03: Synchronize Projects v2 items and field mappings

- [ ] Complete G03.

**Dependencies:** G02.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Connectors/GitHubProjectSync.swift`, `Connectors/GitHubProjectMapping.swift`, `Surfaces/GitHubBoardBindingView.swift`, `Tests/GitHubProjectSyncTests.swift`.

**Acceptance criteria:**
- [ ] Mirror project/item/content/field/option identities with complete nested pagination.
- [ ] Represent issue, PR and draft items separately and resolve each repository binding independently.
- [ ] Map status fields explicitly and surface archived/removed items or changed options without guessing.

**Verification:** Run GH-03/09 on a multi-repository board with drafts, PRs, missing fields and more than one field-value page.

### G04: Prepare a verified per-task coding workspace

- [ ] Complete G04.

**Dependencies:** R01, T05, T08.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Projects/TaskWorkspaceManager.swift`, `Projects/WorkspaceLease.swift`, `Surfaces/WorkspaceReviewView.swift`, `Tests/TaskWorkspaceTests.swift`.

**Acceptance criteria:**
- [ ] Create and record a task branch/worktree from a verified repository/base without altering the dirty primary checkout.
- [ ] Validate allowed roots, repository identity and lease ownership before execution/resume.
- [ ] Recover missing/interrupted workspaces and defer cleanup until results are accepted or deliberately archived.

**Verification:** Run GH-07 with dirty files, multiple checkouts, missing branches and crash recovery; verify task isolation is not advertised as a security sandbox.

### G05: Dispatch authorized GitHub issues to the right Codex sessions

- [ ] Complete G05.

**Dependencies:** G02, G03, G04, R03, K05.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Projects/IssueDispatcher.swift`, `Projects/DispatchClaimStore.swift`, `Surfaces/IssueWorkQueue.swift`, `Tests/IssueDispatchTests.swift`.

**Acceptance criteria:**
- [ ] Resolve the requested repo/board/filter and queue a clear authorized batch once; sync alone does not launch work.
- [ ] Bind each issue to task/workspace/session plus an issue revision and current scoped evidence.
- [ ] Recheck eligibility before launch and avoid active duplicates; ambiguous bindings block only the unresolved item.

**Verification:** Run GH-02/06 and ROUTE scenarios including repeated commands, closed issues, competing local claims and multiple tasks in one project.

#### Checkpoint after G05

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### G06: Review issue work and create authorized draft PRs

- [ ] Complete G06.

**Dependencies:** G05.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Connectors/GitHubPullRequests.swift`, `Surfaces/CodeChangeReview.swift`, `Connectors/DeliveryLedger.swift`, `Tests/GitHubPRDeliveryTests.swift`.

**Acceptance criteria:**
- [ ] Show code diff, reproduction/test evidence, task/issue identity and exact source/target branch.
- [ ] Push/create a draft PR only within authorization and record stable branch/PR/result identities.
- [ ] Reconcile uncertain create responses before retrying; successful agent execution does not merge or close an issue.

**Verification:** Use mock pushes and remote PR fixtures for GH-08/10; perform real account writes only when explicitly authorized.

### G07: Reconcile GitHub lifecycle and authorized write-back

- [ ] Complete G07.

**Dependencies:** G06, G03.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `Connectors/GitHubReconciliation.swift`, `Connectors/OutboundAction.swift`, `Surfaces/SyncConflictView.swift`, `Tests/GitHubReconciliationTests.swift`.

**Acceptance criteria:**
- [ ] Track PR/issue state independently from board status and local review/completion.
- [ ] Apply only configured authorized comments/status updates with expected revisions and durable delivery identity.
- [ ] Handle remote edits, revoked access and ambiguous delivery without blind last-write-wins or duplicate posts.

**Verification:** Replay out-of-order events, field deletion, merge/close changes and response-loss writes; verify conflicts retain both versions.

#### Checkpoint after G07 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M3: Multiple agents

### T22: Validate the Claude bridge and authentication path

- [ ] Complete T22.

**Dependencies:** T05, T07.
**Scope:** Small; one focused implementation slice.
**Likely files:** `docs/claude-compatibility.md`, `Bridges/ClaudeProbe/`, `Packages/SlimeCore/Tests/Fixtures/claude-input.jsonl`.

**Acceptance criteria:**
- [ ] Select a supported personal/public authentication route using current official guidance.
- [ ] Demonstrate structured streaming, permission callback and question exchange in a bounded bridge or fixture harness.
- [ ] Record packaging/runtime costs and unsupported behavior before app integration.

**Verification:** Verify the bridge protocol with mocked SDK messages and a separately authorized live smoke test when the chosen auth route is available.

### T23: Integrate managed Claude runs

- [ ] Complete T23.

**Dependencies:** T22, T08.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Providers/Claude/ClaudeAdapter.swift`, `App/Surfaces/RuntimeSettings.swift`, `Packages/SlimeCore/Sources/SlimeCore/Runtime/Capabilities.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ClaudeAdapterTests.swift`.

**Acceptance criteria:**
- [ ] Run Claude work through the common task/run event path and the selected bridge.
- [ ] Route supported permissions/questions with exact IDs; handle cancel and resume only where verified.
- [ ] Keep provider-native session/configuration separate from Codex and expose unavailable capabilities.

**Verification:** Replay Claude lifecycle/input fixtures and interleave them with Codex requests; confirm no cross-provider response routing.

### T24: Integrate Pi RPC runs

- [ ] Complete T24.

**Implementation evidence (2026-11-01):** Native selection and managed Pi 1.4.0 runs now implement stream/lifecycle translation, exact session binding, verified cwd/tool preflight, approval extension, dialogs, cancellation and separate session usage. Process and native fixtures pass; real Pi no-inference preflight passes. Live authenticated generation and real tool approvals remain unverified, so the full gate stays open. See [Pi compatibility](../docs/pi-compatibility.md).

**Dependencies:** T05, T07, T08.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Providers/Pi/PiAdapter.swift`, `App/Surfaces/RuntimeSettings.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/PiAdapterTests.swift`, `Packages/SlimeCore/Tests/Fixtures/pi-rpc.jsonl`.

**Acceptance criteria:**
- [ ] Translate prompt/stream/lifecycle events into the common run model.
- [ ] Handle supported extension UI requests with matching response IDs and timeouts.
- [ ] Mark universal approvals or account limits unsupported unless an actual integration supplies them.

**Verification:** Exercise prompt, cancellation, extension input and process failure fixtures; run an authorized live sample if available.

#### Checkpoint after T24

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T25: Observe external sessions with explicit limits

- [ ] Complete T25.

**Dependencies:** T09, T23, T24.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Runtime/SessionObserver.swift`, `Packages/SlimeCore/Sources/SlimeCore/Providers/Claude/ClaudeObserver.swift`, `App/Surfaces/SessionList.swift`, `App/Surfaces/UsageView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/ObserverTests.swift`.

**Acceptance criteria:**
- [ ] Start with an opt-in supported Claude hook/status-line feed and label its sessions Observed.
- [ ] Preserve existing integration configuration and provide removal; hide controls without a real control channel.
- [ ] Normalize available observed usage without double-counting account snapshots or inventing missing Pi/Codex observation capabilities.

**Verification:** Replay stale/missing telemetry and multi-session events; verify opt-in installation/removal in a temporary configuration. Other observer adapters are follow-on tasks.

#### Checkpoint after T25 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M4: Additional connectors

### T27: Capture a Slack thread into a task

- [ ] Complete T27.

**Dependencies:** T26, T14.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Connectors/SlackConnector.swift`, `App/Surfaces/SlackCaptureView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/SlackConnectorTests.swift`, `docs/connectors/slack.md`.

**Acceptance criteria:**
- [ ] Verify current authentication/scopes and read one explicitly selected authorized thread.
- [ ] Create or link a task with stable conversation/message IDs and visible source context.
- [ ] Deduplicate repeated captures and distinguish missing permission from missing content.

**Verification:** Use mock API fixtures and then a selected test thread if authorized; no outbound message in this task.

### T28: Capture Lark context into a task

- [ ] Complete T28.

**Dependencies:** T26, T14.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Connectors/LarkConnector.swift`, `App/Surfaces/LarkCaptureView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/LarkConnectorTests.swift`, `docs/connectors/lark.md`.

**Acceptance criteria:**
- [ ] Verify current global Lark versus Feishu endpoint/auth differences and select the intended environment.
- [ ] Capture one selected authorized conversation or document reference into a task with stable source IDs.
- [ ] Handle inaccessible content and duplicate capture; record which resource types are actually supported.

**Verification:** Use environment-specific mock fixtures and one authorized sample; expanded search/document ingestion remains follow-on work.

### T29: Link a Linear issue to a local task

- [ ] Complete T29.

**Dependencies:** T26, T14.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Connectors/LinearConnector.swift`, `App/Surfaces/LinearLinkView.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/LinearConnectorTests.swift`, `docs/connectors/linear.md`.

**Acceptance criteria:**
- [ ] Verify current authentication/scopes and import a selected issue with its stable remote ID.
- [ ] Map title, description and supported status fields without overwriting local edits silently.
- [ ] Show stale remote revisions and prevent duplicate local tasks for repeated imports.

**Verification:** Test fixtures for import, permission failure, edits and repeated imports; verify against a selected test issue if authorized.

#### Checkpoint after T29

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T30: Publish authorized results without duplicates

- [ ] Complete T30.

**Dependencies:** T27, T28, T29, G07.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Packages/SlimeCore/Sources/SlimeCore/Connectors/OutboundAction.swift`, `Packages/SlimeCore/Sources/SlimeCore/Connectors/DeliveryLedger.swift`, `App/Surfaces/OutboundPreview.swift`, `Packages/SlimeCore/Tests/SlimeCoreTests/OutboundDeliveryTests.swift`.

**Acceptance criteria:**
- [ ] Prepare a reviewable supported reply/update tied to the original source and intended account.
- [ ] Send only within user authorization and keep an idempotency/delivery record across retries.
- [ ] On uncertain delivery or a changed remote revision, reconcile or surface a conflict instead of blindly resending.

**Verification:** Test retries, response loss, wrong-account prevention and conflicts with mocks; perform only explicitly authorized service writes in live checks.

#### Checkpoint after T30 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

## M4g: Google workflows

See [Google integration design](../docs/google-integration.md). All tasks are planned; no connection or live write is implied.

### U01: Connect and isolate Google accounts

- [ ] Complete U01.

**Dependencies:** T26, R01.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/GoogleAccount.swift`, `Connectors/GoogleOAuth.swift`, `Surfaces/GoogleAccountsView.swift`, `Tests/GoogleAccountTests.swift`, `docs/connectors/google.md`.

**Acceptance criteria:**
- [ ] Validate the supported desktop OAuth/redirect flow, PKCE/state, intended audience, required scope categories and distribution verification requirements before implementing dependent features.
- [ ] Store tokens in Keychain; show account identity and actual granted capabilities, with project bindings and partial-consent handling.
- [ ] Support disconnect/revocation and prevent wrong-account or disabled-scope calls without placing secrets in prompts or logs.

**Verification:** Use fake OAuth/grant fixtures for callback mismatch, partial consent, token refresh and account switching; record a live test-account sign-in separately.

### U02: Read Gmail context into project tasks

- [ ] Complete U02.

**Dependencies:** U01, T14, R03.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/GmailReader.swift`, `Surfaces/MailContextView.swift`, `Projects/MailTaskCapture.swift`, `Tests/GmailReaderTests.swift`.

**Acceptance criteria:**
- [ ] Search and paginate authorized mail; show account, thread/message identities and source links with bounded MIME/attachment handling.
- [ ] Summarize selected threads with evidence and create/link one task in an explicitly resolved project; do not mark mail read or dispatch solely on refresh.
- [ ] Keep untrusted message content from changing tool permissions or routing, and prevent duplicate capture across refreshes.

**Verification:** Replay MIME, attachments, pagination, prompt-injection and ambiguous-project fixtures; demonstrate a selected email becoming a correctly routed task.

### U03: Read calendars and prepare meeting context

- [ ] Complete U03.

**Dependencies:** U01, K06.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/CalendarReader.swift`, `Surfaces/AgendaView.swift`, `Knowledge/MeetingContext.swift`, `Tests/CalendarReaderTests.swift`.

**Acceptance criteria:**
- [ ] Select accounts/calendars and display agenda plus available free/busy information with source links and freshness.
- [ ] Handle time zones, all-day events, recurring instances, cancellations and daylight-saving boundaries without duplicate agenda entries.
- [ ] Prepare a meeting brief only from selected accessible event/project sources; distinguish missing visibility from a genuinely free time slot.

**Verification:** Use multi-calendar fixtures with DST, overlapping events, recurrence exceptions and restricted visibility; verify no write call occurs.

#### Checkpoint after U03

- [ ] Focused checks pass and the native app builds.
- [ ] Demonstrate the completed workflow with account identity, partial permissions and failure states visible.
- [ ] Record evidence for source scope, authorization and recovery before the next slice.

### U04: Ingest selected Google files as scoped evidence

- [ ] Complete U04.

**Dependencies:** U01, K06, T18.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/GoogleDocumentReader.swift`, `Knowledge/GoogleSource.swift`, `Surfaces/GoogleFileSelection.swift`, `Tests/GoogleSourceTests.swift`.

**Acceptance criteria:**
- [ ] Select accessible Drive files and extract supported Docs/Sheets/Slides content with bounded size, explicit partial/unsupported states and verifiable source locators.
- [ ] Record account/object identity, revision or hash and selected knowledge scope; separate temporary reads from user-selected durable ingestion.
- [ ] Validate per-file grants, invalidate revoked-source retrieval, and pass requirements to the existing project resolver before a requested coding task.

**Verification:** Use selected-file fixtures for exports, ranges/slides, permission loss, changed revisions and cross-project isolation; do not claim whole-folder access from one selection.

### U05: Prepare and deliver Gmail replies

- [ ] Complete U05.

**Dependencies:** U02, T30.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/GmailWriter.swift`, `Surfaces/MailDraftPreview.swift`, `Connectors/DeliveryLedger.swift`, `Tests/GmailDeliveryTests.swift`.

**Acceptance criteria:**
- [ ] Show sender/account, recipients including Cc/Bcc, thread, body and attachments; distinguish local drafts, remote draft saves and send actions.
- [ ] Enable only granted capabilities and execute the concrete action within existing user authorization; persist remote identifiers and delivery results.
- [ ] Reconcile uncertain send results when supported and surface unresolved outcomes without blind retries or duplicate messages.

**Verification:** Exercise wrong-account, changed-recipient, denied-scope, expired-authorization and lost-response fixtures; live sends target only authorized test recipients.

#### Checkpoint after U05

- [ ] Focused checks pass and the native app builds.
- [ ] Demonstrate the completed workflow with account identity, partial permissions and failure states visible.
- [ ] Record evidence for source scope, authorization and recovery before the next slice.

### U06: Schedule and update calendar events

- [ ] Complete U06.

**Dependencies:** U03, T30.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/CalendarWriter.swift`, `Surfaces/EventPreview.swift`, `Connectors/DeliveryLedger.swift`, `Tests/CalendarDeliveryTests.swift`.

**Acceptance criteria:**
- [ ] Prepare create/reschedule/cancel actions with calendar/account, time zone, attendees, notification behavior and occurrence-versus-series scope.
- [ ] Revalidate current availability and supported revision preconditions before an authorized write; surface conflicts and permission changes.
- [ ] Reconcile uncertain writes through supported remote evidence and retain an inspectable result; never infer authorization from an event description.

**Verification:** Use fixtures for DST changes, series exceptions, moved events, lost responses and attendee notifications; verify only authorized test events in live checks.

### U07: Recover Google refresh and revoked-source state

- [ ] Complete U07.

**Dependencies:** U02, U03, U04, U05, U06.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `Connectors/GoogleRefresh.swift`, `Connectors/GoogleSyncStore.swift`, `Knowledge/GoogleRevocation.swift`, `Tests/GoogleRecoveryTests.swift`, `docs/connectors/google.md`.

**Acceptance criteria:**
- [ ] Persist independent Gmail history/Calendar sync state per account and collection only after complete paging; use bounded rebuilds for invalid state and on-demand refresh for selected Drive files.
- [ ] Handle rate limits, offline/sleep/relaunch and partial failures with backoff and visible freshness; refresh never autonomously dispatches an agent or sends messages.
- [ ] On disconnect or revoked access, stop new calls, block queued writes and exclude affected cached evidence; expose imported-memory retention/deletion choices and pass GOOGLE-01–GOOGLE-10.

**Verification:** Replay expired cursors, partial pages, revocation and crash-after-write fixtures; run a native mixed-workload check for responsiveness and absence of duplicate effects.

#### Checkpoint after U07 — milestone exit

- [ ] Focused checks pass and the native app builds.
- [ ] Demonstrate the completed workflow with account identity, partial permissions and failure states visible.
- [ ] Record evidence for source scope, authorization and recovery before the next slice.

## M5: Release readiness

### T31: Finish native accessibility and display behavior

- [ ] Complete T31.

**Dependencies:** T12, T18, T25, T30, R03, K06, G07, Q04, U07.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `App/Surfaces/NotchController.swift`, `App/Surfaces/WorkspaceView.swift`, `App/Character/SlimeView.swift`, `docs/native-validation.md`.

**Acceptance criteria:**
- [ ] Support keyboard navigation and readable accessible names across primary workflows.
- [ ] Verify reduced motion, larger text, multiple displays, full-screen apps and no-notch fallback.
- [ ] Keep blocking attention available without stealing focus or relying solely on color/motion.

**Verification:** Run a recorded native checklist including keyboard-only and VoiceOver checks on the selected support matrix.

### T32: Measure responsiveness and lifecycle reliability

- [ ] Complete T32.

**Dependencies:** T21, T25, T30, T31.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `docs/performance.md`, `scripts/check-lifecycle.sh`, `Packages/SlimeCore/Tests/SlimeCoreTests/StressTests.swift`, `App/Services/Diagnostics.swift`.

**Acceptance criteria:**
- [ ] Measure idle CPU/memory and active streaming responsiveness on target hardware; record budgets and results.
- [ ] Exercise sleep/wake, network loss, large output, large manifests and disappearing CLIs without duplicate work.
- [ ] Offer redacted diagnostics and verify that logs omit credentials and file contents by default.

**Verification:** Use repeatable workload fixtures and native profiling; document failures and fixes before release rather than asserting unmeasured targets.

### Q05: Enforce native finish and resource budgets before release

- [ ] Complete Q05.

**Dependencies:** Q04, T31, T32, K06, G07.
**Scope:** Medium; one focused implementation slice. Split further if the concrete patch exceeds the intended boundary.
**Likely files:** `docs/native-release-review.md`, `docs/performance.md`, `scripts/check-native-quality.sh`.

**Acceptance criteria:**
- [ ] Measure and report the defined latency/frame/idle-memory/CPU targets on the documented reference Mac and actual release configuration.
- [ ] Complete a mixed-workload soak and visual/accessibility review without unresolved blocking regressions.
- [ ] Record any budget revision with evidence; do not declare high quality solely from a screenshot or synthetic browser test.

**Verification:** Repeat real-scale interactions under knowledge retrieval, GitHub refresh, streaming and file intake; inspect native profiling traces and process lifetime.

#### Checkpoint after Q05

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.

### T33: Package and document the supported release

- [ ] Complete T33.

**Dependencies:** T32, Q05.
**Scope:** Medium; one focused implementation slice.
**Likely files:** `scripts/package.sh`, `docs/install.md`, `docs/compatibility.md`, `README.md`.

**Acceptance criteria:**
- [ ] Produce a reproducible versioned build with required notices and dependency/asset license records.
- [ ] When distribution credentials are available, sign/notarize and verify installation and launch on a clean environment.
- [ ] Document supported CLI versions, capabilities, permissions, data locations, removal and known limitations.

**Verification:** Verify the actual packaged artifact. If signing/notarization cannot be completed, leave that criterion open and label the build development-only.

#### Checkpoint after T33 — milestone exit

- [ ] Focused checks pass and the application builds when code exists.
- [ ] Demonstrate the completed path, including unsupported/error states, and record remaining limitations.
- [ ] Check scope, native quality and evidence/isolation requirements before the next slice; ask only for decisions that actually need user input.
