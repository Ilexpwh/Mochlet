# Reviewed file organization

Files → Organize files and undo → Organize loaded files prepares a plan for the currently loaded file set. The local option groups files under Documents, PDFs or Images without inference. The AI option sends the user's instruction plus filenames, formats, extraction warnings and up to 1,000 excerpt characters per file to the explicitly selected text analysis model. It requires the user's own configured key and makes no automatic provider fallback.

The response is a bounded JSON proposal containing known file IDs, relative destinations and reasons. Unknown/duplicate IDs, absolute or parent/hidden paths, duplicate destinations and file/parent path conflicts fail validation. Existing target files are never replaced. An omitted file stays unchanged. Source fingerprints must still match the bytes ingested before preview; edited files must be fed again.

The next sheet displays every full source/destination and reason. Preview writes only a local operation journal; it creates no destination folders or moves. Apply creates missing subfolders within the reviewed destination and moves regular files individually. The root folder is bound to its filesystem identity. Replaced roots, symlink parents, changed sources and collisions block execution. Earlier successful moves remain in history if a later move fails.

Undo uses the same journal and original fingerprint; it never overwrites a new occupant of the original path. Created empty subfolders remain. Interrupted move receipts reconcile from file identities before any retry. History is paged so older undo records remain reachable.

Current bounds: at most 100 loaded files, 100 MB per move, same filesystem only. Feeding still has its own smaller extraction limits. No whole-directory relocation, deletion, cross-volume copy, arbitrary command execution or automatic action on a generated plan. Close the review to cancel; cancelled previews cannot execute themselves. AI proposal quality and paid live inference remain separate validation gates.
