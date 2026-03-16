---
name: sampling-results-2026-03-15
description: Sampling results for all 5 migration configs plus post-optimization SS-Shadow-Swap results from IONOS cluster
type: project
---

## Sampling Results (2026-03-15) — Pre-Optimization

**Why:** First cluster evaluation with Exchange-Fence identity swap, Drain replay mode, and all 5 configs. Validates all configs work before full evaluation.

**How to apply:** Use as baseline reference for full evaluation. Compare against these numbers to detect regressions or anomalies.

### Cluster
- CP: 87.106.231.231, W1: 217.154.91.72, W2: 87.106.48.199
- K8s 1.31, CRI-O with CRIU 4.0, crun-wrapper (`--tcp-established`), `/etc/criu/default.conf` (`skip-in-flight`)
- `checkpoint-transfer:latest` loaded on both workers via skopeo

### Pre-Optimization Results (0 msg/s)

| Config | Total Time | Downtime | Checkpoint | Transfer | Restore | Replay | Finalize |
|--------|-----------|----------|------------|----------|---------|--------|----------|
| SS-Sequential | 78.8s | 34,069ms | 452ms | 205ms | 38.4s | 35.8s | 825ms |
| SS-Shadow (no swap) | 13.0s | 0ms | 415ms | 203ms | 2.3s | 6.5s | 538ms |
| SS-Shadow-Swap (ExchangeFence) | 66.6s | 0ms | 370ms | 193ms | 2.6s | 8.8s | 52.8s |
| Deployment-Registry | 13.0s | 0ms | 493ms | 196ms | 2.7s | 6.8s | 846ms |
| Deployment-Direct | 16.5s | 0ms | 410ms | 4.8s | 2.9s | 9.1s | 201ms |

### Post-Optimization SS-Shadow-Swap Results

After ParallelDrain fix + PrepareSwap force-delete + checkpoint image fallback:

| Rate | Total | Downtime | Checkpoint | Transfer | Restore | Replay | Finalize |
|------|-------|----------|------------|----------|---------|--------|----------|
| 0 msg/s | ~24s | 0ms | 394ms | 1.2s | 2.9s | 7.1s | **12.1s** |
| 40 msg/s | ~26s | 0ms | 395ms | 1.3s | 3.0s | 8.2s | **12.6s** |
| 120 msg/s | ~26s | 0ms | 436ms | 185ms | 2.1s | 8.3s | **15.3s** |

**Key improvement: Finalize 52.8s → 12-15s (77% reduction)**

### Observations
- **SS-Sequential**: ~34s downtime (source deleted before restore). Restore takes ~38s (full pod creation + pip install + CRIU restore)
- **SS-Shadow (no swap)**: 0ms downtime, fast (13s) — but leaves orphaned shadow pod. Not production-viable for StatefulSets.
- **SS-Shadow-Swap**: 0ms downtime. Finalize now 12-15s (was 52.8s). Re-checkpoint uses fallback (cgroup v2 limitation)
- **Deployment-Registry**: Fastest total (13s). 0ms downtime.
- **Deployment-Direct**: Slightly slower (16.5s) due to Direct transfer (4.8s vs 196ms registry)
- **All ShadowPod configs achieve 0ms HTTP downtime** (service-level)

### Scripts
- Sampling script: `/tmp/run_sampling_downtime_v2.sh` (with proper cleanup between runs)
- Probe logs: `/tmp/probe-dt-*.log` on local machine
