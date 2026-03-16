# Optimization Implementation State (2026-02-16)

## Overview
Three-phase optimization to reduce migration time from ~55.7s to <15s.
- **Design doc**: `docs/plans/2026-02-16-optimization-design.md` (approved)
- **Implementation plan**: `docs/plans/2026-02-16-optimization-implementation.md` (9 tasks)
- **Research**: `docs/research/optimization-approaches-2026-02.md` (8 approaches A-H evaluated)

## Decision History
- User rejected "Continuous Migration Readiness" as wasteful (2x resources for rare event)
- User rejected StatefulSet-focused approaches — message consumers don't need stable pod identity
- User chose three practical engineering optimizations over novel research approaches
- Discarded: Service Mesh (E), Event Replay (F), StatefulSet ShadowPod (A)
- Kept baseline (StatefulSet Sequential) for evaluation comparison

## Three Optimizations

### 1. Deployment-based Workload (Restoring: 39.1s → ~3-5s) — IMPLEMENTED
- Consumer runs as Deployment instead of StatefulSet
- ShadowPod strategy works without identity conflicts
- Controller detects Deployment via ReplicaSet ownerRef chain in `handlePending`
- `handleFinalizing` patches Deployment with nodeAffinity for target node
- **Files**: `eval/workloads/consumer-deployment.yaml`, controller Pending/Finalizing

### 2. Direct Node-to-Node Transfer (Transferring: 5.9s → ~1-2s) — IMPLEMENTED
- ms2m-agent DaemonSet on each worker node
- Transfer Job POSTs checkpoint tar via HTTP to agent on target node
- Agent builds OCI image locally, loads into CRI-O via `skopeo copy oci:... containers-storage:...`
- No registry involved
- **New CRD field**: `spec.transferMode: "Direct"` (default: `"Registry"`)
- **Files**: `cmd/ms2m-agent/main.go`, `config/daemonset/ms2m-agent.yaml`, `internal/checkpoint/image.go`

### 3. Background Pre-dumps (Checkpointing: 478ms → <50ms) — DESIGN ONLY
- Task 9 in plan, marked optional/high-risk
- Requires CRIU pre-dump with soft-dirty bit tracking from DaemonSet context
- Needs `hostPID: true` and direct CRIU access (not kubelet API)
- **Not implemented** — needs cluster SSH to prototype

## Implementation Status (Tasks 1-8 COMPLETE)

| Task | Description | Status |
|------|-------------|--------|
| 1 | Deployment consumer manifest | Done |
| 2 | Controller Deployment detection (handlePending) | Done |
| 3 | Controller Deployment finalization (handleFinalizing) | Done |
| 4 | CRD TransferMode field | Done |
| 5 | Shared checkpoint image building package | Done |
| 6 | ms2m-agent DaemonSet | Done |
| 7 | Wire Direct transfer in controller Transferring/Restoring | Done |
| 8 | Evaluation scripts (run_optimized_evaluation.sh) | Done |
| 9 | Background pre-dumps | Not started (optional) |

## Code Changes Summary

### New files
- `eval/workloads/consumer-deployment.yaml` — Deployment variant of consumer
- `internal/checkpoint/image.go` + `image_test.go` — Shared OCI image building
- `cmd/ms2m-agent/main.go` + `main_test.go` — DaemonSet HTTP server
- `config/daemonset/ms2m-agent.yaml` — DaemonSet + Service manifest
- `Dockerfile.agent` — Multi-stage build for ms2m-agent
- `eval/scripts/run_optimized_evaluation.sh` — Multi-config evaluation

### Modified files
- `api/v1alpha1/types.go` — Added `TransferMode` (spec), `DeploymentName` (status)
- `internal/controller/statefulmigration_controller.go` — Deployment detection, Direct transfer, nodeAffinity patching
- `internal/controller/statefulmigration_controller_test.go` — 7+ new tests
- `cmd/checkpoint-transfer/main.go` — Refactored to shared package + direct HTTP mode
- `config/crd/bases/migration.ms2m.io_statefulmigrations.yaml` — New fields
- `eval/scripts/run_evaluation.sh` — Added configuration column to CSV
- `Makefile` — Added `agent-build`, `agent-docker-build` targets

## Git State
- 12 commits on main ahead of origin/main
- All tests passing (`go test ./...` — 8 packages OK)
- No uncommitted changes

## Key Commits
```
a0b9da0 docs: add optimization research and literature survey
f9dd072 eval: add optimized evaluation script
95b86d6 feat: wire Direct transfer mode through controller
ef270da feat: patch Deployment nodeAffinity during ShadowPod finalization
6e6631b feat: detect Deployment owner and record in migration status
bbab007 feat: add ms2m-agent DaemonSet for direct checkpoint transfer
b4a94d7 feat: add TransferMode field and direct HTTP transfer
3251642 refactor: extract checkpoint image building into shared package
f804476 eval: add Deployment variant of consumer workload
204b6bf docs: add detailed optimization implementation plan
bfdff39 docs: add optimization design
```

## Evaluation Matrix (to be validated on cluster)

| Configuration | Restoring | Transferring | Checkpointing | Expected Total |
|---|---|---|---|---|
| StatefulSet + Sequential + Registry (baseline) | 39.1s | 5.9s | 478ms | ~55.7s |
| Deployment + ShadowPod + Registry | ~3-5s | 5.9s | 478ms | ~20s |
| Deployment + ShadowPod + Direct | ~3-5s | ~1-2s | 478ms | ~15s |

Test matrix: msg rates 1, 5, 10, 20, 50, 100, 200 msg/s × 10 repetitions each.

## Evaluation Script Usage
```bash
# Baseline
NAMESPACE=ms2m TARGET_NODE=worker-2 REPETITIONS=10 MSG_RATES="1 5 10 20 50 100 200" \
  bash eval/scripts/run_evaluation.sh

# Optimized (3 configurations)
CONFIGURATION=deployment-registry NAMESPACE=ms2m TARGET_NODE=worker-2 \
  REPETITIONS=10 MSG_RATES="1 5 10 20 50 100 200" \
  bash eval/scripts/run_optimized_evaluation.sh

CONFIGURATION=deployment-direct NAMESPACE=ms2m TARGET_NODE=worker-2 \
  REPETITIONS=10 MSG_RATES="1 5 10 20 50 100 200" \
  bash eval/scripts/run_optimized_evaluation.sh
```

## Next Steps
1. **Push to origin** — 12 commits ready
2. **Deploy to IONOS cluster** — controller image + ms2m-agent DaemonSet + consumer-deployment
3. **Run evaluation** — all 3 configurations × 7 message rates × 10 reps
4. **Task 9 (optional)** — Background pre-dumps, needs SSH to cluster node to test CRIU pre-dump from DaemonSet
5. **Analyze results** — Compare configurations, produce dissertation charts
