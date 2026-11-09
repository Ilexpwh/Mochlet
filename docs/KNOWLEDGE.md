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
  notes/YYYY/MM/DD.md          type: note, one `## HH:MM` entry per spoken or typed note
  meetings/<date>-<slug>.md     type: meeting: summary + full transcript, resource → ~/Mochlet/Meetings/…/transcript.md
  signals/YYYY-MM-DD.md         type: digest: the day's AI signals (Hot · Selected · Briefs), sources = the items' URLs
  memories/                     later milestones write here
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

## Ingestion

A drop, a pasted link, text from the ask bubble, "Save window" or an MCP `add_resource` call becomes an
ingest job (`IngestController`): two extractions run at once, one brain call at a time, and the card in
the notch shows the stage for every job.

1. **Extract** (`MochletServices/Extract`): text, Markdown and CSV (`TextExtractor`), code (fenced up to
   200 KB, else an outline), PDF through PDFKit with Vision OCR for pages under 40 characters
   (`PDFExtractor`), docx/rtf/odt through `NSAttributedString` with `textutil` as fallback
   (`OfficeExtractor`), PPTX from the slide XML with speaker notes (`PPTXExtractor`), images through OCR
   (`ImageExtractor`), audio and video through `AVAssetReader` and `SpeechAnalyzer` with ffmpeg for mkv,
   webm and opus (`MediaExtractor`). Links (`URLIngestor`): PDFs are downloaded; `arxiv.org/abs|pdf`
   fetches the metadata from the export API plus the PDF; GitHub repositories get the README and the
   file tree, GitHub blobs the raw file; YouTube uses oEmbed plus subtitles when `yt-dlp` is installed;
   every other page is rendered in a hidden `WKWebView` and reduced to the article by Mochlet's own
   reader script, with a static fetch as fallback. `robots.txt` is honoured unless the setting is off.
2. **Analyse**: the brain (the chat backend, used one-shot through `LLMClient`) fills the report schema:
   title, one-liner, summary, key points, why it matters, entities, tags, language, content kind,
   suggested project, action items, open questions, quotes, related pages. Sources above about 12k
   tokens are read window by window (notes per part, then one reduce pass). Images get a description
   first when the brain can see them. Claude Code answers through `--json-schema`; other backends get
   the schema in the prompt and one repair pass. The brain runs without MCP servers, tools or a
   session file, and its hook events are tagged so no mini slime appears for them.
3. **Route**: `ProjectRouter` asks a `DecisionEngine` (Apple FoundationModels on-device first, then the
   brain as LLM-JSON; answers cached 24 h) to pick a project or the inbox from the title, one-liner,
   tags, host and source folder, multiplied by learned priors (`host:`, `tag:`, `dir:`). Below 70 %
   confidence or with the top two within 20 % the card asks, with the suggestion accepted after 10 s.
   Choosing differently, or moving a report later, adjusts the priors.
4. **File**: the source is mirrored to `<dir>/references/<sha12>-<name>` (plus a readable `.md` for
   binary files and an `.html` snapshot for pages, listed under `mochlet.mirrors`), the report is
   written, both are indexed and the folder indexes regenerated. A failed extraction or analysis still
   files a stub report with the reason, so nothing dropped is lost. Dedupe keys are `sha256:`, the
   canonical `url:` and `arxiv:<id>`; a known source answers "Already chewed" unless re-chewed, and a
   re-chew keeps the report's path.
5. **Integrate**: the brain sees the report, the most related pages (`find`) and the existing titles and
   returns an `IntegrationPlan` (revise sections, create entity/concept pages, add links, at most 15
   pages). Pages a human edited receive a "Proposed update" block instead of a rewrite. The report is
   marked `mochlet.integrated: true` and `log.md` gets an `integrate |` line.

Settings → Knowledge → Chewing switches OCR, transcription, image descriptions, integration and
`robots.txt` individually. The ingest card offers Open, Ask (the knowledge card with the report in
context), Move (to another project or the inbox) and Re-chew; a failed job offers Try again and the log.

## Notes

"Note to self…", "remember that…" (voice, or typed into the ask bubble) appends to `notes/YYYY/MM/DD.md`
(`NoteWriter`): the page is created with `type: note`, title `Notes YYYY-MM-DD` and
`mochlet: {kind: notes, last_source: voice}`; the body is `# Notes YYYY-MM-DD` followed by `## HH:MM`
headings, and a second note in the same minute joins the previous entry. The page is reindexed on its own
(`reindex(only:)`), the folder indexes regenerated and `log.md` gets `- HH:MM note | <text> → notes/…`.
Notes are plain pages: they are found by `find`/`search`, linted, and integrate like anything else when
you ask the base to.

## Meetings

A finished meeting (`MeetingController`) is filed as `meetings/<date>-<slug>.md` with `type: meeting`,
`resource` pointing at the Lark-form `transcript.md` under `~/Mochlet/Meetings/`, `tags` from the
summary's keywords, `sources[transcript]`, and `mochlet: {kind: meeting, dir, started_at, duration_s, app,
speakers, language}`. The body carries the summary sections (overview, decisions, action items with
owners, open questions, topics with `HH:MM:SS` stamps, marks) and then the whole transcript as
`**Name** \`HH:MM:SS\`` lines, so a query lands on the moment something was said. Renaming or merging
speakers on the card rewrites the page (the log line says "updated"). The page is a normal wiki page:
indexed, linted, integrable; the audio stays outside the bundle and follows the retention setting.

## Signals

The daily digest (`SignalsController`, written at the time set under Settings → Signals, or on demand) is
filed as `signals/YYYY-MM-DD.md` with `type: digest`, `tags: [signals, digest]`, `sources[]` = one entry
per selected item (`id: eN`, the item's URL, its title) and `mochlet: {kind: digest, window
{from, to}, items_seen, items, hot, rubric_hash}`. The body opens with the brain's overview, then Hot
(events carried by several sources, hotness ≥ 2), Selected (the best item per event, ranked by hotness
then score, at most two per source) and Briefs (one line each). Each entry has the title as the heading
with `↑` for rising and `×n` for the number of sources, the summary, and a `<sub>` line with the reason,
the source and the score; `[^eN]` footnotes point at the source URLs. Events already shown in the last seven digests come back only with a new party or four
sources. The `signals_latest` MCP tool returns the newest page; `log.md` gets a `digest |` line. The
items themselves (scores, writings, embeddings, events, hotness history) live outside the bundle in
`~/Library/Application Support/Mochlet/signals.sqlite`, which is a cache: delete it and the sources are
fetched again (30 newest items per source the first time; older ones are kept as history, not scored).
