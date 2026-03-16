# MEMORY.md

## User Preferences
- **No AI attribution**: Never include Co-Authored-By, AI-generated markers, or any indication of AI involvement in code, commits, or documentation. Everything should look human-written.
- **Git email**: haidinhtuan@gmail.com

## Project: MS2M Kubernetes Controller
- **Dissertation reference**: `Dissertation_Final.pdf` in project root - Ch10 (MS2M framework), Ch11 (K8s integration)
- **CRD group**: `migration.ms2m.io/v1alpha1`
- **Controller entry point**: `cmd/main.go`
- **Build**: `make build`, `make run`, `make test`
- **IONOS Cloud**: Only use token for "Hai Dinh Tuan" — shared infrastructure, always teardown after evaluation.

## Critical Deployment Notes (Bare-Metal CRIU Setup)
- See [deployment-notes.md](deployment-notes.md) for full details

## Optimization Implementation (2026-02-16) — COMPLETED
- See [optimization-state.md](optimization-state.md) for full details

## Evaluation (2026-02-18) — COMPLETED, CLUSTER TORN DOWN (2026-02-23)
- See [eval-state.md](eval-state.md) for historical cluster state
- See [validation-test-data.md](validation-test-data.md) for all test data

## Identity Swap Implementation (2026-03-01) — COMPLETED
- See [identity-swap-state.md](identity-swap-state.md) for full details

## Exchange-Fence Convergence (2026-03-15) — IMPLEMENTED
- See [exchange-fence-design.md](exchange-fence-design.md) for full algorithm + implementation details
- CRD field: `identitySwapMode: "ExchangeFence"`

## Finalize Phase Optimization (2026-03-15) — COMMITTED + PUSHED
- See [finalize-optimization-2026-03-15.md](finalize-optimization-2026-03-15.md) for full details
- **Finalize: 52.8s → 12-15s** (force-delete source pod, ParallelDrain fix, checkpoint image fallback)
- Cluster-tested at 0, 40, 120 msg/s — all pass, 0ms downtime, STS adoption correct
- **Committed + pushed** (4 commits on 2026-03-16)

## CRIU Re-Checkpoint — FIXED AND VERIFIED (2026-03-16)
- See [criu-recheckpoint-limitation.md](criu-recheckpoint-limitation.md) for full analysis
- **Two patches** in crun 1.19.1 (`/tmp/crun-src/src/libcrun/criu.c` on workers):
  1. `criu_add_cg_root(NULL, status->cgroup_path)` — fixes cgroup namespace root mismatch
  2. `criu_set_tcp_close(true)` when `tcp_established` is set — drops TCP connections on restore (consumer reconnects)
- Fork: `github.com/haidinhtuan/crun` branch `fix/cgroup-root-restore`
- Full migration verified: ShadowPod+ExchangeFence completes ~22s at 40 msg/s

## Drain Replay Mode (2026-03-01) — IMPLEMENTED
- `replayMode: "Drain"` — unbinds secondary queue, drains to zero
- See [replay-design-discussion.md](replay-design-discussion.md)

## Sampling Results (2026-03-15)
- See [sampling-results-2026-03-15.md](sampling-results-2026-03-15.md) for full data
- Post-optimization SS-Shadow-Swap: Finalize ~12-15s, 0ms downtime

## Cluster State (IONOS — STILL RUNNING, as of 2026-03-16)
- CP: 87.106.231.231, W1: 217.154.91.72, W2: 87.106.48.199
- KUBECONFIG: `eval/infra/kubeconfig`
- Controller deployed with all optimizations (rebuilt + pushed to in-cluster registry 2026-03-16)
- Producer at 40 msg/s
- **crun**: patched 1.19.1-dirty on both workers (source `/tmp/crun-src/`, binary `/usr/local/bin/crun`)
- **CRIU config**: `/etc/criu/default.conf` has `skip-in-flight` and `tcp-close` on both workers
- consumer-0 currently on worker-1, StatefulSet adopted, healthy
- **Teardown after full evaluation**

## Consumer Prefetch Fix (2026-03-15) — COMMITTED + PUSHED
- Changed `prefetch_count` from 1 to 50 in both `eval/workloads/consumer.yaml` and `consumer-deployment.yaml`
- Old throughput: ~2.4 msg/s (bottlenecked by network round-trip with prefetch=1)
- New throughput: ~50 msg/s (limited by pika event loop + 10ms processing delay + control queue polling)
- Consumer keeps up at ≤50 msg/s, falls behind at ≥60 msg/s
- This means ExchangeFence is viable at rates ≤50, Cutoff fallback at rates >50
- **Deployed to cluster** (consumer-0 restarted with new code)

## Remaining Tasks (resume here next session)
1. ~~**Commit and push** all local changes~~ — DONE (2026-03-16, 4 commits)
2. ~~**Fix re-checkpoint**~~ — DONE (2026-03-16): patched crun with cgroup_root + tcp_close, verified working
3. **Run full evaluation**: 4 configs × 7 rates × 10 reps = 280 runs
   - Configs: SS-Sequential, SS-Shadow-Swap (ExchangeFence), Deployment-Registry, Deployment-Direct
   - Rates: 10, 20, 40, 60, 80, 100, 120 msg/s
   - **IMPORTANT**: Purge queues between runs, clean checkpoint images, verify consumer ready before next run
4. **Update Overleaf** charts/tables with new evaluation data
5. **Teardown IONOS cluster** after evaluation
- **Note**: `exchangeName: "app.fanout"` required (empty string → ACCESS_REFUSED)
- **Note**: Probe must use service DNS (`consumer.default.svc...`), NOT pod-specific headless DNS

## Evaluation Configs (from Overleaf paper)
| # | Name | Workload | Strategy | Identity Swap |
|---|------|----------|----------|---------------|
| 1 | statefulset-sequential | StatefulSet | Sequential | N/A (baseline) |
| 2 | statefulset-shadowpod | StatefulSet | ShadowPod | Cutoff (MiniReplay) |
| 3 | statefulset-shadowpod-swap | StatefulSet | ShadowPod | ExchangeFence |
| 4 | deployment-registry | Deployment | ShadowPod | N/A |
- All use registry transfer. Configs 1v2 isolate ShadowPod effect, 2v3 isolate ExchangeFence effect, 2v4 isolate workload type effect.

## Key File Locations
- Controller: `internal/controller/statefulmigration_controller.go`
- Controller tests: `internal/controller/statefulmigration_controller_test.go`
- CRD types: `api/v1alpha1/types.go`
- CRD YAML: `config/crd/bases/migration.ms2m.io_statefulmigrations.yaml`
- ms2m-agent DaemonSet: `cmd/ms2m-agent/main.go`
- Eval scripts: `eval/scripts/run_evaluation.sh`, `eval/scripts/run_all_evaluations.sh`
- Eval infra: `eval/infra/` (gitignored)
