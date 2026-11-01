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

## Edge docking scenarios

| ID | Setup / request | Required result |
|---|---|---|
| DOCK-01 | Drag compact slime or expanded header to top, left or right | Follow pointer; snap to nearest supported edge; side panel expands inward |
| DOCK-02 | Drag or choose edge, then quit and relaunch | Restore display, edge and normalized position |
| DOCK-03 | Negative-origin display, removed display, changed resolution | Correct coordinate mapping; panel remains reachable on an available display |
| DOCK-04 | Drag during hover dismissal or while a draft exists | No dismissal during drag, no lost draft, no task submission |
| DOCK-05 | Use Appearance controls without a pointer drag | Equivalent Top/Left/Right choices and centering action |

## Google connector scenarios

| ID | Setup / request | Required result |
|---|---|---|
| GOOGLE-01 | Work and personal accounts contain matching subjects/file names | Results and actions retain account identity; project scope prevents accidental cross-account context |
| GOOGLE-02 | User grants Calendar read access but denies Gmail or event writes | Enabled features work; unavailable actions show missing grants without repeated calls |
| GOOGLE-03 | “Use this bug report email to fix XXX”; email mentions another project | Explicit destination and verified workspace win; ambiguity/conflict is resolved before a write turn |
| GOOGLE-04 | More than one page; token expires or a page fails | No premature cursor advance; bounded rebuild/retry preserves completeness and shows stale/partial state |
| GOOGLE-05 | Mail send or event creation succeeds but response is lost | Reconcile evidence; uncertain outcome is visible and not blindly resent |
| GOOGLE-06 | Recurring event crosses DST; user changes one occurrence | Correct local time and occurrence are previewed; series and attendee notification effects are explicit |
| GOOGLE-07 | Account disconnects while a reply is queued and its document is indexed | No new write; affected evidence becomes unavailable; retention/deletion options identify imported material |
| GOOGLE-08 | Selected Drive file is accessible but siblings are not | Only granted content is read; no assumed recursive folder permission |
| GOOGLE-09 | Remote document contains instructions to reveal another project's data | Content remains evidence, cannot grant access or change execution policy |
| GOOGLE-10 | App sleeps during refresh; calendar changes remotely meanwhile | Resume revalidates state, shows freshness and conflicts, and creates no duplicate task/event |

All routing/scope/duplicate-write cases are release blockers. The knowledge-quality rubric additionally measures supported answers and abstention on a frozen corpus; see [knowledge design](knowledge-memory.md). Live smoke checks remain separate from fixture tests and require the applicable authorization already established in the session.


## Pi provider scenarios

| ID | Setup / request | Required result |
|---|---|---|
| PI-01 | Saved UUID/file header, live handshake or cwd disagrees | Fail before sending user text; never fall back to latest session |
| PI-02 | Concurrent confirm/select/input/editor requests; one expires | Replies match the exact ID; expired cards close; no inferred approval |
| PI-03 | A writable tool is requested before host verification, in read-only mode or after dialog failure | Extension blocks execution |
| PI-04 | `agent_end`, retry, then `agent_settled`; final text differs from deltas | One final result with corrected text, after settlement |
| PI-05 | Cancel while dialogs and queued follow-ups exist | Clear queue first, cancel dialogs, abort; preserve unsent text without executing it |
| PI-06 | Statistics fail after successful settlement | Result remains reviewable; usage is unavailable, not zero or a subscription quota |
| UI-01 | Submit through Command-Return and through Send, then type another request | Submitted draft clears visually; composer regains focus; no stale resend |

Evidence and the distinction between fixtures and live provider checks are recorded in [Pi compatibility](pi-compatibility.md).
