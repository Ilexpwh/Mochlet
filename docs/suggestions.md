# Additions worth building

This list now separates optional product recommendations from requirements added by the user on 2026-11-01. Items marked **baseline** are incorporated into the implementation checklist because they make the requested features dependable. The rest remain optional backlog; they do not expand M1.

## Highest value

| Addition | Example | Why it helps | Placement |
|---|---|---|---|
| **Attention inbox** | “Moss needs a folder choice; Pip needs approval.” | One place for actionable blockers across agents; less terminal hunting | M1 baseline, T07/T12 |
| **Recovery journal** | “This run was interrupted. Resume its session or retry as a new attempt.” | Makes laptop sleep, app restart and connection loss understandable | M1 baseline, T08 |
| **File-change preview + conditional undo** | “Move these 12 files; keep both versions of this collision.” | Makes organization trustworthy and recoverable | M2 baseline, T19–T21 |
| **Reusable task recipes** | “Weekly project recap”, “Sort invoices”, “Review this repository” | Turns recurring instructions into a short action with chosen inputs | Optional after M2 |
| **Personal/project knowledge and memory** | “What did we decide about this project?” | Grounded, inspectable context across sessions | **Now required**; M1b / K01–K06, see [design](knowledge-memory.md) |
| **Handoff packet** | “Continue this task in Pi with the current brief, outputs and unresolved questions.” | Provides useful continuity across agents without pretending they share private context | Optional after M3 |

## Other good additions

### Quick capture from Finder or a selected screen region

Offer “Send to slime” for selected files and a user-triggered screenshot capture. Attach a visible preview and let the user choose what to send. This is a natural entry point for multimodal work. Start with Finder file intake; screen capture needs a separate permission and privacy UX. Avoid continuous screen recording.

### An adjustable quiet mode

Use a subtle badge for routine updates and an explicit attention state for pending input. Let the user mute celebrations, reduce animation and configure completion notifications. Never hide a blocking request solely because animation is disabled. Keyboard access and motion alternatives align with [Apple's keyboard guidance](https://developer.apple.com/design/human-interface-guidelines/keyboards/) and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### Result review with provenance

Every generated artifact should show which task/run produced it, which inputs it used and where it was saved. Code changes should link to a diff; summaries should link to source pages/files. “Done” becomes inspectable instead of just a happy animation. File source references are already part of M2; repository diff review is a later extension.

### Usage-aware queueing

Warn before starting more work when an available quota window is nearly exhausted. Queue a task for manual retry rather than silently switching accounts or models. An app-side cost estimate is not a hard billing cap, and account limits may be absent or stale. Consider this after reliable usage snapshots are implemented.

### Workspace export and recovery

Export task metadata, project settings and artifact references without credentials. Show whether referenced external files are included. Start with a portable export; encrypted backup and synchronization can come later. This gives a personal tool a practical exit and recovery path.

### Local diagnostics panel

Show CLI discovery/version, last successful connection, capability support, current permission state and recent redacted errors. A “copy diagnostics” action should omit prompts, file content and credentials by default. This will save substantial debugging effort during the first releases.

## Keep the character useful

- Tie expressions to real state: listening, ingesting, working, waiting, resting or failed.
- Keep cosmetic personality separate from task instructions and permission policy.
- Let one slime represent a role such as researcher or organizer, with an independently selected provider.
- Prefer a handful of expressive original poses over a large customization marketplace at launch.
- Include a “stop this run” action in the compact surface; add “stop all managed runs” once concurrent execution exists. Observed sessions must not imply a stop capability they lack.

## Defer

| Idea | Why later |
|---|---|
| Autonomous agent teams | Compounds scheduling, shared-folder contention, cost attribution and approval routing before the basic loop is reliable |
| Always-listening voice | Adds microphone privacy, power and accidental-trigger problems; push-to-talk covers the requested workflow |
| Automatic global file reorganization | A bounded user-selected folder and previewable plan are easier to reason about and recover |
| Skin marketplace / executable plugins | Adds packaging, trust and compatibility work; simple original customization is enough initially |
| Cloud sync / team accounts | Changes identity, conflict resolution, storage and access-control architecture; preserve extension points first |
| Autonomous provider failover | Can duplicate work, change capabilities and lose context; start with an explicit handoff packet |

## My recommendation

Make **project identity, grounded memory, native interaction quality, attention, recovery and file reversibility** foundational. Add **recipes** as the first optional productivity feature. Keep advanced cosmetics and multi-agent autonomy behind a reliable daily-use workflow.
