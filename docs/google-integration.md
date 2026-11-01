# Google integrations

Status: required product scope, planned on 2026-11-01; no Google account is connected and no connector is implemented. Delivery: M4g, after the shared connector foundation and initial Slack/Lark/Linear workflows. Gmail and Calendar are required; Drive and selected Google Docs, Sheets and Slides provide the first knowledge-source extension. Additional Google services remain follow-on work.

## What Mochlet should do

| Service | First supported workflows | Boundary |
|---|---|---|
| Gmail | Search authorized mail, summarize selected threads, extract action items, link mail to a project task, prepare drafts and send/reply when authorized | Reading a message does not mark it read or authorize a reply; mailbox cleanup is later work |
| Calendar | Show agenda, inspect availability, prepare meeting briefs, create/reschedule/cancel authorized events | Respect selected calendars, time zones, recurrence and attendee notification choices |
| Drive | Find and select accessible files, attach references to projects, ingest supported content into scoped knowledge | Selected files first; continuous whole-Drive indexing and remote file organization are later work |
| Docs / Sheets / Slides | Read supported selected content through appropriate API/export paths; cite document sections, sheet ranges or slide numbers where available | Extraction fidelity and unsupported content are visible; native document editing is later work |

Example commands:

- “Summarize today's unread mail from my work account and show what needs my attention.”
- “Use this bug report email to start a Codex task in XXX.”
- “Find a free hour tomorrow and schedule time to fix issue 42.”
- “Prepare me for the next meeting using its linked documents and relevant project notes.”
- “Read this Google Doc and add its requirements to my XXX project.”
- “Draft a reply with the result of this task.”

These commands use the same voice/text entry point, project resolver, task model and attention inbox as local files and GitHub. A selected document or sender is context, not sufficient proof of a project destination. Ambiguous bindings show project/account choices before dispatch. Drafting and scheduling do not silently execute unrelated coding work.

## Accounts and authorization

Support multiple personal and Google Workspace accounts with a visible account badge on search results, evidence and every outbound action. Bind projects to explicit connection IDs and optional calendar/file selections. Remote object keys include connection, service, collection and object IDs; email addresses and display names are labels, not sole identity keys.

Use a supported desktop OAuth flow with browser consent, PKCE and state validation, and store refresh credentials in Keychain. Choose and validate the redirect mechanism against Google's current desktop guidance during U01. Tokens never enter model prompts, logs, the repository or exported knowledge. [Desktop OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).

Request only scopes needed by the enabled feature, and show actual grants when consent is partial. Introduce write permissions when the user enables write features. Google scope consent and Mochlet's project/data selections are distinct: a local Gmail label filter does not narrow a mailbox-wide OAuth grant. Evaluate verification requirements for the intended audience before distribution; Workspace administrator restrictions or revoked grants must leave an actionable unavailable state. [Consent and scope guidance](https://developers.google.com/workspace/guides/configure-oauth-consent).

Prefer per-file Drive access where it supports the selection workflow. Do not imply that selecting a folder grants every descendant through `drive.file`; validate actual per-file access and request broader access only for a feature that needs it. [Drive scope guidance](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

## Retrieval and memory

App-owned connectors fetch bounded context through the scoped tool gateway. A selected CLI receives only the evidence needed for its authorized run. Before first model processing, explain that cloud mail/documents may be sent to the selected provider; local orchestration does not imply local inference.

Keep temporary service caches separate from durable OKF memory. Merely connecting an inbox must not import it into personal memory. Explicit ingestion records source account, remote ID, locator, revision or content hash, retrieval time and project/personal scope. Refresh or label stale evidence before answering current-state questions. Summaries retain source links and extraction gaps, and user-approved memory remains correctable and removable.

Disconnect stops new calls, cancels or blocks queued actions, and invalidates active retrieval/cache access for that connection. Offer deletion of imported content and derived indexes under the existing forgetting policy; show retained summaries and originals separately. Do not imply that disconnect retracts data already sent to an AI provider. Remote text remains untrusted context and cannot change project routing or authorize tool actions.

## Writes and recovery

Reuse the shared outbound action ledger. Every action records account, target, exact content, local task, remote revision where available, and authorization. Gmail previews include sender, To/Cc/Bcc, reply thread and attachments. Calendar previews include calendar, local time and time zone, attendees, notification behavior, and whether a change affects one occurrence or a series. Authorization can be given in the current request or a specifically configured workflow; do not ask again when it already covers the concrete action.

A prepared local email draft is not yet a Gmail draft. Saving remotely and sending are separate actions with separate results. A timeout after sending is an uncertain outcome, not a reason to send again. Reconcile using supported remote evidence; if certainty is unavailable, surface the uncertainty for resolution. Do not claim universal exactly-once delivery. Event updates similarly check supported revision preconditions and surface conflicts rather than silently overwriting newer changes.

## Refresh and service lifetime

Start with on-demand and bounded refresh while Mochlet runs; pause/back off on errors and show last successful refresh. No always-on cloud relay or mailbox monitor is required. Queued writes are revalidated after sleep, reauthentication or relaunch.

Keep independent cursors and query configuration for each account/service/collection. Gmail partial refresh uses history and falls back to a bounded full synchronization when history is unavailable. Calendar persists its sync token only after all pages complete and rebuilds the affected mirror when the token is invalid. [Gmail synchronization](https://developers.google.com/workspace/gmail/api/guides/sync), [Calendar synchronization](https://developers.google.com/workspace/calendar/api/guides/sync).

Drive first refreshes selected objects on demand. Continuous folder sync, push notifications and background operation after app quit need separate tasks and deployment decisions. Notifications must distinguish a newly fetched item from a newly actionable task; refresh alone never launches an agent or sends a reply.

## Delivery and verification

U01–U07 in [the checklist](../tasks/todo.md) cover accounts, mail reading, agenda, document ingestion, email writes, calendar writes and recovery. Use synthetic accounts/messages/events in fixtures; live checks use explicitly selected test resources and authorized writes. [Acceptance scenarios](acceptance-scenarios.md) cover account isolation, revoked grants, sync recovery, time zones, duplicate writes and source-driven project dispatch.

Recommended follow-on: an on-demand daily briefing combining agenda, selected important mail, GitHub issues and agent blockers, with source links and explicit account scope. Calendar focus blocks for coding tasks are useful next; autonomous mailbox cleanup, automatic meeting recording and broad contact import remain outside the initial Google scope.
