# Mochlet 0.1.0 — local development preview

This is a launchable Apple Silicon development preview, not the completed release described by every milestone. The repository’s README lists implemented workflows; build-status.md records individual checks and limitations.

## Build and run

Run `scripts/check.sh` for core fixtures, the Debug app and the native runtime host. Run `scripts/package-local.sh` for a Release app and a ZIP plus manifest under `dist/`. The script uses the full Xcode developer path, verifies the local signature/architecture, records the exact Git revision and reports whether the tree was dirty.

Open `build/Build/Products/Release/Mochlet.app`, or extract the generated ZIP and open its Mochlet app. This is locally ad-hoc signed, not Developer ID signed or notarized. Do not treat it as a public-distribution package. macOS 15 is the build target; this Mac’s macOS 27 is the tested host.

Register a project folder in Projects, configure the installed CLI in Agent settings, then use Companion. Existing CLI login is used. Tasks preserve exact session/project bindings. Additional requests queue behind the current coding run. Attempts and replies are visible in Task board. The companion can be placed at top/left/right through Appearance and has compact/header drag handlers; end-to-end physical dragging remains unverified because the native automation service cannot drag its borderless panel.

## Optional connections

- Speech & Models: enter your own OpenRouter key and choose an appropriate transcription/analysis model. Image summaries require image input and text output. Paid inference is not exercised by the fixture suite.
- Google: configure a Desktop OAuth client, sign in and grant only the desired features; bind the account to a project. Saved Gmail/calendar synchronization stays scoped to explicit selections.
- GitHub: choose an authenticated account/repository, sync issues, then create reviewed task drafts. Push/PR publication is a separate explicit action.
- Slack/Lark/Feishu/Linear: configure the provider token and project binding. Source capture and reply delivery have local fixtures; live workspace validation remains pending.

Meeting capture requires explicit recording and OS permission. No personal audio was recorded to validate this preview. Live capture/device changes, Cantonese/Mandarin/English quality, diarization and long-recording behavior require consented samples and a configured provider.

## Remaining release gates

The full release still needs the live audio/provider/connector matrix, physical docking/multiple displays, VoiceOver and full-screen checks, macOS 15 execution, warm acknowledgement/stall measurements, two-hour mixed-workload soak and distribution signing/notarization. One recorded quiet-idle sample is below 1% of one core; it does not establish the rest of the performance gate.

Feature expansion remains tracked separately: manual task ordering/multiple profiles, GitHub Projects V2, broader team write-back and external-client liveness/control. Existing checklist IDs and unchecked acceptance items remain intact. No background workflow executes meeting action items or sends external replies just because they were summarized.
