# The knowledge base

Mochlet keeps what you drop on it in `~/Mochlet/Knowledge/`, an [OKF](https://okf.md) v0.2 Markdown
bundle you can open in Obsidian or any editor. The model is Karpathy's "LLM wiki": immutable sources,
wiki pages the app maintains over them, and a schema file that tells every agent the rules.

## Layout

```
~/Mochlet/Knowledge/
  SCHEMA.md  CLAUDE.md  AGENTS.md    the schema; the copies let Claude Code / Codex opened in the folder follow it
  index.md  log.md                   generated: what is here (by type, with one-liners) and what Mochlet did, newest first
  inbox/        <slug>.md (type: report)   one page per source you dropped, with references/<sha12>-<name> next to it
  entities/     people, orgs, products, models, papers (type: entity)   — written by the integrator (M7)
  concepts/     cross-source pages (type: concept | comparison)         — written by the integrator (M7)
  syntheses/    answers you filed ("File this answer"), question as title, sources = citations
  meta/         lint-YYYY-MM-DD.md (type: lint)
  projects/     <project-slug>/{index.md, <slug>.md, references/}   reports filed to a project
  meetings/ notes/ signals/ memories/     later milestones write here
```

Every directory also gets `.abstract.md` (≤ 256 chars) and `.overview.md` (≤ 4000 chars) sidecars,
generated bottom-up, so an agent can skim a folder without opening every page.

Rules Mochlet follows:

- Pages carry YAML frontmatter with a required `type`; `title, description, resource, tags, status,
  stale_after, generated{by,at}, verified[{by,at}], sources[]` are the OKF trust fields; `mochlet:` is
  the app's namespaced block. Unknown keys round-trip untouched.
- `references/` is never edited. Text and Markdown sources are indexed in full (`type: reference`),
  ranked slightly below the page about them, and never listed in `index.md`.
- A page you wrote or verified (`verified[].by: human:…`, no generated stamp, or a body changed since
  `generated.at`) is never overwritten; Mochlet adds a `## Proposed update (date)` block instead.
- `index.md` and `log.md` are regenerated; edits there are overwritten. Log lines are grep-able:
  `- 09:41 ingest | <title> → <path>`, `- 10:02 query | <question> → syntheses/<slug>.md`, `- lint | …`.
- `[[Page]]`, `[[Page|alias]]`, `[[Page#Heading]]` and `![[embed]]` resolve like Obsidian (by file name,
  title or slug); links are re-resolved when a target appears or disappears.

## Search

`index.sqlite` (support folder) holds pages, chunks (≈700 tokens, 1-block overlap, heading paths, line
ranges), an FTS5 table over pre-segmented tokens (Chinese character bigrams + dictionary words, lowercase
Latin words) and vectors.

- `find`: BM25 top 50 ∪ vector top 50 → reciprocal-rank fusion → priors (deprecated ×0.5, stale ×0.8,
  project ×1.2, pages over raw sources) → best 2 passages per page → top k. No model involved, ≈ms.
- Vectors come from Apple's on-device `NLContextualEmbedding` (512-d, per script: Latin, Chinese,
  Japanese, Korean), computed in the background; the first run downloads the language model. Switch it
  off in Settings → Knowledge if you prefer keyword-only search.
- `search` (the card's Ask): lexical variants of the question → union of finds → a prompt with numbered
  passages → the chat backend streams an answer with `[n]` citations → chips open the page at the line
  (Cursor / VS Code when running, otherwise the default editor) or the source URL.
- "File this answer" writes `syntheses/<slug>.md` with the citations as `sources[]` and adds a
  `## Mentioned in` backlink to each cited page Mochlet owns.

## Lint

The Lint button (and `mochlet-cli lint`) writes `meta/lint-<date>.md` listing orphans, broken links,
entities mentioned in several pages without their own page, reports never integrated, sources without a
report, stale pages, and contradictions once the integrator runs. The slime looks annoyed when a lint
finds contradictions.

## Coding agents: MCP

While Mochlet runs it listens on `127.0.0.1:<port>` (`POST /mcp`, bearer token, JSON-RPC 2.0, Streamable
HTTP without SSE). `mcp.json` in the support folder names the port and token; `mochlet-mcp` is a stdio
shim that forwards each line, so:

```sh
claude mcp add mochlet -- "$HOME/Library/Application Support/Mochlet/bin/mochlet-mcp"
codex  mcp add mochlet -- "$HOME/Library/Application Support/Mochlet/bin/mochlet-mcp"
```

Tools: `find`, `search`, `read`, `list`, `tree`, `grep`, `add_resource` (files, links or text, exactly
like a drop), `projects`, `signals_latest`. When the app is not running the shim answers every request
with a JSON-RPC error so the agent can tell you.

## Command line

`Mochlet.app/Contents/Helpers/mochlet-cli` works on the bundle without the app (the two share the index
through SQLite WAL): `bootstrap`, `reindex [--force]`, `find <query> [-k 8] [--type report]`,
`grep <text>`, `lint`, `ingest <file.md|.txt> [--project slug]`, `embed`. `--root <folder>` or
`MOCHLET_KNOWLEDGE_ROOT` point it at another bundle (the index then lives at `<root>/.index.sqlite`).
`scripts/smoke-ingest.sh` runs the whole chain against the fixtures.

## What arrives next

M7 adds the extractors (PDF with OCR, Office, PPTX, images, audio/video), the web reader, the report
analyzer (summary, key points, entities, action items via the brain), the integrator that revises entity
and concept pages after each ingest, and the project router. Until then a non-text drop is mirrored with
a stub report so nothing is lost, and a link is filed as a draft report that the reader will rewrite.
