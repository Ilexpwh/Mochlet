# Native project task board

The board groups tasks into To do, In progress, Review and Done. Filters select project, title and priority; cards sort by priority, due date, then creation time. The ordering affects presentation, not the execution queue. Draft creation, edits, comments and status changes never start an agent.

Task details persist priority, due date, description, parent and dependency identities. Comments are local. Details display the latest 100 attempts, the latest output and 200 comments. Agent completion still enters Review; completing the task is a separate user action.

Parents/dependencies must be other tasks in the same project. The combined graph rejects cycles. All dependencies must be completed at enqueue and again at run claim; reopened dependencies block queued work. Blocked queue claims become interrupted without automatic replay.

Edits compare the exact task and details revision transactionally. Queued/running/waiting tasks and unresolved PR publication are protected. Existing sessions, run history and connected/GitHub sources preserve their project and agent. Only unstarted unbound drafts can change destination. Enqueue also compares its captured task snapshot, preventing a delayed context preparation from overwriting an intervening board edit.

## Evidence — 2026-11-01

- Three core tests verify metadata/comment persistence, stale edits, runtime-field protection, graph cycles, cross-project references/moves, dependency reopening and established-session/source routing.
- A native orchestration fixture changes project/provider/title while submission awaits context. The edited draft survives; the stale request reaches neither queue nor runtime.
- Full check passes 71 fixture declarations (two parameterized across six cases), three opt-in live tests skipped, native build and AppModel host.
- Native isolated-data walkthrough creates a draft, edits priority/description/due date, adds a comment, reopens persisted fields and filters the board. [Details evidence](evidence/native-task-details.png), [responsive board after relaunch](evidence/native-task-board.png). No agent or external service was invoked.

Manual card dragging/order, multiple character/profile assignments remain open. Agent assignment is available on unbound drafts. Large-board and VoiceOver evaluation remain release checks; this slice does not mark the entire T14 milestone complete.

## Per-attempt output — 2026-11-01

New attempts save their own assistant text separately from the combined task conversation. Expand an attempt to read its original instructions and reply. The last 1,000,000 UTF-8 bytes are retained without splitting characters; a visible notice identifies truncated replies. Provider snapshots replace the current attempt text. Older attempts remain explicitly unavailable rather than reconstructing an unreliable history.

Output checkpoints occur at completed provider items and terminal transitions. A hard crash can lose the unfinished fragment since the last item checkpoint. Active-run checks, output and combined task text commit together; cancellation wins over a late checkpoint. Optional spoken replies now speak only the current attempt.

Four core fixtures cover separate follow-ups, snapshots, Unicode truncation, reopening, wrong-task guards and concurrent cancellation. Native Codex/Pi orchestration fixtures verify recorded output. The full check passes 107 reported tests (104 fixture declarations plus three opt-in live skips), Debug build and native runtime host. A final accessibility-label rebuild passes. The native walkthrough reopened two fictional attempts and verified distinct prompts/replies through uniquely named disclosure controls. [Native evidence](evidence/native-attempt-output.png).
