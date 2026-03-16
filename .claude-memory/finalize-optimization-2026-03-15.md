---
name: finalize-optimization-2026-03-15
description: Finalize phase optimizations reducing SS-Shadow-Swap from 52s to 12s — force-delete, ParallelDrain fix, checkpoint image fallback
type: project
---

## Finalize Phase Optimization (2026-03-15) — IMPLEMENTED + CLUSTER TESTED

**Why:** SS-Shadow-Swap Finalize was 52.8s, dominated by two bottlenecks: ParallelDrain (62s waiting for primary queue) and pod termination (28s from STS controller's 30s grace period). Both fixed, bringing Finalize to ~12s.

**How to apply:** These changes are in the controller code but NOT yet committed/pushed. Must build+deploy before evaluation.

### Changes Made

1. **PrepareSwap force-delete** (main fix, saves ~28s):
   - After STS scale-down, immediately removes Service labels (traffic bridge) and force-deletes source pod with `GracePeriodSeconds: 0`
   - Previously: STS controller deleted pod with default 30s grace; our 1s force-delete in CreateReplacement didn't override it
   - Now: pod is gone instantly in PrepareSwap, CreateReplacement finds NotFound and creates replacement immediately

2. **ParallelDrain fix** (saves ~60s, done earlier in session):
   - Changed drain condition from waiting for BOTH primary+swap queues to only waiting for swap queue
   - Primary queue drains naturally after TrafficSwitch; waiting for it was unnecessary and took 62s

3. **Checkpoint image fallback** (correctness fix):
   - CreateReplacement now checks `PhaseTimings["Swap.ReCheckpoint.fallback"]` flag
   - Fallback case: uses registry image (`PullAlways`) instead of non-existent `localhost/checkpoint/...:recheckpoint` (`PullNever`)
   - Without this fix, replacement pod would fail with ErrImageNeverPull in clean environments

4. **All force-delete grace periods**: Changed from `int64(1)` to `int64(0)` in 3 places (CreateReplacement, TrafficSwitch, FenceCutover)

### Test Results (cluster-verified)

| Test | Finalize | Downtime | Result |
|------|----------|----------|--------|
| 0 msg/s | 12.1s | 0ms | Pass |
| 40 msg/s | 12.6s | 0ms (1 DNS blip) | Pass |
| 120 msg/s | 15.3s | 0ms (1 DNS blip) | Pass |

All tests: STS adoption correct, no orphaned pods, all queues cleaned up.

### Before/After

| Metric | Before | After |
|--------|--------|-------|
| Finalize | 52.8s | 12-15s |
| Pod termination | 28s | 0s |
| ParallelDrain | 62s | N/A (fixed) |
| Total SS-Shadow-Swap | ~67s | ~26s |

### Known Limitations

- **Re-checkpoint still fails**: CRIU cgroup v2 namespace mismatch after restore — cannot re-checkpoint a CRIU-restored container. Falls back to original checkpoint image. This means replacement pod has stale state (from before shadow ran). Not fixable without CRIU upstream changes.
- **Swap queue messages deleted at cutoff**: At high rates (>40 msg/s), MiniReplay 15s cutoff doesn't drain all swap messages. Remaining are deleted in TrafficSwitch. These are duplicates (also on primary queue, consumed by shadow), so no data loss.
- **Headless DNS gap**: Pod-specific DNS (`consumer-0.consumer...`) has a gap between source deletion and replacement creation (~3-5s). Service-level DNS (`consumer.default...`) has 0ms downtime via traffic bridge.

### Code Locations

- PrepareSwap force-delete: `internal/controller/statefulmigration_controller.go` ~line 1024-1065 (inside `handleSwapPrepare`)
- Checkpoint image fallback: same file, `handleSwapCreateReplacement` ~line 1394-1404
- ParallelDrain fix: same file, `handleSwapParallelDrain` — condition changed to `swapTotal == 0`

### Deployment Status

- Code changes: local only, NOT committed/pushed
- Controller image: built and deployed to cluster registry (`registry.registry.svc.cluster.local:5000/ms2m-controller:latest`)
- Tests: `go test ./internal/controller/` — all passing
