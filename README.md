# Mochlet — native slime companion

A native macOS companion that lives at the notch, runs work through your selected local AI CLI, and keeps projects, tasks and files organized.

**Status:** native development build available (2026-11-01). Mochlet now has a Coucou-style notch island, original minimal slime, workspace, persistent projects/tasks and a real Codex app-server adapter. Voice, meetings and external connectors remain in the implementation sequence. `slime-app` is the development folder.

## Implementation

The approved [technical specification](docs/technical-spec.md), [visual design system](docs/design-system.html) and [implementation sequence](tasks/implementation-plan.md) guide the build. [Build status](docs/build-status.md) distinguishes implemented behavior from pending live and release checks.

## Run locally

```sh
./scripts/check.sh
open build/Build/Products/Debug/Mochlet.app
```

Builds use `/Applications/Xcode.app/Contents/Developer` without changing global Xcode selection. The personal development build is ad-hoc signed for Apple Silicon; macOS 15 is the deployment target, not yet a tested OS configuration. Add a project folder, select Codex settings, then send a task. Command–Return sends; Escape folds the island; Command–Shift–Space toggles it while Mochlet receives keyboard events. No global shortcut registration yet.

Coucou's island geometry and motion code are adapted under MIT; see [attribution and parity notes](docs/coucou-adaptation.md). No Coucou character or audio assets are bundled.

Drag the compact slime or the expanded island's name/character to dock at the top, left or right screen edge. Side panels expand inward. Mochlet remembers the display and position; Appearance → Screen edge provides the same placement choices without dragging.

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

One original customizable slime, a responsive native notch panel with a menu-bar fallback, text and push-to-talk input, project-aware Codex start/resume, approvals and questions, persisted history, available usage and an attention inbox. The next core slice adds personal/project knowledge and reviewed memory before expanding providers.

Project boards, file feeding, source-linked summaries and reviewed file operations follow. GitHub repository/issues/Projects synchronization then feeds tasks into verified local workspaces. Later milestones add Claude Code, Pi, external-session observation, Lark, Slack and Linear, followed by Google accounts with Gmail, Calendar and selected Drive/Docs/Sheets/Slides sources. Native service reliability and character quality are checked from the first release, not deferred to the end.

## Working assumptions

- Native implementation with selected MIT-licensed Coucou island code adapted locally. Multica remains an architecture reference.
- One person on their own Mac first. Team/cloud functionality remains a future extension.
- Apple Silicon development first; provisional minimum macOS 15. Confirm support before implementation.
- Codex is the first adapter. Capability and authentication checks determine what each later adapter can offer.
- Local orchestration and storage do not imply offline AI inference.
- `App/` and `Packages/SlimeCore/` are implemented source directories. Architecture documents also describe later modules that do not exist yet.

The roadmap remains broader than the development build. Consult the evidence ledger before treating a planned capability as complete.
