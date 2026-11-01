# Reviewed GitHub publication

An issue task owns an isolated worktree and branch. Finish and commit its changes there through the normal agent approval flow. In GitHub → Review & publish task, select the task, explicit target branch, description and validation evidence. An untested change needs an explicit untested reason. The app does not infer that an agent's success means tests passed.

The preview shows task/issue identity, repository/account, source and target branches, exact head/base commits, commit list and diff. Binary content is represented by Git metadata; it is not visually decoded. Clean workspaces and unchanged reviewed commits are required. Preview generation fetches the target object without checking out files or moving local branches. Previews expire after 15 minutes.

## Delivery and recovery

- **Prepared:** local preview only. Replace freely before submission.
- **Pushing:** branch creation may have happened. Reconciliation reads the exact remote head. Matching SHA advances to ready; absent branch permits a retry using the same immutable SHA and an empty expected-value lease. A different SHA is never overwritten.
- **Ready:** reviewed commit is on GitHub; PR creation has not started. Continue explicitly, or review again while keeping the remote branch. A changed target requires fresh review.
- **Creating:** persisted before the PR POST. A lost response remains unresolved until the marker/branch/repository lookup finds the PR. No blind create retry or discard is offered.
- **Published:** receipt preserves PR number/URL and remote state. Refresh may report merged/closed, draft status or a changed head; local task status remains independent.

The temporary Git transport uses a bare repository and the task's object directory as an alternate. It ignores project/global config, hooks, SSH identities, credential helpers and URL rewrites. One credential captured from `gh auth token` is used for both HTTPS Git and REST requests throughout that operation. Token bytes are not stored in the database, request arguments or a temporary file. API requests reject redirects and responses exceeding 2 MB.

The user explicitly authorizes the reviewed branch and draft PR through the publish button. Source issue links use ordinary references, not automatic closing keywords. No merge, issue close or comment is part of this action. If the user's own PR text includes GitHub closing keywords, GitHub's normal later merge semantics still apply.

## Bounds and remaining gates

This workflow targets github.com, same-repository task branches and SHA-1 repositories. It publishes committed files only, one initial PR per task. Automatic committing, updating an existing PR head, cross-fork PRs, GitHub Enterprise, Projects V2, comments/status write-back and worktree cleanup remain separate work. API rate/permission errors are visible; no automatic retries or identity fallback occur. A creation that cannot be reconciled requires inspection on GitHub.

Seven publication fixtures cover lost responses, duplicate claims, changed workspaces, branch-only recovery, failed preflight reads, target advance/review, credential isolation and actual local-bare Git transfer/lease behavior. Native source fixtures verify changed-project/new-conversation/active-task rejection and changed remote issue rejection before agent dispatch. No live PR write was made. The native setup sheet is verified; populated native review and real account publication remain open gates.

## Primary references

- [GitHub pull requests REST API](https://docs.github.com/en/rest/pulls/pulls): draft creation and head/base-filtered lookup.
- [GitHub CLI auth token](https://cli.github.com/manual/gh_auth_token): capture the active account credential per operation.
- [Git credentials](https://git-scm.com/docs/gitcredentials): ephemeral helper protocol.
- [Git push](https://git-scm.com/docs/git-push): exact refspecs and empty expected-value leases.
