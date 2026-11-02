# Native performance baseline

This record separates measured results from release targets. It does not establish that the complete native-quality gate has passed.

## Reference environment — 2026-11-02

| Property | Observed value |
|---|---|
| Hardware | Apple Silicon, model `Mac17,9`, 18 logical CPUs, 24 GiB RAM |
| Running OS | macOS 27.0, build 26A428 |
| Build | Native arm64 Release, optimized, source `d0bc945` |
| Toolchain | Xcode 27.2 at `/Applications/Xcode.app/Contents/Developer` |
| Deployment setting | macOS 15.0; actual macOS 15 execution remains unverified |
| Display | Built-in Retina Display, 1512 × 982 logical points |
| Refresh cadence | Not measured; no frame-rate claim |
| Idle workload | Right-edge compact companion, workspace closed, unsent draft retained, no running coding task, recording or synchronization |

The normal Release app was launched through the native UI after the older idle build was closed. The unsent draft was restored without submission. No new account grants, recordings or external writes were performed. The sampler watches this app's PID and verifies its executable/start identity throughout; it does not control the app or keep it in a synthetic hidden state.

## Measurements

**Five-minute result:** 300.019 seconds, 2.27 seconds of app CPU time, averaging **0.7566% of one core**. Sampled RSS ranged from **105.7 to 105.8 MiB**. This passes the specified <1% quiet-idle CPU target for this workload. It does not establish physical footprint or active-workload memory limits.

The result and raw five-second samples are retained in [release-idle-2026-11-02.json](evidence/release-idle-2026-11-02.json). CPU is cumulative app CPU time divided by elapsed monotonic time, as a percentage of one CPU core. RSS is sampled resident memory, not the macOS physical-footprint metric.

The earlier [60-second sample](evidence/release-idle-2026-11-01.json) averaged 0.77% of one core, with sampled RSS approximately 104–108 MiB. It was shorter than the defined five-minute window and is retained as historical evidence.

## Still open

- P95 warm input to visible acknowledgement ≤100 ms, measured with native event/frame evidence.
- Frame cadence and repeatable >100 ms stalls under expansion, output streaming and file intake.
- Active workload and child-process memory/CPU; physical footprint, GPU/energy and thermal behavior.
- Two-hour mixed-workload stability with sleep/wake, real display changes and provider interruption.
- Voice/meeting recording and language-quality performance on consented samples.

No target has been relaxed. T32/Q05 and the complete release milestone remain unchecked. Reproduction uses [the local package and sampler instructions](local-package.md).
