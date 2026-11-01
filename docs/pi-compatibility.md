# Pi compatibility and verification

Verified on 1 November 2026 against **Pi 1.4.0**, upstream commit `4a080252f06caf63a525d7873c5d94d3c23887e0`. Pi is a user-installed CLI, not bundled with Mochlet. The [upstream source](https://github.com/earendil-works/pi/tree/v1.4.0) is MIT licensed. Mochlet's small approval extension is original code; no Pi runtime dependency was added to the Swift package.

## Supported contract

Sources: pinned [RPC commands](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-commands.md), [extension UI](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc-extension-ui.md), [CLI configuration](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/cli.md), and [session format](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/sessions.md). Documentation was resolved through Context7 and checked against the installed 1.4.0 distribution and pinned source.

- Start a dedicated `--mode rpc` process per turn, passing argument arrays and the registered working directory. Check `--version` first. The selected Pi model/authentication remains Pi's responsibility; Mochlet never substitutes a provider.
- Disable discovered extensions, MCP, skills, prompt templates and themes. Explicitly load only Mochlet's approval extension. `--no-approve` disables project-local trust-gated resources; it is **not** per-tool approval. `--offline` suppresses automatic discovery/catalog updates; it does **not** make model inference offline. Normal project context files may still be read by Pi.
- Allow `read`, `grep`, `find`, `ls` in read-only mode; add `bash`, `edit`, `write` otherwise. Check the effective tool list. This is a tool restriction, not an operating-system sandbox. Bash approved by the user can start processes outside the agent's lifecycle.
- Before sending user text, ask `get_state`, then run a nonce-bound extension command that reports the actual session ID/file/cwd and tool configuration without inference. Reject an absent handshake, mismatched identity or different directory. Slash commands are excluded from ordinary tasks.
- Bind exact UUID and session file under Application Support/Mochlet/Agents/Pi. Resume uses `--session` and validates the saved JSONL header plus the live handshake. Never use Pi's latest-session shortcut. A fresh session file is created by Pi when actual conversation content is persisted; attempting to resume an empty/unwritten session fails visibly.
- Correlate command responses by ID and command type. Normalize confirm/select/input/editor requests with exact dialog IDs. Select only offered values; input/editor can accept custom text. Support cancellation and local expiration. A written response is not a server acknowledgement.
- The approval extension gates every non-read tool call with an explicit confirmation. Missing host verification, read-only policy, an oversized request, denial, expiration and delivery exceptions all block the tool. Only this bounded integration supplies tool approvals; arbitrary third-party extensions are unsupported.
- Replace provisional text with authoritative final assistant text. `agent_end` alone is not completion: wait for `agent_settled`, including retries/compaction/queued work. Duplicate settled events are inert. Provider errors and aborts never become success.
- Cancel by clearing steering/follow-up queues before aborting. Restore cleared text to the composer and journal it. Do not dispatch it automatically. Disconnects pause Mochlet's durable queue.
- Show reported cumulative session token/cost statistics separately from Codex account allowance. Unavailable statistics do not erase a completed result. Pi weekly/subscription limits remain unavailable.

## Evidence

- Core protocol and process fixtures cover fragmented frames, exact resume, approval/question correlation, timeout, cancellation ordering, preserved queued text, missing guard, wrong cwd, process death, final text replacement, duplicate settlement and unavailable statistics.
- The real Pi 1.4.0 process loaded the extension and passed read-only preflight through `PiRuntime`, using an isolated empty agent directory. No model inference or tool execution occurred in that live probe.
- Fifteen direct extension assertions passed using Pi's installed TypeScript loader: host verification, read permission, deny/allow, read-only protection, exact reviewed input, abort-signal forwarding and fail-closed delivery errors.
- Native AppModel fixtures pass creation/resume, decline, selection, final output replacement and usage attribution. A separate native UI walkthrough passed the same flow using the deterministic process fixture. [Approval screenshot](evidence/native-pi-approval.png).
- The UI walkthrough also reproduced stale composer text specifically after Command-Return. Ending the AppKit edit before submission fixes it; both keyboard and button submission now clear the draft. Keyboard focus returns to the composer.

**Still unverified:** live authenticated Pi generation, real tool execution after approve/deny, live provider cancellation, model-specific context/compaction behavior and third-party extension compatibility. The fixture walkthrough is not evidence for these. The T24 release gate remains open.

## Reproduce

```sh
./scripts/check.sh
# Use an existing Pi 1.4.0 executable; this isolated probe makes no inference request:
MOCHLET_LIVE_PI_PATH=/absolute/path/to/pi \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/SlimeCore --filter livePiGuardPreflightWithoutModelInference
# Optional extension assertions using the loader installed alongside Pi:
node scripts/check-pi-guard.mjs /absolute/path/to/node_modules/jiti/lib/jiti.mjs
```

For normal use, choose Pi and set its executable in Agent settings. Configure Pi's model/authentication separately. No credentials are copied from Codex or Claude, and no Pi installation or login is performed silently.
