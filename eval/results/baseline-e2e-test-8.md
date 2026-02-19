# Baseline Migration Metrics (e2e-test-8)

Date: 2026-02-15
Cluster: bare-metal, 3 nodes (Ubuntu 22.04, K8s 1.31, CRI-O 1.31, CRIU 4.0)
Migration: consumer-0 from worker-1 to worker-2 (Sequential strategy)
Message rate: 10 msg/s (default producer rate)
Checkpoint size: ~27 MB

## Phase Timings

| Phase | Duration | Notes |
|-------|----------|-------|
| Checkpointing | 430ms | Kubelet Checkpoint API + CRIU |
| Transferring | 5.231s | OCI image build (gzip level 6) + HTTPS registry push |
| Restoring | 243ms | Pod creation on target node |
| Replaying | 2m0.354s | Cutoff reached (NOT drained); queue depth 236,410 and INCREASING |
| Finalizing | 1.601s | Cleanup |
| **Total** | **~2m8s** | |

## Known Issues at Baseline

1. **Replay broken**: Queue depth increasing (236K+ msgs), consumer not consuming from replay queue
2. **Transfer slow**: Gzip compression + HTTPS overhead for in-cluster transfer
3. **Reconcile overhead**: 5s polling for transfer job, status update conflicts ("object modified" errors)
4. **StatefulSet not handled**: StatefulSet controller recreates deleted pod on original node
5. **Pod spec incomplete**: Target pod missing labels, ports, env vars from source

## Controller Reconcile Delays

- Pending → Checkpointing: ~instant (same reconcile)
- Checkpointing → Transferring: requeue (1 reconcile cycle)
- Transferring polling: RequeueAfter 5s
- Restoring polling: RequeueAfter 2s
- Replaying polling: RequeueAfter 2s
