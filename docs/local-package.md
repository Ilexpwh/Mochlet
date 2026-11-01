# Local package and performance evidence

Run `./scripts/package-local.sh` to compile an Apple Silicon Release app, verify its local signature and create a unique directory under `dist/`. It contains `Mochlet.zip`, a SHA-256 checksum and a manifest recording the source revision, dirty working-tree state, deployment setting and verification limits. The script uses the full Xcode developer path without changing global settings. Failed packaging removes only that run's newly created output directory.

This is an ad-hoc signed personal build. It is not notarized or a public-distribution release. The macOS 15 deployment setting is verified in the executable; running on macOS 15 remains an independent compatibility gate. Unzip the archive and open `Mochlet.app` on the development Mac. Keep application data in Application Support separate from the app bundle and repository.

The original icon is rendered from the native slime using `./scripts/make-icon.sh`. All required macOS icon sizes are included. Coucou and GRDB notices ship in app resources and remain in `LICENSES/`.

## Measured idle sample

The [2026-11-01 Release sample](evidence/release-idle-2026-11-01.json) ran for 60 seconds with the workspace closed, compact companion visible, no coding task and no recording. Average process CPU was **0.77% of one core**, and sampled resident memory ranged from approximately **104–108 MiB**. This sample meets the quiet-idle CPU target. It does not establish interaction latency, GPU/energy consumption, child-process cost or two-hour mixed-workload stability.

Reproduce after setting up the desired native UI state:

```sh
python3 scripts/measure-idle.py <Mochlet-PID> --seconds 60 \
  --label 'Describe actual UI and workload state' --output /tmp/mochlet-idle.json
```

The sampler checks process identity throughout the run and saves raw cumulative CPU/RSS samples. It does not operate the UI or start recordings. Release walkthrough confirmed launch, workspace closure and continued compact companion operation on this development Mac.
