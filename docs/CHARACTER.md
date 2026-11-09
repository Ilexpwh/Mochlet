# The slime: a style guide

Mochlet's slime is drawn to the standard of the Japanese TV anime it is modelled on (Rimuru from
*That Time I Got Reincarnated as a Slime*, the official sticker sheets and the Bandai
"punipuni" figures). This document is the spec the renderer and the engine are tuned against.
Numbers are in R units (R = the body half-width the stage asks for; the floor is y = 0, y down).

The work landed as milestones A0–A7 (baseline, silhouette, material, face, surface details,
motion, sizes, perf/docs). Each section below states the target and, once a milestone is in,
which code owns it.

## Silhouette

- A **bun**, not a ball: settled width : height ≈ 1.36–1.40 : 1. Flat base in contact with the
  floor, with a soft **skirt**: the lowest 0.3 R flares outward a little and tucks under into the
  contact chord. The crown is a wide, low arc.
- Rest ring: `RestProfile` defaults (A1) `width 1.12, height 0.94, centerY −0.78`, skirt bumps at
  ±0.55 rad from the horizontal; rest top −1.72. The other silhouettes (drop, puddle, loaf, spiky,
  tall) are explicit so they stay distinct from the bun.
- Everything inside the body (face, core, highlights, arm joints, morph blobs) is placed through
  the `BodyFrame` affine fit, so it squashes, leans and stretches with the ring.
- The body carries emotion: melt → low lobed puddle; puff → cheeks out, top flat; strain → crease
  strokes; shock → jump and stretch thin; marks (`?` `!` `♪`) grow out of the top-back as the same
  material over one bead.

## Material (two-layer translucent cel)

1. **Shell**: pale tint of the hue (rimuru ≈ #C0E4F8). Flat fill over the whole silhouette,
   goo included.
2. **Core**: a darker organic mass (rimuru ≈ #78AEE6) in the lower ~70 % of the body, cloud-topped,
   offset slightly right, with 1–3 lighter windows. The face sits over it.
3. **Specular**: one hard-edged pill upper-left (≈ 0.45 R × 0.16 R at −20°) with 1–2 trailing dots.
   Never blurred. Highlights stay with the light, not the surface (they do not rotate with lean).
4. **Rim**: a thin light band inside the outline along the lower-right / base (translucency).
5. **Ink**: one thin outline, dark desaturated hue, width 0.035 R (min 1 px). Face strokes share it.
6. **Floor**: a soft contact ellipse (≈ 1.1 R × 0.18 R). No horizontal "water level" inside the body.

Palette roles (`SlimeTheme`): core · mid · rim · deep · ink · highlight · blush · accent · tongue;
`isDark` = mid luminance < 0.33 flips the ink to light. `material(tint:)` (A2) derives shell,
inner, window, ink line, rim light and glow for any palette, including custom HSL picks.

## Face language (anime strokes)

Default face style is `anime`; `round` keeps the earlier ball eyes as a setting.

| Feeling | Eyes | Mouth | Extras |
| --- | --- | --- | --- |
| content (idle, greeting, question, waiting) | bold dash 0.34 R long with a slight upward bow, two short lash ticks at the inner end (ー= =ー, from the Bandai figures); eyes 0.94 R apart | none | blush 0.70 |
| happy / finished / cheer | ᵔ ᵔ arcs | ω / open wide | sparkles |
| thinking / working | relaxed line with a tick | none | |
| sleeping | — — | none | zzz |
| squeeze (error, poked) | > < with strain ticks | wavy / o | sweat |
| shock / surprised | double-ring eyes, dot pupils | open wide / o | `!` |
| dizzy | spirals | wavy | |
| sad / melt | down-turned arcs | wavy | face slides down |
| cry | closed strokes with two tear ribbons | wavy | drips |
| annoyed / puff | flat line | ∧ caret | anger mark, creases |
| love | hearts | ω | hearts |
| excited | ✦ sparkles | ω | |
| smug / proud | one arc, one line | tiny smile | |

- Eyes sit ≈ 0.14 R above the body centroid at (±0.47, −1.04); they slide ≤ 0.08 R with the gaze.
- Blush: flat `blush` ovals (0.28 R × 0.16 R) at (±0.78, −0.97), hard edge, alpha 0.70 at rest.
- Blink: the stroke lerps to a flat line and back (50 / 15 / 70 ms) every 3–6 s.
- Strokes are tapered brush shapes (`BrushStroke`): half-width w(t) = wMax · max(0.3, 1 − |2t − 1|^1.6),
  wMax = max(0.95 px, 0.045 R). Face ink is `ink` pulled 30 % toward black on light bodies, darker than
  the outline, as on the figures. Ball shapes map to strokes through `EyeShape.strokeEquivalent`, so an
  anime face never shows a sclera whatever sets the eye (drag-in, digesting, micro-idle, the stage).
- The face catalogue lives in `FaceTable` (state and emote columns per `FaceStyle`); `round` reproduces the
  character's earlier face. Settings → Character → Face, debug `look?face=anime|round`,
  tools `--face anime|round`.

## Surface details

- Sweat: `AccessoryKind.sweat`, a teardrop of the body's own jelly (shell, inner, ink, glint) that
  rides the upper cheek at ring angle −π/2 ± 0.75 and slides 0.30 rad down over 0.8 s, 0.62 s life
  plus the 0.18 s removal fade. The error state sweats every 2.5 s, `confused` once, and the third
  press within 0.9 s of the last (ぷにぷに) draws one.
- Creases: `CreaseFrame`s are 0.18 R ink ticks pointing in from 0.05 R inside the outline. A press
  sets `strainAngle` from the finger and fades `strainAmount` 1 → 0 over 0.5 s (three ticks); puff
  creases both cheeks and melt both lower sides while the morph holds (two ticks each side).
- Core lag: `coreSpring` ω 10 ζ 0.35 (≈ 70 ms lag, 31 % overshoot) and `coreScaleSpring` (same)
  chasing the ring's extents, drawn as `frame.coreScale / body.scale` on the inner mass, so the core
  trails upward through a fall and spreads wide for a beat after a landing. The renderer clamps
  the positional lag to ±0.4 reference units.
- Melt: `faceSlide` 0.25 R over 0.6 s moves eyes, mouth and blush down the face sphere (they
  foreshorten on the way) and back when the puddle releases.

## Motion (anime timing)

| Beat | Target | Measured (A5, R 56, 60 fps trace) |
| --- | --- | --- |
| landing | squash to ≈ 0.70 height / 1.35 width, then 2–3 damped wobble cycles (period ≈ 0.45 s, decay ≈ 0.6 per cycle) | greeting drop: 0.80 / 1.09 at +0.2 s, rebound 1.17, period 0.47 s; happy hop: 0.76 / 1.18, rebound 1.21; cheer rings 0.75 → 1.22 → 0.84 → 1.10 → 0.91 → 1.04 |
| hop | anticipation squash 0.85 for 0.12 s → air stretch up to 1.2 → land → wobble | anticipation 0.94 tall / 1.07 wide for 0.12 s, airborne 0.28 s, stretch 1.25 tall / 0.81 wide at take-off |
| poke | local dent ≈ 0.25 R that ripples around the ring and recovers in 0.5 s; eyes squint; sweat on the third quick poke | dent 0.25 R at the finger, antipode still; recovered to 0.06 R by 0.7 s; squint 0.25 s; sweat at the third press |
| idle | breath ±2.5 % at 0.29 Hz; weight shift ±4° over 2 s; micro-wobble every 8–15 s | height ±3 %, blink to 0 |
| core | lags the shell by ≈ 70 ms and overshoots ≈ 30 % | peaks 0.3–0.5 R behind on hops (clamped to 0.4 when drawn) |
| melt | spread over 0.6 s, face slides down 0.25 R | 0.61 tall / 1.39 wide by +0.35 s, held to +1.8 s, back up with a 1.06 boing |
| puff | cheeks in 0.2 s (outBack), hold, release with one wobble | 1.05 wide / 1.11 tall (sizeScale 1.06), release wobble ±1 % |
| shock | jump + stretch, `!` grows in 0.28 s | airborne at once for 0.28 s, stretch 1.22, land 0.82 / 1.13 |

Rule of thumb: eases are asymmetric (fast in, slow settle), nothing moves linearly, and everything
that stops wobbles once.

Who owns it (A5):

- **Jelly**: `SoftBodyParams` `anchorStiffness 165, damping 2.6` (ω₀ ≈ 14 rad/s, ζ ≈ 0.09, period
  0.45 s, ≈ 0.55 decay per cycle); `firm` damping 9 / anchors 220 stays calm; `bouncy` 1.8; `runny`
  P 45 / d 2.2 / g 4; `airy` g 0.6 / d 2.4; minis d 3.0 / P 50. `SoftBody.settle` runs 5 s so the
  construction transient is gone before the reference ring is taken.
- **Volume**: `bulkDamping 30` is a pressure term against the rate of area change. The breathing
  mode (every point in or out together) is near-critically damped (ζ ≈ 0.65) so the body keeps its
  volume through merges, size changes and pokes, while the shape modes, which keep the area, ring
  freely. Split droplets carry three quarters of the body's real rest area.
- **Landing**: `landed(speed:)` adds a scripted flatten complementary to what the ring already does
  (`want 0.55·clamp(speed/2.5, 0.3, 1)` minus the physics dip), keys 0.07 s outQuad → +30 % rebound
  0.16 s → −12 % 0.14 s → 1 over 0.20 s outBack. Skipped under reduce motion, morphs, sleeping, split.
- **Hop**: `hop(_:anticipation:)` squashes to 0.85 over the anticipation (0.12 s; shock uses 0), then
  `launchHop` jumps and sets `airStretch = 1 + min(0.20, 0.08·v)`; in the air the stretch chases
  `1 + 0.08·|vy|` with τ 0.08 s, so the body is thin at take-off and round at the apex.
- **Poke**: `Impulse.poke(angle:depth:)` displaces the ring (weight `max(0, n·dir)^8`, ≈ 23° half
  width) without a kick; `pressBegan` dents 0.25 R at the finger, squints for 0.25 s and sets the
  crease strain. `.poked` keeps lean + squeeze + puni, no slap.
- **Idle**: `scheduleMicroIdle` every U(8, 15) s: micro-wobble 45 %, weight shift 30 % (lean ±0.07
  over 1.0 s, hold 0.6 s, back), glance 15 %, half-lid 10 %. Breath 0.025 at 0.29 Hz.
- **Emote passes**: puff morph 0.2 s outBack with mirrored creases, release `.wobble 0.3`; melt
  face slide + bottom creases, release eases straight back (the ring supplies the boing); shock
  `hop(1.6, anticipation: 0)`; happy `hop(1.6)`; finished sparkles at +0.40 s; cry drips from under
  the stroke eyes; every morph emote ends with a `.wobble 0.12`.

## Sizes

| Where | R | Detail |
| --- | --- | --- |
| compact strip | ≈ 15–16 pt | tiny: shell + plain core + short pill + 1 px ink |
| compact minis | ≈ 7 pt | tiny |
| expanded island, desktop | 56 pt | full |
| tray minis | 14.5 pt | tiny |
| drag ghost | ≥ 24 pt | medium |
| settings preview / thumbnails | 46 pt / 32 ppu | full / medium |

Detail levels: full ≥ 36 px/R, medium ≥ 24, tiny below.

## Baseline (A0, 2026-11-09)

Captured locally into `Packages/SlimeKit/out/baseline/` (ignored by git) with the release
`slimekit-tools`: `bench.txt`, `catalog-r{56,22,15}.png` (12 palettes × 15 looks) and 48-frame
filmstrips for idle, greeting, question, chewing, sleeping and the emotes poked, happy, cheer,
melt, puff, shock, cry, hum. Release draw cost at R 56 before the work: idle 0.23 ms, grown `?`
0.36 ms, cheer 0.82 ms, chewing with arms 1.19 ms per frame.

## How to check

```sh
cd Packages/SlimeKit
swift run -c release slimekit-tools render-catalog --out out/catalog.png --radius 56   # then 22, 15
swift run -c release slimekit-tools render-filmstrip --state greeting --fps 60 --frames 90 --out out/fs
swift run -c release slimekit-tools bench
```

Read `trace.json` in a filmstrip folder for squash extremes, wobble crossings and settle time.
