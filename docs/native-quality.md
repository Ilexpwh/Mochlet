# Native experience and motion contract

Status: required quality bar, added 2026-11-01. These are design targets and acceptance gates, not measurements of an implemented application. The existing HTML prototype is a concept reference, not the production visual or motion standard.

## Working identity: Mochlet

Pronunciation: **MOCH-let**. The name suggests a small, soft companion and leaves room for serious knowledge and coding work. Suggested tagline: **Your little companion for big work.** The product can be called Mochlet while each slime keeps its own user-chosen name.

Keep the development directory `slime-app` and current internal module names stable. This is a naming proposal, not a registered name or a claim of domain/trademark availability. A preliminary check found existing [Mossling apps](https://apps.apple.com/ca/app/mossling/id6808949867), so that earlier candidate was dropped. Recheck the selected name before public distribution.

Visual direction: a distinctive rounded silhouette with controlled volume, expressive eyes, a restrained highlight and contact shadow, readable at notch size. Use an original small pose vocabulary and accessories anchored to the body rig. Keep workspace typography and controls calm and recognizably native. Color is customizable; shape, timing and expression make the character recognizable across palettes.

## What “high quality” means

1. **Immediate response:** clicking, speaking and dropping files produce visible acknowledgement without waiting for a CLI or network request.
2. **Continuous motion:** transitions can reverse or change destination without snapping, restarting from a default pose or blocking input.
3. **Honest expression:** the character reflects actual state and uncertainty; it does not celebrate a failed or partial operation.
4. **Reliable native behavior:** display changes, full-screen apps, Space changes, sleep and wake do not strand the panel or lose tasks.
5. **Quiet presence:** animation and notifications are restrained; power use and accessibility remain part of the design.

Apple recommends purposeful, optional, interruptible motion and distinguishes input delay from animation hitches. Use these as evaluation principles, while treating the numeric budgets below as our own targets. [Motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion), [responsiveness](https://developer.apple.com/documentation/xcode/understanding-user-interface-responsiveness), [macOS guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/).

## Surface behavior

| Surface | Job | Behavior |
|---|---|---|
| Resting notch | Quiet presence and attention count | Minimal silhouette/status; no readable private task text by default |
| Peek | Show active project/task and quick actions | Open deliberately; avoid hover expansion that interferes with menu-bar travel |
| Conversation panel | Type, speak, drop files and answer requests | Predictable keyboard focus and stable composer position |
| Attention panel | Resolve the next blocker | Show task/project/action; prioritization never silently answers another request |
| Full workspace | Projects, knowledge, session history, diffs and files | Standard resizable native window with normal selection/copy behavior |

Click opens the companion; the configured shortcut focuses input. Escape closes the surface without canceling the run. Recording has its own explicit stop/cancel behavior so Escape never leaves the microphone running invisibly. Drag-enter advertises whether the payload is accepted, unsupported or too large before drop. Right-click opens a conventional context menu.

Use system screen geometry/safe areas; never assume a hardcoded notch width or place actionable content behind the camera cutout. Honor selected-display policy, display scaling and menu-bar relocation. A no-notch Mac uses the menu-bar fallback. Hit testing stays within app-owned controls; no invisible full-screen input interception.

## Character state model

Separate task state, input state and animation state. A single reducer derives a visual state; animations do not mutate tasks. Cancel queued transitions when their underlying state expires.

| State | Proposed expression/motion | Truth source |
|---|---|---|
| Idle | Infrequent blink, slight settling; long still periods | No foreground interaction or attention |
| Greeting / peek | Brief eye contact and one small lift | User opens panel |
| Listening | Attentive eyes and gentle level response | Actual active recording; no decorative fake waveform |
| Thinking | Focused gaze and slow shape change | Agent preparing/responding without measurable progress |
| Working | Restrained activity indicator; no endless large bounce | Runtime activity |
| File hover | Mouth anticipation, small lean toward drop zone | Accepted drag enters the panel |
| Chewing | Short squash/compression rhythm; file count/progress outside body | Intake/extraction in progress |
| Needs input | Curious tilt and stable attention marker | Unresolved provider question/approval |
| Success | One small lift/settle, then rest | Confirmed completion; partial success gets a different label |
| Error / disconnected | Concerned eyes and clear text, no punishment animation | Explicit failed/interrupted/disconnected state |
| Rest | Static/slower pose | User quiet mode or occluded surface |

Input states take visual precedence while the user interacts, but unresolved attention remains visible as a badge. Text always distinguishes recording, processing, waiting, disconnected and failed states. The slime never looks “angry” at the user for declining an approval.

## Motion tuning targets

These ranges are starting values to tune in a native prototype, not a command to add delay:

- Click/hover acknowledgement: 60–100 ms, with immediate control highlight.
- Peek/expand/collapse: roughly 160–240 ms, restrained easing or a lightly damped spring.
- Expression transition: roughly 100–180 ms; eye/mouth changes should remain readable at small scale.
- Chewing cycle: roughly 350–500 ms, scaled to ingestion stage; complete only when processing state changes.
- Success accent: a single 300–450 ms gesture; do not prolong or replay it on each output chunk.
- Idle: sparse, slightly varied timing, never a large continuous bounce. Pause unnecessary drawing when hidden or the screen is locked.

Squash/stretch preserves the impression of volume; eyes, mouth and accessories track the same body transform. Anchor feet/base to avoid floating. Interrupting a spring continues from its current visual state. Layout size changes and character motion use separate tracks so the text composer does not jitter.

Prototype a native vector/Canvas renderer first. Compare a sprite or specialist animation engine only if it materially improves fidelity within the resource budget. No renderer dependency is selected solely because it has attractive demos. Ship original local assets with documented licenses.

## Service and lifecycle quality

- Run ownership, durable events and pending requests live outside view lifetime. Opening/closing a surface never restarts a CLI.
- Use bounded queues, cancellation and backpressure. Database work, file extraction, retrieval and process I/O stay off the UI thread.
- Reconnect with explicit state; avoid duplicate runs, polling storms or relaunch loops.
- Wake reconciles sessions and refreshes stale issue/usage state before claiming it is current.
- No busy animation timer, microphone recording or broad file watcher runs unnecessarily in the background.
- Login launch is user-controlled. A future separate helper must have its own lifecycle and uninstall behavior; M1 does not promise work after app quit.
- Provide a visible privacy/quiet mode for task text. Do not promise automatic screen-sharing detection on every capture path.

## Measurable gate

Document the reference supported Mac, OS, build mode, display refresh rate and workload before collecting results.

| Measurement | Initial target | Method |
|---|---|---|
| Warm input to first visible acknowledgement | P95 ≤100 ms | Native signposts + screen/frame capture over repeated interactions |
| Animated frame deadline | Match actual refresh cadence: ~16.7 ms at 60 Hz, ~8.3 ms at 120 Hz when supported | Profiling under expansion, chewing and streamed-output load; do not force 120 Hz while idle |
| Visible hitches | No repeatable >100 ms UI stalls in the reference interaction suite | Main-thread/hitch trace; fix causes before release |
| Hidden/quiet idle CPU | Target <1% of one CPU core averaged over 5 minutes, with sync paused and speech engine unloaded | Record exact process metric and conditions; separate active/background sync costs |
| Native shell memory | Initial target ≤150 MB steady-state without CLI children or loaded speech/model assets | Record total app footprint and child/model costs separately; revise only with evidence |
| Stability | No crash, orphaned owned process or duplicate task in a 2-hour mixed-workload soak | Sleep/wake, display changes, cancel/reconnect, large output and file intake |

These are provisional engineering budgets, not benchmark promises. M1 includes the first measurements; M5 repeats them on the packaged release. Quality work cannot be postponed entirely to final polish.

## Accessibility and finish review

Support keyboard navigation, VoiceOver labels, increased contrast, reduced motion and standard text editing. Reduced motion substitutes stable poses/short fades without losing state. Sound is optional and never the only status signal. Larger text must not clip controls or make the active project identity disappear.

Record a native walkthrough of: open → type → run → question → answer → result; voice with permission denial; file drag accepted/rejected → chew → partial result; error/recovery; rapid open/close during streaming; multiple displays and full-screen apps. Review at real notch size, not only enlarged design frames.

No milestone can mark a native interaction complete based solely on the HTML simulation. Tasks Q01–Q05 own this contract, alongside T31/T32.
