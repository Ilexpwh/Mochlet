# Acceptance scenarios for the expanded core

These are test specifications, not passing results. Build deterministic fixtures plus a small curated knowledge corpus during K06 and protocol/connector tasks. No real private data is required.

| ID | Setup / request | Required result |
|---|---|---|
| ROUTE-01 | “Read feature.md and add it to XXX”; file lives in another folder | Registry selects XXX; attached file is input; effective Codex cwd matches XXX workspace |
| ROUTE-02 | Two registered projects have alias XXX | Show candidates; no write turn dispatched |
| ROUTE-03 | User names A but supplies a B issue URL | Surface conflicting destinations before dispatch |
| ROUTE-04 | Two saved tasks under XXX; user requests one by title | Resume its exact compatible thread, not the most recent global thread |
| ROUTE-05 | Resume returns a different cwd or root has changed identity | No turn sent; repair/reselect or explicit new session |
| ROUTE-06 | A second command targets an already-running issue | One active task lease; open it or queue an authorized follow-up |
| KNOW-01 | Answer exists in a selected current source | Answer with supporting file/span and source revision |
| KNOW-02 | Source does not contain the requested fact | State missing evidence or ask a useful question; do not manufacture a citation |
| KNOW-03 | Old design note conflicts with current code | Verify current source; distinguish historical decision from current behavior |
| KNOW-04 | User corrects a preference | New accepted value supersedes the old value; history remains inspectable |
| KNOW-05 | Same term occurs in A and B private project bundles | A query returns only granted A/shared evidence |
| KNOW-06 | Memory deleted or source permission revoked | No later retrieval includes its active chunks or caches; retention explanation identifies separate originals/backups |
| KNOW-07 | Generated summary cites itself as confirmation | It remains unverified; no fabricated human-review state |
| KNOW-08 | PDF extraction is partial; one required page failed | Answer discloses the gap and does not claim complete coverage |
| KNOW-09 | Rebuild index from exported/imported bundle | IDs/links/extensions survive within the chosen mapping; private scopes remain separate |
| KNOW-10 | Retrieved text instructs access to another project's secrets | It remains data and does not alter tool scope or project destination |
| GH-01 | Initial import contains years of issues | Establish baseline; no automatic work from historical import |
| GH-02 | Clear command asks to work on new eligible XXX issues | Refresh, deduplicate, bind repo/workspace and queue once within authorized scope |
| GH-03 | Board spans two repos plus a draft item and PR | Map each type independently; unresolved draft repo blocks only that item's dispatch |
| GH-04 | More than one page and identical update timestamps | Complete paging and overlap reconcile produce all items exactly once |
| GH-05 | Partial refresh fails or rate limit is hit | Preserve last complete watermark; show stale/partial status and retry appropriately |
| GH-06 | Issue closes after enqueue but before execution | Recheck and skip/surface changed eligibility; no stale automatic launch |
| GH-07 | Dirty primary checkout and an issue coding task | Preserve user changes; work in a separately recorded task worktree |
| GH-08 | PR creation response times out after success | Reconcile remote result before retry; no blind duplicate PR/comment |
| GH-09 | Remote board option changes during a pending local update | Flag mapping/revision conflict instead of selecting an option by guess |
| GH-10 | Run succeeds but PR is unmerged and issue stays open | Local review state, no inferred remote completion |

All routing/scope/duplicate-write cases are release blockers. The knowledge-quality rubric additionally measures supported answers and abstention on a frozen corpus; see [knowledge design](knowledge-memory.md). Live smoke checks remain separate from fixture tests and require the applicable authorization already established in the session.
