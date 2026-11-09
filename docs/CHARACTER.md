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

## Motion (anime timing)

| Beat | Target |
| --- | --- |
| landing | squash to ≈ 0.70 height / 1.35 width, then 2–3 damped wobble cycles (period ≈ 0.45 s, decay ≈ 0.6 per cycle) |
| hop | anticipation squash 0.85 for 0.12 s → air stretch up to 1.2 → land → wobble |
| poke | local dent ≈ 0.25 R that ripples around the ring and recovers in 0.5 s; eyes squint; sweat on the third quick poke |
| idle | breath ±2.5 % at 0.29 Hz; weight shift ±4° over 2 s; micro-wobble every 8–15 s |
| core | lags the shell by ≈ 70 ms and overshoots ≈ 30 % |
| melt | spread over 0.6 s, face slides down 0.25 R |
| puff | cheeks in 0.2 s (outBack), hold, release with one wobble |
| shock | jump + stretch, `!` grows in 0.28 s |

Rule of thumb: eases are asymmetric (fast in, slow settle), nothing moves linearly, and everything
that stops wobbles once.

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
