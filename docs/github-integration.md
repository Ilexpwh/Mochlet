# GitHub project and issue workflows

Status: required integration. Deliver GitHub before the optional order of Slack/Lark/Linear because it directly feeds the requested coding workflow.

## Three different sync operations

1. **Work metadata:** repositories, issues, comments, labels, pull requests and GitHub Projects v2 items/fields mirrored into Slime.
2. **Source code:** explicitly chosen checkout/clone, fetch and task worktree preparation. Metadata refresh never silently pulls, resets or changes the user's working tree.
3. **Knowledge:** selected source/issue revisions compiled into project-scoped knowledge with provenance and invalidation. A synced issue remains a report, not a verified statement about code.

## Bindings and identity

Connect a GitHub account/host, select allowed repositories and optionally a Projects v2 board, then map them to a local Slime project. Store immutable node IDs plus human-readable owner/name/number and URLs. Repository names alone are insufficient; a transfer or rename must not create duplicate projects.

Keep repository issues separate from Projects v2 items. A board can include issues, pull requests and draft items; an issue can appear on multiple boards. Store item IDs and field/option IDs independently from the underlying issue. A draft without a repository requires an explicit default binding or a user choice before coding. These distinctions follow the [Projects API documentation](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects).

## Authentication and tools

Design for a permission-scoped GitHub connection. Evaluate a GitHub App authorization flow for a distributable app; a personal prototype may invoke an already-authorized `gh` installation through a narrow adapter. Do not embed a GitHub App private key/client secret in the desktop binary or silently extract another tool's token. Confirm permissions for repository versus organization/user Projects during G01.

The app's deterministic sync service owns cursors, retries, identity and conflict policy. The official [GitHub MCP server](https://github.com/github/github-mcp-server) is a useful optional agent-tool surface for repository, issue, project and PR actions; it does not replace our persistent synchronization or authorization ledger. Broker agent writes through the same policy/ledger so direct tools cannot bypass it.

## Initial synchronization

- Sync on explicit refresh, project open when stale, and optional bounded polling while the Mac is awake. Later, add webhook delivery through an authenticated relay if always-on event intake is needed.
- Page through issues/comments and all requested Projects items/field-value connections. Do not treat a first page as a complete board. Filter PR records from issue endpoints where applicable.
- Store provider object IDs, remote revision/update time, last successful sync, conditional-request metadata and per-resource cursors. The first sync establishes a baseline; it does not treat every historical issue as newly authorized work.
- For updated-since scans, overlap the time window and deduplicate by stable ID/revision. Periodically reconcile membership, closures and permission changes. Do not advance the complete-sync watermark after a partial failure.
- Treat webhook deliveries as invalidation signals to reconcile, with delivery-ID deduplication. Deleted/inaccessible resources and archived project items need explicit states; a missing item in one partial page proves nothing.
- Surface offline/stale/rate-limited status. Honor server retry instructions and use conditional reads where supported. GitHub recommends webhooks where practical and efficient conditional polling when they are unavailable. [API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api).

## “Check new issues in XXX and start work on them”

1. Resolve XXX to a registered project and selected repository/board bindings.
2. Refresh authorized issue data and determine what is new since the last successful relevant checkpoint; on first use, show the baseline semantics.
3. Interpret the user's current instruction as authorization to queue the matching local work. Apply configured labels/assignees/state filters and show the resulting queue. Ambiguous scope or repo mapping needs clarification; a clear already-authorized batch does not need repeated permission prompts.
4. Create linked tasks once, keyed by provider/host/repository/issue identity. Record the issue revision as the input snapshot. Avoid an active duplicate with a transactional claim/lease and local idempotency key.
5. Recheck eligibility before execution; skip closed/withdrawn items and surface already-assigned/active work according to project policy. Queue one active run initially; do not claim distributed exclusivity from a local lease.
6. Prepare a verified per-task workspace; assemble the latest issue, comments, attachments and scoped project evidence.
7. Start or resume that task's Codex thread with the workspace cwd. Collect reproduction evidence, changes and relevant tests.
8. Present a diff and result. Create a branch push/draft PR or send an update only when that outbound action is authorized. Link task, issue, branch, run and PR.

Checking or synchronizing issues by itself never authorizes execution. A future persistent “work on new issues” rule needs explicit scope, eligibility, concurrency and spending limits; this planning step creates no such automation.

## Status and write-back policy

| Local state | Default GitHub behavior |
|---|---|
| Imported / queued | Local state only; do not claim the issue remotely |
| Working | Optional configured board-status update or comment within granted authority |
| Needs input | Attention inbox; optionally prepare an issue question |
| Run succeeded | Review locally; do not auto-close the issue |
| Draft PR created | Save stable PR identity and link to the issue/task |
| PR merged or issue closed remotely | Reconcile against actual remote events/state, then update local completion according to project policy |

Keep issue open/closed state separate from arbitrary board status options. Map board field IDs and option IDs explicitly; missing/renamed fields pause that mapping rather than guessing. Remote fields are authoritative unless a user-authorized edit has a recorded expected revision. On conflicting local/remote edits, show both and retain the pending action.

For writes, maintain an outbound ledger with destination/account, operation fingerprint, expected remote state and response IDs. Do not assume every GitHub mutation accepts an idempotency key. After a timeout, read back identifiable state before retrying; if duplicate prevention cannot be established, show uncertain delivery instead of posting again blindly.

## Reference implementations

- **Symphony:** use its issue-to-isolated-work orchestration as a design reference. Its published demo uses Linear; it is not evidence of a drop-in GitHub sync backend. [Repository](https://github.com/openai/symphony).
- **Vibe Kanban:** useful examples of agent workspaces, review and PR-oriented workflow. Its current README announces sunsetting, so treat it as a reference rather than a new foundational runtime dependency. [Repository](https://github.com/BloopAI/vibe-kanban).
- **GitHub MCP server:** official tool surface to evaluate behind the app's capability and authorization boundaries. [Repository](https://github.com/github/github-mcp-server).

## Required failure checks

Pagination beyond one page; duplicate events; timestamp ties; refresh after sleep; rate limiting; token revocation; issue transfer/rename; PR records mixed with issues; multi-repo boards; draft items; deleted status options; out-of-order updates; dirty checkouts; missing worktrees; issue closure before dispatch; duplicate user commands; uncertain outbound delivery; an issue body containing instructions to access another project.

Tasks: G01–G07 in [the checklist](../tasks/todo.md). Live account access or outbound writes have not been performed by this planning update.
