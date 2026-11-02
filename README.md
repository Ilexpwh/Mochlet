# Mochlet — native slime companion

A native macOS companion that lives at the notch, runs work through your selected local AI CLI, and keeps projects, tasks and files organized.

**Status:** launchable native development build (2026-11-02), with real Codex and Claude start/resume workflows and an experimental Pi RPC adapter. The complete release plan is still in progress. `slime-app` is the development folder.

Implemented native workflows include:

- Saved companion profiles with character palette, instructions, agent and voice; task sessions retain their assigned profile snapshot. A simple customizable slime, Coucou-derived island motion, top/left/right docking, menu-bar fallback and workspace.
- Native project task board with persistent manual ordering, priorities, due dates, dependencies, comments, review states and separately saved per-attempt replies.
- Durable project/task history, a recoverable queue, exact agent sessions, project-scoped stored Codex history browsing, approvals/questions and available Codex allowance windows.
- Personal/project memory, source-linked answers, reviewed OKF folder import/export with lifecycle controls, file feeding, opt-in visual image summaries, local/AI organization proposals and reviewed moves with undo.
- Voice controls and configurable OpenRouter speech/analysis profiles; explicit encrypted microphone/system meeting capture, transcript revisions and speaker editing.
- GitHub account/repository binding, issue synchronization, cached discussions with comment-pinned task context, bounded Projects V2 board reading/status mapping, isolated task worktrees, exact-commit draft PR previews and durable publication reconciliation.
- Slack/Lark/Feishu/Linear verified token connections, selected source capture, project-bound task drafts, explicit memory copies and reviewed replies with durable delivery records.
- Google Desktop OAuth configuration, account/project bindings, Gmail threads with explicit tracked-thread history sync, calendar agenda/availability, durable selected-calendar sync with offline records and selected Drive text; reviewed source task drafts and explicit memory copies. Separate Gmail and Calendar write previews use a durable delivery ledger and uncertain-result reconciliation.

Voice and meetings require your own API configuration and further live validation. Google requires your own Desktop OAuth client and is fixture/native-setup verified; live account workflows remain unverified. Live Slack/Lark/Linear access, live Google account validation, live PR publishing, complete OKF conformance and distribution gates remain unfinished. See the [evidence ledger](docs/build-status.md) for precise limits.

## Implementation

The [HTML system map](docs/system-map.html) explains the implemented functions, architecture and remaining release gates, with an actual native screenshot.

The approved [technical specification](docs/technical-spec.md), [visual design system](docs/design-system.html) and [implementation sequence](tasks/implementation-plan.md) guide the build. [Build status](docs/build-status.md) distinguishes implemented behavior from pending live and release checks.

## Run locally

```sh
./scripts/check.sh
open build/Build/Products/Debug/Mochlet.app
```

Builds use `/Applications/Xcode.app/Contents/Developer` without changing global Xcode selection. The personal development build is ad-hoc signed for Apple Silicon; macOS 15 is the deployment target, not yet a tested OS configuration. Add a project folder, configure an agent executable in Agent settings, then send a task. Claude support is pinned to CLI 2.1.296; Pi support is pinned to 1.4.0. Existing CLI authentication is used. Pi has passed real no-inference preflight and native fixture workflows; live authenticated generation remains unverified. See [Pi compatibility](docs/pi-compatibility.md). Command–Return sends; Escape folds the island; Command–Shift–Space toggles it while Mochlet receives keyboard events. Global shortcuts are registered for Control–Option–Space (companion) and hold Control–Option–V (voice); physical-key/audio validation remains pending.

Coucou's island geometry and motion code are adapted under MIT; see [attribution and parity notes](docs/coucou-adaptation.md). No Coucou character or audio assets are bundled.

Drag the compact slime or the expanded island's name/character to dock at the top, left or right screen edge. Side panels expand inward. Mochlet remembers the display and position; Appearance → Screen edge provides the same placement choices without dragging.

Appearance → Companion display selects a specific display or Automatic. Saved display UUIDs survive numeric-ID changes where macOS preserves their identity; disconnected choices retain their preference while the panel uses an available screen. [Docking and recovery](docs/docking.md) records cancellation behavior and verification limits.

## Start here

1. [Build plan](tasks/plan.md) — scope, architecture choices, milestones, dependencies and risks.
2. [Implementation checklist](tasks/todo.md) — ordered tasks with acceptance criteria and verification.
3. [Product definition](docs/product.md) — requirements, user journeys and release boundaries.
4. [Architecture](docs/architecture.md) — modules, data model, runtime contracts and proposed source layout.
5. [Knowledge and memory](docs/knowledge-memory.md) — lightweight OKF vault, scoped retrieval, corrections and evidence.
6. [Project routing](docs/project-routing.md) — resolve the right project and start/resume its exact Codex session.
7. [GitHub integration](docs/github-integration.md) — repository/issues/Projects sync and issue-to-work execution.
8. [Google integrations](docs/google-integration.md) — Gmail, Calendar, Drive and selected Workspace knowledge sources.
9. [Native quality and name](docs/native-quality.md) — Mochlet identity, interaction/motion specification and performance gates.
10. [Acceptance scenarios](docs/acceptance-scenarios.md) and [research notes](docs/research-notes.md).
11. [Recommended additions](docs/suggestions.md) — optional ideas beyond the required scope.

The [example OKF bundle](examples/knowledge-demo/index.md) makes the proposed document format concrete. It contains fictional fixture content, not personal memory or a configured project.

The [interactive HTML blueprint](docs/reference/blueprint.html) remains an earlier visual concept. Its interactions are simulations and it predates the expanded knowledge/GitHub/Google scope and production motion contract. The [Coucou system map](docs/reference/coucou-system-map.html) documents the existing reference project.

## First working release

One original customizable slime, a responsive native notch panel with a menu-bar fallback, text and push-to-talk input, project-aware Codex start/resume, approvals and questions, persisted history, available usage and an attention inbox. Personal/project knowledge and reviewed memory are now implemented in the development build.

File feeding, summaries, reviewed moves, GitHub issue sync and isolated task workspaces are implemented. Remaining milestones include broader Projects field support and additional PR actions, external-client liveness/control, richer team write-back and broader connector workflows. Account-bound source capture for Slack/Lark/Feishu/Linear and Google Gmail/Calendar/Drive is implemented with fixture evidence; live account validation remains open. Native service reliability and character quality are checked from the first release, not deferred to the end.

## Working assumptions

- Native implementation with selected MIT-licensed Coucou island code adapted locally. Multica remains an architecture reference.
- One person on their own Mac first. Team/cloud functionality remains a future extension.
- Apple Silicon development first; minimum deployment target macOS 15; actual compatibility validation is still required.
- Codex is the first adapter. Capability and authentication checks determine what each later adapter can offer.
- Local orchestration and storage do not imply offline AI inference.
- `App/` and `Packages/SlimeCore/` are implemented source directories. Architecture documents also describe later modules that do not exist yet.

The roadmap remains broader than the development build. Consult the evidence ledger before treating a planned capability as complete.

## Verification and research

`./scripts/check.sh` runs core fixtures, builds the app and runs native orchestration regressions against disposable CLI processes. Live agent tests are opt-in: `MOCHLET_LIVE_CODEX=1` or `MOCHLET_LIVE_CLAUDE=1` with the corresponding test filter. They use your local CLI authentication. `MOCHLET_LIVE_PI_PATH=/absolute/path/to/pi` with the `livePiGuardPreflightWithoutModelInference` filter runs a real Pi preflight in an isolated empty agent directory without model inference.

[Component research](docs/component-research.md) and [Coucou porting details](docs/coucou-porting-research.md) record pinned upstream sources, licenses and adoption decisions. Coucou code is adapted with its MIT attribution; no proprietary character assets are included.

Project names, exact aliases and per-project coding instructions are editable in Projects. See [project settings](docs/project-settings.md) for routing and relocation limits.

Build a local Release ZIP with `./scripts/package-local.sh`. See [packaging and measured idle performance](docs/local-package.md) for artifact contents, reproduction and distribution limits.

[Knowledge bundle interchange](docs/okf-bundles.md) covers reviewed folder imports, scoped exports, freshness and deprecated-memory handling.

[Reviewed file organization](docs/file-organization.md) describes grouping, AI proposals, path validation and partial-failure undo.

[Calendar synchronization](docs/google-calendar-sync.md) documents atomic paging, expiry recovery, recurring cancellations and offline browsing.

[Tracked Gmail threads](docs/gmail-sync.md) documents bounded history refresh, offline reading and expired-cursor recovery without downloading unselected conversations.
