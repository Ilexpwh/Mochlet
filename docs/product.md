# Product definition

## Purpose

Make a friendly, customizable slime the front door to agent work on a Mac. The slime should reduce the effort of starting work, understanding progress and resolving blockers. The full workspace holds the detail that cannot fit at the notch.

## User-requested capabilities

| Area | Intended behavior | First delivery |
|---|---|---|
| Slime companion | Name, color, expressions, accessories and personality; chosen CLI/model; text and voice interaction | M1 basic customization; expanded cosmetics later |
| Agent control | Start work, stream activity, handle approvals/questions, cancel, resume supported sessions; observe external agents | M1 managed Codex; M3 other agents and observation |
| Usage | Account windows and reset times where available; separate per-run tokens/cost; unknown/stale states | M1 Codex; M3 provider normalization |
| Projects/tasks | Project roots, resources, instructions, task board, priority, assignment, subtasks and run history | M1 task history; M2 project workspace |
| Personal knowledge/memory | Portable OKF vault, scoped retrieval, source-linked answers, editable preferences, corrections and forgetting | M1b core; file ingestion expands in M2 |
| Project-aware sessions | Resolve project aliases/repository bindings, choose exact cwd, start or resume a task-specific Codex session | M1a core |
| GitHub | Repository/issue/Projects v2 sync, issue-to-task dispatch, worktrees, diff/PR review and authorized write-back | M2g, before other connectors |
| Native interaction quality | Original character, interruptible motion, stable focus/display behavior and measured resource use | M1a onward; Q01–Q05 |
| Connected tools | Lark/Slack context, Linear issues, capture into tasks and authorized updates | M4 |
| File feeding | Drop files/folders, chewing progress, supported-format extraction, analysis and cited summaries | M2 text/PDF/images; additional formats later |
| File organization | Preview rename/move/copy plan, validate, apply, recover and conditionally undo | M2 |

## Main journeys

### Give the slime a task

Click the slime or use a configurable shortcut → choose a project/profile → type or speak → review the transcript if speaking → send → watch relevant activity → answer requests → review the result and artifacts. A real task and run are created, even if the entry point feels like chat.

### Resolve something that needs you

The slime shows an attention badge → open the attention inbox → see the agent, project, exact action and reason → approve/decline or answer → see delivery confirmation. Several pending requests stay separate. Expired requests cannot be answered.

### Feed it a folder

Drop a selection → inspect accepted/skipped files → choose summarize, answer a question or propose organization → observe progress → receive outputs with file/page references. Original files stay in place during analysis. Upload/processing boundaries are visible before cloud-backed analysis.

### Organize files

Describe the desired destination and organization → inspect concrete source/destination operations → resolve collisions → apply an authorized plan → inspect the operation journal. Undo is available only for operations whose postconditions still match; arbitrary agent actions are not universally undoable.

### Work from a connected conversation

Choose an authorized message or issue → create/link a task with its source ID → run work in a selected local project → prepare an update → publish when authorized. A remote message is context; it does not automatically authorize access to local folders or execution.

## Product rules

- A task represents an outcome; a run is one attempt; a provider session holds provider-specific conversation continuity.
- Slime appearance and personality are separate from runtime/model configuration.
- Managed and observed sessions are visibly different. Controls reflect actual capabilities.
- The notch shows concise activity and attention. Logs, diffs, boards and long conversations belong in the workspace window.
- Successful execution moves a task to review; task completion follows its acceptance policy.
- Never show missing account data as 0% usage. Every usage figure has a source and timestamp.
- Closing a panel must not stop work. Quitting the app has an explicit active-run policy.
- Character animation follows real state. Chewing ends because ingestion ends, not because an animation timer elapsed.
- Keyboard operation, text labels and reduced-motion behavior are part of the product.

## M1a/M1b release boundaries

M1a includes one locally managed Codex runtime, an explicit project registry, project-aware start/resume, one active run at a time, a queued task list, text, push-to-talk with an editable transcript, original slime customization, attention inbox, history, available usage and interruption recovery. Native responsiveness and motion checks are part of its exit.

M1b adds a lightweight personal/project knowledge vault, reviewed memory changes, scoped retrieval, cited answers and an evaluation corpus. These are required features, not an optional personalization add-on.

Excluded from M1a/M1b: external-session takeover, automatic provider switching, connector sync, file-writing automation, team accounts, cloud task execution, arbitrary third-party skins, always-listening audio and a helper that continues after the app quits.

Missing speech support or unsupported CLI capabilities must be visible, with a usable text-only path. This does not count as completing the voice acceptance criteria on the selected supported configuration.

## Success criteria

1. A user can start a task without opening a terminal and receive its persisted output.
2. Two pending questions/approvals cannot be mixed up or silently lost.
3. A crash or relaunch never silently reruns a non-idempotent task.
4. The app clearly distinguishes running, disconnected, interrupted and completed work.
5. A folder summary identifies which files were actually processed.
6. A file plan cannot overwrite a collision or operate outside its granted roots without being rejected or explicitly resolved.
7. The app remains responsive while a provider streams large output; idle character rendering is measured and tuned before distribution.

Measure task-start latency, time to resolve an attention item, failed request delivery, recovery correctness and idle resource usage during local testing. These are engineering measurements, not a requirement to collect user analytics.


## Newly required journeys

- “Read this file and add the feature to XXX”: resolve XXX, preserve the input file, retrieve scoped project evidence, choose a verified workspace and start/resume the intended Codex task. See [routing](project-routing.md).
- “What did we decide about XXX?”: retrieve current relevant sources and reviewed memory, cite support, distinguish historical decisions and explicitly report missing/conflicting evidence. See [knowledge design](knowledge-memory.md).
- “Check new GitHub issues in XXX and start work on them”: refresh the bound repositories/board, apply the authorized selection once, prepare isolated workspaces and dispatch task-specific sessions. See [GitHub design](github-integration.md).

The product name proposal is **Mochlet**. Character/service quality follows the measurable [native experience contract](native-quality.md). The [acceptance scenarios](acceptance-scenarios.md) define the expanded routing, knowledge and sync checks.
