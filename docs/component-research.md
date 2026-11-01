# Mochlet component research

Research date: **1 November 2026**. These are evaluated candidates and implementation recommendations, **not a list of integrated capabilities**. Repository metadata and current primary documentation were checked online. Release dates below are evidence of recent activity, not proof of quality or compatibility. Validate a pinned revision before adoption.

## Recommended adoption order

1. Keep Coucou as the principal interaction reference; finish the native notch lifecycle and file-drop feedback before adding unrelated visual libraries.
2. Add customizable global shortcuts through KeyboardShortcuts if the current native shortcut implementation cannot satisfy the keyboard acceptance scenarios.
3. Keep the approved ScreenCaptureKit/AVFoundation capture architecture and OpenRouter transcription provider. Evaluate local audio engines as explicitly selected alternatives, without automatic fallback.
4. Align portable knowledge exports with the actual OKF v0.2 specification. Treat VikingMem and OpenViking as separate architectural references.
5. Use GitHub CLI for a personal-release GitHub transport and AppAuth or Google Sign-In for production Google authorization. Keep sync state in Mochlet, separate from authentication.
6. Add Pi through its documented JSONL RPC; add Claude through a version-pinned, supported protocol with explicit permission handling. Neither provider should inherit Codex's protocol assumptions.
7. Add Sparkle only when the signed release/update pipeline is ready.

## Native interaction and distribution

| Candidate | Verified evidence | Recommended use and gate |
|---|---|---|
| [Coucou](https://github.com/Louis-CFM/coucou) | Native macOS notch companion, MIT repository; current README documents hover opening, desktop placement, file drop, agent approval interactions and a full workspace window. [Source](https://github.com/Louis-CFM/coucou) | Main UX reference as requested. Reuse narrow, attributed pieces at a pinned commit. Keep Mochlet's durable task routing, explicit recording state, and original character identity. Acceptance: keyboard/focus behavior, interrupted transitions, no lost composer drafts, no automatic approval. |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT; version **3.1.0**, released **2026-09-11**. Provides user-recorded global shortcuts and SwiftUI recorder controls; README states macOS 10.15+ and sandbox compatibility. [README](https://github.com/sindresorhus/KeyboardShortcuts), [release](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.1.0) | Strong candidate for show/hide companion and push-to-talk controls. Validate conflicts, press/release semantics, keyboard layouts and disabled shortcuts during recording transitions. Avoid custom global event taps unless the chosen key requires them. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Version **2.10.1**, released **2026-10-25**. Official setup supports SPM and signed update tooling. License contains the main permissive notice plus several third-party notices, so preserve the complete file. [Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), [setup](https://sparkle-project.org/documentation/), [license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) | Prefer over a homegrown updater for direct distribution. Gate on valid signed artifacts, hosted appcast, update signing keys, failed-download recovery and an upgrade test from the previous app version. Do not display an operational updater before those exist. |

Polish recommendations: animate the shell and character independently; reserve attention for actionable events; tie chewing to ingestion progress; retain stable text/composer geometry during pose changes. Test reduced motion, full-screen Spaces, multiple displays, external-display-only use, permission sheets, and focus restoration. These are proposed Mochlet acceptance criteria, not claims about upstream implementations.

## Audio, voice and meetings

| Candidate | Verified evidence | Decision |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 SDK; **v0.18.0**, released **2026-10-28**. Swift/Core ML transcription, VAD and speaker diarization. Documentation provides an offline diarization manager and model preparation lifecycle. [Repository](https://github.com/FluidInference/FluidAudio), [release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0), [diarization guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md) | Best first local VAD/diarization experiment. Download models only after explicit selection. Measure memory, warm-up, battery and speaker confusion on Mochlet's meeting corpus. Inspect licenses for the exact model artifacts separately. |
| [WhisperKit / Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift) | The old WhisperKit repository redirects here. MIT SDK; **v1.1.1**, released **2026-10-08**. Package still exports `WhisperKit`; also exports `SpeakerKit` and `TTSKit`, with macOS 13 minimum. SpeakerKit can combine diarization with WhisperKit transcripts. [Repository](https://github.com/argmaxinc/argmax-oss-swift), [package](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift), [release](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.1) | Strong alternative for optional local multilingual transcription plus speaker alignment. Pin the package and model versions. Keep it behind `ModelService`, not in the recorder or UI. Separate SDK licensing from downloaded model terms. |
| [AudioTee](https://github.com/makeusabrew/audiotee) | Swift CLI using Core Audio taps (macOS 14.2+), PCM on stdout, system/process filtering. README documents default-output-device limitations. Repository was not archived, last push **2026-03-31**; no release and no root license file were found. [README](https://github.com/makeusabrew/audiotee/blob/main/README.md), [repository metadata](https://api.github.com/repos/makeusabrew/audiotee), [root listing](https://api.github.com/repos/makeusabrew/audiotee/contents) | Architecture reference only; do not vendor code while reuse licensing is unresolved. It does not justify replacing the approved capture pipeline. Use Apple's capture APIs directly for the first release. |

**Language caveat:** FluidAudio's current Parakeet options documented as multilingual target 25 European languages; that claim is not evidence of Cantonese or Mandarin support. Keep model selection explicit and evaluate English, Cantonese, Mandarin and code-switching separately. [FluidAudio ASR guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md)

OpenRouter/Nemotron remains the requested default. The candidates above do not remove the need for endpoint capability checks, provisional request-scoped speaker IDs, final transcript revisions, encrypted retained audio, seven-day deletion and consented live capture tests. A local speech engine should never silently replace an unavailable remote model.

## Portable knowledge and memory

**Important correction:** the supplied [arXiv paper 2605.29640](https://arxiv.org/html/2605.29640v1) is *VikingMem: A Memory Base Management System for Stateful LLM-based Applications*. Its event/entity model and memory evolution are useful references; it is not the Open Knowledge Format specification. Adopt the concepts of provenance, correction and temporal evolution as product design ideas without copying its prose or diagrams.

The canonical format is now [GoogleCloudPlatform/open-knowledge-format](https://github.com/GoogleCloudPlatform/open-knowledge-format); its repository uses [Apache-2.0](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/LICENSE.md). The older `knowledge-catalog/okf` copy explicitly says it is frozen. [Migration notice](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/README.md)

OKF **v0.2** defines Markdown with YAML frontmatter; `type` is the only always-required key. Optional provenance, freshness, verification and lifecycle fields support richer records. Unknown fields should survive round trips. Concept identity derives from a bundle-relative path; `index.md` and `log.md` have reserved meanings. [Canonical specification](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md)

Recommendation: keep native Markdown storage plus derived SQLite retrieval. Add a versioned importer/exporter, preserve unknown YAML, and keep Mochlet's project scope and stable internal ID as extensions. Test malformed frontmatter, renamed files, source revisions, deleted files and citation resolution. Do not claim complete OKF consumer compatibility merely because exported notes contain frontmatter.

[OpenViking](https://github.com/volcengine/OpenViking) is active: **v0.5.2.1**, released **2026-10-27**. Current upstream advertises **AGPL-3.0**, not a permissive license. Use it as a context hierarchy/retrieval design reference; do not copy current upstream into Mochlet under an assumption that it is Apache-licensed. A locally checked-out earlier revision may differ and must be examined separately before reuse. [License and repository](https://github.com/volcengine/OpenViking), [release](https://github.com/volcengine/OpenViking/releases/tag/v0.5.2.1)

## GitHub and Google connections

| Candidate | Verified evidence | Adoption recommendation |
|---|---|---|
| [GitHub CLI](https://github.com/cli/cli) | MIT, **v2.103.3**, released **2026-10-26**. `gh api` supports authenticated REST/GraphQL requests and pagination. [Release](https://github.com/cli/cli/releases/tag/v2.103.3), [manual](https://cli.github.com/manual/gh_api) | Good personal-release transport when the user already has `gh`. Invoke a selected executable with argument arrays; bind account, host and repository explicitly. Mochlet owns checkpoints, issue identity and routing. For public distribution, evaluate a GitHub App separately. |
| [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) | Apache-2.0, macOS supported; **3.0.0**, released **2026-08-24**. Native authorization uses an external user agent; convenience request construction supplies PKCE. macOS examples include a loopback redirect listener and fresh-token handling. [README](https://github.com/openid/AppAuth-iOS), [release](https://github.com/openid/AppAuth-iOS/releases/tag/3.0.0) | Preferred general OAuth foundation if several connectors need native authorization. Keep per-account state in Keychain and request only workflow-specific scopes. It is an authorization library, not Gmail/Calendar synchronization. |
| [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS) | Official Google iOS/macOS sign-in SDK, Apache-2.0; **10.1.0**, released **2026-10-23**. [Repository](https://github.com/google/GoogleSignIn-iOS), [release](https://github.com/google/GoogleSignIn-iOS/releases/tag/10.1.0) | Alternative when Google-only account UX is the priority. Choose one Google authorization owner, rather than overlapping SDK and custom refresh logic. Still requires the app's OAuth client configuration and service-specific consent. |

Use the official synchronization contracts as the implementation source: GitHub recommends following pagination links and conditional requests with ETags; authenticated unchanged responses can avoid primary rate-limit consumption. [GitHub best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)

Gmail has full and partial synchronization using history state; expired history requires recovery through full sync. Calendar has persistent sync tokens, paging and token invalidation recovery. Keep these cursors scoped to the account and collection; never advance them after a partial failure. [Gmail sync](https://developers.google.com/workspace/gmail/api/guides/sync), [Calendar sync](https://developers.google.com/workspace/calendar/api/guides/sync)

For issue-to-task workflows, resolve the selected GitHub repository to a registered local project before launching an agent. Store the issue URL, stable remote identity and fetched revision with the task. Repository text is task input, not authority to change connector accounts or execute unrelated commands. Preview remote mutations and reconcile uncertain responses before retrying. These are Mochlet design recommendations.

## Coding-agent adapters

**Pi:** `badlogic/pi-mono` now redirects to [earendil-works/pi](https://github.com/earendil-works/pi). MIT; observed release **v1.4.0**, **2026-10-21**. Its documented RPC mode is a long-lived process with JSONL commands, responses, session events and extension-UI records. The installed `pi --help` remains authoritative for version-specific CLI options. [RPC contract](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md), [release](https://github.com/earendil-works/pi/releases/tag/v1.4.0)

Implement a distinct Pi adapter with bounded frame parsing, request IDs, state verification and session-file binding. Do not equate an extension UI prompt with Codex's permission system. Capture protocol fixtures from the installed version and test cancellation, restart and simultaneous prompts before advertising approval support.

**Claude:** the official [Python Agent SDK](https://github.com/anthropics/claude-agent-sdk-python) is MIT and active (**v0.2.176**, released **2026-10-31**), but that license does not relicense the Claude Code executable or service. [Release](https://github.com/anthropics/claude-agent-sdk-python/releases/tag/v0.2.176) The official docs describe supported Python/TypeScript permission callbacks, sessions and structured streams, and recommend subprocess CLI use for other languages. Current SDK guidance also restricts offering third-party claude.ai login/rate-limit access without prior approval; avoid making a public subscription-auth promise. [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)

For Swift, first validate a direct CLI adapter against the installed version. Use exact session IDs and explicit cwd; distinguish structured stream completion from process exit. Full interactive approvals require a documented control path, not parsing human terminal text. `-p` can load project hooks and MCP configuration without an interactive trust prompt, so onboarding must make project trust explicit. [Headless contract](https://code.claude.com/docs/en/headless)

## Evidence and remaining work

This research used official repositories, GitHub metadata/release endpoints, publisher documentation and Context7 queries for AppAuth and FluidAudio. No package was installed, no model downloaded, no credentials accessed and no live recording made by this research task. The report makes no measured performance or language-quality claims.

Before integrating a candidate: pin its revision; preserve its notices; verify macOS 15 builds; run targeted fixture and native interaction tests; record live provider evidence separately. Repository activity and README examples alone do not satisfy the release gates in the implementation plan.
