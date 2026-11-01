# Project-aware commands and Codex continuity

Status: core requirement. Project resolution happens before retrieval, session selection and execution.

## The project registry

Each project has a stable ID, display name, user-managed aliases, one or more verified local roots, repository identities, a preferred working root, default agent/model, knowledge scope and execution policy. GitHub repository IDs/host and optional Projects v2 IDs are bindings, not project names. A GitHub board may contain several repositories.

Store verified checkout identity, canonical path/bookmark, allowed subdirectories, optional monorepo component and root health. If a root moves, reconnect it explicitly after identity checks. Do not silently substitute the process home directory or another similarly named repository.

Application scope checks are not an OS sandbox: a CLI's actual permissions must be configured separately. The registry determines where Slime intends to run work; the provider's sandbox/tool policy determines what the process can access.

## Resolution rules

Use these in order, while checking for conflicts:

1. Explicit project selection or stable project ID supplied by the user.
2. An exact GitHub issue/repository URL mapped to a registered project.
3. A unique exact project name or user-defined alias in the instruction.
4. The current task's existing project or an explicitly selected active workspace when the user says “this project”.
5. Model-assisted candidate suggestions, shown for disambiguation; they cannot dispatch a write task on their own.

An explicit project and an issue mapped to a different project create a conflict to resolve, not a precedence trick. Duplicate aliases, an unmapped repository, a multi-repo draft item or missing local root require a short selection before execution. A dropped file describes task input and does not change the target project merely because it lives elsewhere.

Show a persistent destination strip: **Project / repository / working folder or worktree / branch / agent / new or resumed session**. The dispatcher validates this record and the provider's returned working directory. A change to the selected UI project cannot retarget an already-running task.

## Example: “Read this file and add the feature to XXX”

1. Resolve `XXX` through the registry; bind the command to its stable project ID.
2. Inventory and read the explicitly supplied file; preserve its source reference and relevant requirements.
3. Retrieve current XXX project knowledge and applicable reviewed preferences.
4. Create a task and choose the verified checkout or isolated worktree. Inspect dirty state without discarding it.
5. Select a compatible session for this task, or create one. A different completed task in the same project is not automatically the right conversation to resume.
6. Start/continue Codex with the exact working directory and requirement/evidence packet. Verify returned session metadata before starting the turn.
7. Stream progress, route questions, capture code changes and test results, then move the task to review. Propose useful memory updates after the outcome is known.

## Session registry

Persist `projectId`, `taskId`, `runId`, provider, account/config identity, provider thread ID, checkout/worktree ID, effective cwd, branch/base commit, status and last activity. A project can have many task-specific sessions. A task can have multiple attempts or handoffs.

| Situation | Behavior |
|---|---|
| “Start a new session for XXX” | Create a new provider thread with verified XXX cwd; preserve previous history |
| “Resume the login bug task in XXX” | Resolve the task and compatible persisted thread; resume by exact ID |
| “Resume XXX” with one eligible candidate | Resume it and show which task/session was chosen |
| Several plausible candidates | Present concise task/session choices; do not choose the newest globally |
| Task already running | Open its live view; steer only if requested/supported, otherwise queue a follow-up |
| Missing/corrupt/unsupported session | Report continuity loss; offer a new thread with a visible handoff summary |
| Existing external terminal session | Import/attach only through supported mechanisms after verifying ownership and root; never assume takeover |
| Different provider/account/root | Do not reuse blindly; create an explicit handoff or request the missing choice |

Codex's structured interface supports starting a thread with a working directory and resuming a specific thread with configuration overrides. The effective returned cwd must be checked; active-thread override behavior can differ from cold resume. Slime will use the installed-version contract and refuse silent cross-project retargeting. [Protocol source](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs).

## Workspaces and isolation

For GitHub issue work, default to a per-task branch/worktree in a managed location. Record the base commit and repo identity. This preserves the user's original dirty checkout; it is not a security boundary. Do not run repository setup hooks automatically merely because an issue asks for them.

For non-Git folders, use an explicitly granted working root and serialize conflicting writes. When a task finishes, retain its workspace until results are accepted or it is deliberately archived. Recovery revalidates the workspace before resuming.

## Acceptance scenarios

- Two projects both contain `README.md`; dropping one while naming the other does not switch cwd.
- Two projects share an alias; no write session launches until the ambiguity is resolved.
- An issue URL points to project B while the user names A; the conflict is visible.
- A resumed thread returns a different cwd; no turn is sent there.
- A repository is moved, renamed, forked or checked out twice; stable identity and selected workspace remain explicit.
- Two “start work” commands for the same active task open/queue once, not spawn duplicate runners.
- Personal knowledge retrieval and project B's private documents never leak into project A without an explicit shared-scope grant.

Tasks: R01–R03 and G04–G05 in [the checklist](../tasks/todo.md).
