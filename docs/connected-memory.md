# Connected memory and queue validity

New Google/Slack/Lark/Feishu/Linear memory copies preserve account identity, source identity, revision and a content hash in `x-mochlet-connection` frontmatter. This metadata grants no access. The derived SQLite index supports old unbound notes and conservatively excludes malformed bindings. Import/export preserves the binding.

Retrieval checks the connected account, project grant, required read capability and cached source identity. Before analysis or agent dispatch, selected sources are read again through the same account. Failures remove cached source eligibility; a deliberate successful read may restore unchanged evidence. Changed content/revision requires re-ingestion. All remote work finishes before the final local check across the evidence packet.

The Knowledge workspace shows unavailable notes for review, edit/export or forgetting. “Keep independent copy” explains the consequence and creates a new local note; it does not silently strip the original binding. Disconnect preserves historical task output. Prior agent context and old unbound memory copies cannot be retroactively withdrawn.

Queued coding prompts retain separate ID/scope/revision references. Restart retains those references; dispatch validates them before runtime startup and after session preparation. Old queued prompts containing untracked memory context are interrupted on migration and must be resubmitted. Completed run history remains separate.

## Verification — 2026-11-01

- Three core tests cover disconnect/reconnect, removed grants, source drift without a revision bump, retained review copies, malformed portable metadata, explicit independent retention, queue restart, revision changes and forgetting.
- Native AppModel fixtures verify no prompt after deletion, disconnect or deletion during session preparation. A two-source fixture deletes the first note during the second source's delayed check and rejects the whole dispatch.
- `scripts/check.sh`: 68 fixture declarations (two parameterized across six cases), three opt-in live tests skipped; native build and runtime host pass.
- [Native retention walkthrough](evidence/native-connected-memory.png) used isolated disposable data, showed excluded connected evidence, then created a distinct independent copy through the review dialog. No real account or remote inference was used.

Live permission revocation and network timing with configured accounts remain unverified. Retrieval is an on-demand check, not continuous remote revocation monitoring.
