# Personal knowledge and memory

Status: required product capability, added 2026-11-01. This is an implementation design, not a running memory service or a guarantee of answer accuracy.

## Decision

Build a local, lightweight knowledge layer with portable OKF documents and a rebuildable SQLite search index. Start with lexical retrieval, explicit scope filters and source expansion; add local embeddings only if evaluation shows a meaningful improvement. No separate vector database, Python server or mandatory embedding API is required for the initial implementation.

The user's paper is **VikingMem**, which describes evolving event/entity memory rather than the OKF format. We borrow its distinction between recorded experiences and maintained knowledge, without claiming to reproduce its architecture or reported benchmark results. [Paper](https://arxiv.org/html/2605.29640v1).

**Format baseline:** target OKF v0.2, pinned to a reviewed specification revision during K01. It uses Markdown/YAML concepts; `type` is required. Optional provenance, generation/verification and lifecycle metadata support source tracking. Directory indexes and ordinary links support navigation. Preserve unknown fields when importing/exporting. Application policy and storage are separate from format conformance. [Canonical specification](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md).

The rest of this document defines **Slime product behavior**, not additional requirements imposed by OKF.

## Four distinct kinds of context

| Context | Contents | Update policy |
|---|---|---|
| Personal knowledge | User-selected documents, reference material and curated explanations | Import or deliberate user edits; source-linked extraction |
| Personal memory | Preferences and explicitly remembered facts | Direct “remember this” writes immediately; inferred candidates enter review |
| Project knowledge/memory | Architecture, decisions, conventions, requirements and validated run lessons | Bound to project ID; review suggested changes and retain provenance |
| Session/task state | Current brief, execution progress, open questions, artifacts and continuation summary | Runtime-owned records; not all conversation content becomes long-term memory |

User preferences influence presentation and workflow; they do not establish facts about a repository. A generated summary is derivative evidence. Current source files and live issue state outrank stale summaries for questions about current implementation or work status.

## Storage and portability

Proposed private application-support layout:

```text
Slime/
  app.sqlite                       # tasks, projects, sessions, source identities
  knowledge/
    personal/                      # one private OKF bundle
    shared/                        # deliberately shared cross-project concepts
    projects/<project-id>/         # one independent bundle per project
  sources/<source-id>/              # selected copies/extracted derivatives
  cache/knowledge-index.sqlite     # FTS + source/chunk/revision tables
  history/                         # bounded local revision journal
```

Project repositories do not receive personal memory by default. Knowledge export excludes credentials and is opt-in per scope. An exported bundle is readable without Slime; search indexes can be rebuilt from authorized bundles and source manifests. A source may be linked in place or copied into the vault; record which policy applies.

Use a Slime-specific metadata namespace such as `x-slime` for stable memory IDs, scope, project ID, source hash, source revision, sensitivity and supersession links. These are app extensions, not purported OKF standard fields. Stable application IDs survive a document rename; format concept paths remain the interoperable document identity. The database maps both.

## Write lifecycle

1. Record the input source with an immutable local ID, content hash, capture time and applicable Git commit/remote revision.
2. Extract only relevant facts or decisions into candidates. Link each candidate to the exact supporting span, page, message or run event.
3. Validate document shape, links and scope; reject attempts to write outside the granted vault roots.
4. A direct user instruction to remember/update something is sufficient authorization. Inferred memories remain proposed until accepted or covered by a configured policy.
5. Distinguish new information, corroboration, correction and contradiction. Never silently merge incompatible statements. Superseded facts leave a navigable history.
6. Commit file changes atomically and update the derived index through a recovery journal. If indexing fails, the durable document remains authoritative and the UI reports pending indexing.

Generation and verification are separate actions. Repeating a model-generated claim does not make it verified. A memory may record that the user prefers a setting without asserting that the setting is objectively best.

## Retrieval and grounded answers

1. **Resolve project and intent first.** Search only personal/shared scopes the user permits plus the selected project's scope. For coding tasks, include only directly relevant personal preferences, not the whole personal vault.
2. **Match precisely before expanding.** Start with project/issue IDs, aliases and terms; use SQLite FTS ranking within allowed scopes. Indexed access filters apply before candidate selection and again before returning context.
3. **Read progressively.** Consult directory descriptions, then candidate summaries, then original supporting passages. Keep a bounded context budget and a trace of which evidence was included or excluded.
4. **Check revision and freshness.** A changed file hash or issue revision invalidates dependent summaries for current-state claims. Refresh the relevant source or label the historical date. Detect contradictory active memories.
5. **Compose an evidence packet.** Include question, resolved project, source excerpts with stable locators, relevant reviewed memories and unresolved conflicts. Pass it to the selected CLI as delimited context, separate from user instructions.
6. **Answer with support.** Link material factual claims to retrievable source spans. Explain uncertainty, cite conflicting evidence or say the available material does not establish an answer. Do not substitute an invented confidence percentage for evidence.
7. **Validate the output.** Resolve citation IDs and verify cited text exists; use evaluation to check whether evidence actually supports the claim. A valid citation link alone does not prove correctness.

For a feature request, the packet includes the requirement file and project decisions, but Codex must still inspect the current checkout and run appropriate checks. Memory is a starting point, not proof of current code behavior.

## Agent access

The app owns knowledge writes. Provide the same read operations through a small runtime tool interface: search scoped knowledge, read a concept/source span and list relevant project resources. Later expose these through a local MCP adapter where useful; the MVP can inject a bounded evidence packet without requiring a new server.

An agent may propose a memory update, but cannot silently broaden its scope or mark its own output human-reviewed. Browser/document/issue text remains untrusted content and cannot grant tools, select another project or alter access policy.

## User controls

- Browse, search, pin, edit, correct, export or forget a memory; show where it came from and where it was used.
- Enable/disable memory use for a run and select permitted scopes.
- Show suggested memories separately from accepted facts/preferences.
- Explain “why did you use this?” with the retrieval trace and source revision.
- Forget removes active retrieval copies, derived chunks and embedding caches. Original chat transcripts, source files and exported backups have separate retention controls; state what remains. Imported revoked sources must be excluded immediately even before physical cleanup finishes.
- A renamed/missing source is reported; it is not quietly reattached to another file with the same name.

## OpenViking lessons and bounded reuse

Use its inspectable context organization and summary/detail separation as design references. The inspected `HierarchicalRetriever.retrieve` currently performs a scoped candidate search with optional reranking, deduplication and thresholds; its class name is not evidence of a recursive tree-walk algorithm. Its memory updater checks for invalid/cyclic replacement targets. These are useful patterns for a much smaller implementation.

The local checkout's top-level license is AGPLv3, and its README describes a server plus model dependencies. Default to an independent lightweight implementation. An optional OpenViking backend can be evaluated later; do not bundle its code or assume deployment/redistribution terms without a separate decision. Exact evidence is in [research notes](research-notes.md).

## Accuracy evaluation

Maintain a small checked-in fixture corpus with answerable, unanswerable, conflicting, stale and cross-project questions. Proposed initial gate: all routing/access/deletion isolation cases pass; at least 90% of factual fixture answers have supporting evidence; all intentionally unanswerable cases abstain or ask for missing evidence. Record numerator/denominator and human rubric; do not advertise this as a universal accuracy rate.

Measure source retrieval recall, citation support, outdated-source use, contradiction handling and index/retrieval latency separately from model answer quality. Compare lexical-only retrieval with an embedding candidate on the same frozen corpus before adding that dependency. Include English/Chinese or the user's actual languages once confirmed.

Implementation tasks: K01–K06 in [the checklist](../tasks/todo.md).
