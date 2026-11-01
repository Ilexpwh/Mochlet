# Companion profiles

Appearance supports creation, editing, duplication, archival and restoration of named companions. Each profile has a mint/peach/sky/lilac palette, local agent, instructions and installed macOS reply voice. Spoken replies still require the global speech setting.

The composer and new-task sheet select a profile before creating work. “No profile” retains manual agent selection. Existing unstarted drafts can explicitly change their profile in Task details. Established sessions keep an immutable profile snapshot, including voice and instructions. Editing or archiving the source profile does not alter those tasks. A new conversation uses the current selected profile. Submitting while the selected task is active/queued creates a new task with the current profile and matching agent.

Profiles and snapshots live in the local SQLite database. Saving uses optimistic version checks; task assignment and creation are transactional. Preparing context captures a profile revision, and enqueue rejects changed assignments, stale new-task profiles and agent mismatches. There is a 100-profile local limit, 120-byte names and 20 KB of instructions per profile. Profile instructions are preferences; the current request and project instructions take precedence.

## Evidence — 2026-11-02

Three core regressions cover persistent snapshots after edit/archive/reopen, stale assignment and queue rollback, established-session immutability, provider mismatches and legacy unprofiled tasks. A native AppModel fixture covers archival fallback to a different agent, new-task forks, captured instructions and persistence of the explicit no-profile choice. Full check: 117 reported Swift tests (three opt-in live tests skip), native app build and native orchestration fixtures passed. Read-only review found an agent-label mismatch in the draft sheet; the label now uses the same selected profile as creation.

Interactive profile editing and physical drag walkthroughs remain unverified. The native automation service repeatedly lost input ownership; an existing composer draft was left intact. No live agent inference, voice output or personal audio was used for these checks.
