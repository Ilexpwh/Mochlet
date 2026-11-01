# Stored Codex sessions

The native Codex sessions workspace lists CLI, editor, exec and app-server sessions for the selected project's exact canonical directory. It uses Codex 0.155.1 `thread/list`, `thread/read` and `thread/turns/list`; it never starts or resumes a turn while browsing. History is bounded, paginated and optionally refreshed every ten seconds. Successful empty refreshes show their count and timestamp.

The reader's runtime status is not proof of another client's process liveness. External approvals/questions remain in their original client. To prepare a resume, stop the external client and acknowledge that in Mochlet. Metadata is re-read, the exact thread ID/directory is imported transactionally and the Companion opens with no new message sent. Existing imports are reused. Active/queued/waiting tasks, stale observations, wrong directories and conflicting ownership fail closed. A concurrent composer edit is preserved.

## Evidence — 2026-11-01

- Installed CLI schema generated locally from 0.155.1; official [app-server contract](https://learn.chatgpt.com/docs/app-server) cross-checked.
- Three new core fixtures cover project scoping, duplicate/wrong IDs, cursor loops, bounded history and idempotent import with no queued execution. Full check: 65 fixture declarations, three opt-in live tests skipped, native build and AppModel regression host pass.
- Read-only real app-server probe listed one parent-project session and read its metadata/one history page. No resume/start or inference occurred.
- Native browser successfully refreshed the source project's empty session list; [screenshot](evidence/native-codex-sessions.png). Populated native browsing/import and concurrent external-client behavior still need a walkthrough. External process monitoring/control is not claimed.
