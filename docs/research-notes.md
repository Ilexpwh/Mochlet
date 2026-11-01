# Research notes: memory, project routing and connectors

Research date: 2026-11-01. Sources informed the plan; none of the reference implementations was installed, connected to an account or copied into application code.

## Sources and decisions

| Source | Verified observation | Decision for Slime |
|---|---|---|
| [VikingMem paper](https://arxiv.org/html/2605.29640v1) | Describes event/entity memory, selective extraction and evolving state; links OpenViking as an open-source subset of capabilities | Separate evidence-bearing events from curated preferences/decisions; do not treat this as an OKF specification or inherit benchmark claims |
| [Canonical OKF repository](https://github.com/GoogleCloudPlatform/open-knowledge-format) and [spec](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md) | Current inspected specification is v0.2; format is independent of its reference producer/runtime | Pin a spec revision, implement portable concepts, keep app-specific extensions explicit |
| OpenViking local checkout | Inspectable context organization, scoped retrieval and replacement validation are useful reference patterns | Independent lightweight core; optional external backend later |
| [Codex thread protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs) | Resume identifies a thread and can apply configuration; responses include effective cwd | Persist identity and verify returned destination before dispatch |
| [GitHub Projects API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects) | Project items have separate content and field identities; content includes issues, PRs and drafts | Explicit repository/project/item mapping and complete pagination |
| [GitHub API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api) | Webhooks are preferred where practical; authenticated conditional requests support efficient polling | Manual/awake refresh first, optional relay later, persistent reconciliation state |
| [Symphony](https://github.com/openai/symphony) | Isolated issue execution; published demo uses Linear and identifies the implementation as a preview | Borrow orchestration boundaries, not an assumed GitHub connector |
| [Vibe Kanban](https://github.com/BloopAI/vibe-kanban) | Workspace/agent/review workflow; README currently announces sunsetting | Study the UX and task model; do not add as a runtime dependency |
| [GitHub MCP server](https://github.com/github/github-mcp-server) | Official agent-facing tools cover repositories, issues, Projects and PRs | Optional tools behind explicit capabilities; deterministic sync remains app-owned |

## Local OpenViking evidence

Checkout: `/Users/ilexpoon/Openviking`; commit `24bd450d602599dcf5d1cdb947a62d6700cdec97` as inspected. No `.codegraph/` directory was present. The codebase-memory index was created with `persistence: false`; no repository index artifact was written.

- `README.md`: filesystem context model, directory summary/detail presentation and deployment prerequisites, read directly.
- `LICENSE`: top-level AGPLv3 text, inspected directly. This observation is not a legal conclusion about a particular future distribution.
- `openviking/retrieve/hierarchical_retriever.py:102`: `HierarchicalRetriever.retrieve` source inspected. It applies request context/scopes, chooses keyword or vector search, deduplicates candidates by URI and optionally reranks/filters before returning results.
- `openviking/session/memory/memory_updater.py:1272`: `_invalid_replacement_sources` source inspected. It detects cycles, case-only replacements, missing targets and targets scheduled for deletion.

These two code paths had matching coverage metadata with no recorded issue at index generation `2026-11-01T10:06:40Z`. Coverage is best-effort; this is a bounded source review, not an exhaustive audit. The fast index reported other excluded/partial files, which are not used to support claims here.

## Research limitations

No live Codex session, GitHub account, remote issue write or OpenViking server was exercised. Protocol docs can be ahead of installed versions. GitHub authentication/scopes and OKF schema details must be pinned and checked during their implementation tasks. No comparison here establishes that one system is more accurate than another on the user's own corpus.

## Revision impact

Knowledge/memory and deterministic project routing are now required core features. GitHub is the first coding-work connector, covering repositories and Projects v2. Existing T01–T33 IDs remain stable; R01–R03, K01–K06, G01–G07 and Q01–Q05 originally extended the checklist to 54 tasks. Google U01–U07 now bring it to 61 tasks. Q tasks cover the newly requested native service, interaction and animation quality. The revised dependency order in the build plan supersedes numeric order.

The current naming proposal is Mochlet; naming checks and Apple design references are recorded in the [native quality contract](native-quality.md).

## Google scope extension — 2026-11-01

Required scope now includes multiple Google accounts, Gmail, Calendar and selected Drive/Docs/Sheets/Slides evidence. Context7 was used for current Workspace consent guidance; official Google pages were consulted for desktop authentication, Drive scopes and service synchronization. These sources support design constraints, not implemented or tested capability claims.

- [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app): use a supported installed-app flow with PKCE and validate redirects during the authentication spike.
- [Workspace consent](https://developers.google.com/workspace/guides/configure-oauth-consent): request feature-specific minimum scopes and resolve audience-dependent verification requirements.
- [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth): per-file access is the preferred initial boundary where it supports the feature; broad Drive access is a separate capability decision.
- [Gmail sync](https://developers.google.com/workspace/gmail/api/guides/sync) and [Calendar sync](https://developers.google.com/workspace/calendar/api/guides/sync): preserve service-specific state and recover invalid cursors; do not treat all Google services as one sync protocol.

The [Google design](google-integration.md) defines workflows, data boundaries and later extensions. Authentication, export formats, write preconditions and service capabilities must be verified against current docs in U01–U07. No Google account was connected during this planning update.
