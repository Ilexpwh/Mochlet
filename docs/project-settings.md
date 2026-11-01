# Project settings and routing

Projects has an accessible card for every registered folder, with Settings and Open actions. Edit a name, comma-separated aliases and project instructions. Exact names/aliases (including Unicode) resolve deterministically; duplicates produce a selection error. This is explicit lookup, not natural-language guessing from arbitrary chat text.

Instructions are optional, at most 16 KB, and accompany each coding request for that project. The submitted prompt and subsequent run retain the exact instructions used. The current request takes precedence. Instructions are user-authored configuration sent to the selected agent, not a secret store. Empty preferences leave the original prompt unchanged.

Edits compare the original project record transactionally. Queued, running or waiting tasks prevent settings changes. Enqueue also compares the project snapshot captured before asynchronous source/memory preparation; a concurrent edit rejects submission rather than dispatching stale preferences or a stale destination. The composer restores the user's request on rejection.

Only a project with no tasks and no GitHub binding can change folders. Established projects must register a new folder separately; exact sessions and existing workspaces are not silently retargeted. A missing established folder remains blocked until restored. A complete moved-repository/session migration workflow remains future work. Aliases are not interpreted as permissions, and attached files never choose a destination.

Verification: core tests cover persistence, scope isolation, duplicate aliases, immutable session destinations, invalid settings and enqueue/edit ordering. The native AppModel fixture delays context preparation during a project edit and confirms no runtime is reached. Another fixture submits two projects and checks only the intended queued prompt receives preferences. Native walkthrough edited and reopened a disposable project and resolved `小薄荷` to the correct destination. [Screenshot](evidence/native-project-settings.png). No live coding request was sent for this walkthrough.
