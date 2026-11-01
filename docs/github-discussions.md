# Selected GitHub issue discussions

“Read discussion” opens a native reader with a saved snapshot, author identities, comment links and last-fetch time. Refresh explicitly reads only that issue. Repository-wide issue synchronization does not fan out into every discussion. Preparation refreshes the issue and comments, then captures them together in the task source.

The REST reader follows ascending comment IDs across pages of 100, limits a discussion to 500 comments/2 MB and verifies account/repository identity before and after. The issue is read before and after pagination; changed issue metadata, comment-count mismatches, duplicate/nonascending IDs or failed pages reject the new snapshot. SQLite cache replacement is atomic and tied to the current project/account/repository binding. Offline or partial reads leave the previous complete cache intact, with its original timestamp. Rebinding an account hides the old cache.

Task preparation has an additional 100 KB context limit. Oversized discussions remain readable but cannot silently become truncated task inputs. Prepared comments are untrusted references. Dispatch reads the discussion again and compares each retained comment identity, author, body and revision; edited/deleted/new comments block stale work, including edits that do not advance the issue timestamp. Legacy tasks without discussion snapshots retain their earlier issue-body scope until explicitly prepared again.

GitHub REST pagination is not a transaction. These checks detect observed changes and revalidate before dispatch; they cannot claim an atomic remote snapshot or prevent a later remote edit after the final check. No comments or status changes are posted by this workflow.

## Evidence — 2026-11-02

Two new core regressions cover 101-comment paging, unchanged-issue-timestamp comment edits, count mismatches, account switches, durable task snapshots, second-page failure and cache account isolation. `scripts/check.sh` passed: 119 reported tests (three opt-in live skips), native build and native orchestration fixtures. Live discussion API and native reader walkthrough remain unverified.

Sources: [GitHub issue comments REST API](https://docs.github.com/en/rest/issues/comments), verified through Context7. Existing [GitHub CLI component research](component-research.md) remains the transport decision.
