# GitHub Projects V2 board reader

GitHub → Projects board binds an explicit user/organization board URL to the selected local project/account/repository. Refresh mirrors a complete bounded snapshot of field definitions, item identities and each item's field-value connection. It includes archived items and distinguishes issues, pull requests, drafts and redacted content. Cached records show their fetch time and remain available after a failed refresh.

Text, number, date, iteration and single-select values are displayed; other complex value types retain identity/type and show an unsupported-value label. There is no claim to mirror nested assignees/labels/reviewers or every Projects field presentation. Status uses an explicitly selected single-select field and option IDs. Field/option changes invalidate the saved mapping until reconfirmed; no status is inferred from a field name, and no remote status is written.

Only open, unarchived issue cards in the bound repository can prepare coding work. Preparation rechecks remote item identity/revision, verifies the local origin, matches the REST issue node ID and captures current comments. The selected board/item identity is stored with the task and checked again before dispatch. Drafts, PRs and cards from another repository do not guess a destination. Explicit preparation from the repository issue replaces any prior board constraint. Preparing a task does not send it.

## Bounds and recovery

- Complete nested paging; repeated cursors, duplicate IDs, missing entries and GraphQL partial errors fail the refresh.
- Up to 150 items including archived cards, 500 fields and 500 values per item; snapshot/response bound 8 MB.
- At most 200 GraphQL requests per refresh. A two-minute budget stops starting new requests; an already-running CLI request has its existing 45-second deadline. No automatic retries or provider fallback.
- Optimistic cache/version checks prevent a late refresh from overwriting a newer board or status mapping. Account/repository changes invalidate cache access and pending saves.
- Board metadata/fields and account/repository identity are checked at both ends. GitHub offers no atomic multi-request snapshot; item preparation and dispatch revalidate the selected item. Membership disappearance is only accepted after complete paging; partial reads never imply deletion.

## Evidence — 2026-11-02

Three core tests cover nested field/item/value pages, issue/PR/draft/other-repository distinctions, archived-item refusal, repeated cursors, partial errors, interrupted nested pages, status-option changes, optimistic mapping, account isolation, durable task board selections and wrong-node refusal. Full core suite/native build/runtime fixtures pass with 122 reported tests (three opt-in live tests skip).

Read-only live schema introspection confirmed Projects content variants, archived-state enum and common field/value interfaces. Attempting the actual queries returned `INSUFFICIENT_SCOPES`: the existing GitHub CLI account lacks `read:project`. No permission was changed. Live board sync and interactive board walkthrough remain unverified; this is not full G03/G05 release acceptance.

Sources verified through Context7: [Projects GraphQL schema](https://docs.github.com/en/graphql/reference/projects), [GitHub CLI API variables](https://cli.github.com/manual/gh_api). Existing [component research](component-research.md) documents why GitHub CLI is the personal-release transport.
