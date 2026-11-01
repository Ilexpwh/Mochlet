# OKF bundles and memory lifecycle

Mochlet imports a reviewed snapshot of one OKF directory into a selected personal/project scope. Concept paths survive export; each imported bundle has a separate root so absolute bundle links retain their intended meaning. Navigation/history files are skipped as memory and indexes are regenerated. Forgotten concepts and prior revisions are excluded from exports. Non-Markdown resources are not copied; the preview lists omissions. No executor, attester or linked resource runs during import.

The folder preview is bounded to 500 concepts, 20 MB total and 5,000 visited entries. Concepts are UTF-8 Markdown up to 2 MB. YAML uses pinned Yams 6.1.0, preserves unknown metadata values and accepts unknown concept types. Formatting/comments may normalize when edited. Frontmatter requires a mapping with a nonempty string type; aliases, merge keys, overly deep structures and headers over 32 KiB/512 lines are outside this importer. This is bounded interoperability, not a claim of accepting every conformant YAML document.

Draft, deprecated, expired and invalid lifecycle metadata exclude notes from AI retrieval. Retained notes remain visible with a reason and a **Review lifecycle** action. Review replaces status/deadline, checks the original file revision and retains the old revision. It does not bypass connected-source access. Expiry is checked again before presenting an answer or dispatching queued evidence.

Import stores fresh local IDs and the explicitly selected scope. A journal rolls back an interrupted batch on next launch. The imported bytes are the previewed snapshot, even if the source directory changes while the review sheet is open. Repeating the same completed preview is rejected. A new explicit import creates independent copies; it is not synchronization.

**Export scope** creates a new collection directory with a local bundle and separate imported bundle roots. Import a child root, not the collection wrapper. Only authoritative current note files are exported, including retained connected or lifecycle-excluded notes; exports do not grant remote permissions. Source provenance and connected references remain metadata. Revision history and original log files are not exported.

Sources: [canonical OKF v0.2 specification](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md), [Yams 6.1.0 parser](https://github.com/jpsim/Yams/blob/6.1.0/Sources/Yams/Parser.swift). YAML and LibYAML MIT notices ship with the app.
