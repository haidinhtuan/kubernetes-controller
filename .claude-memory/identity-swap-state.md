# Identity Swap Implementation State (2026-03-01)

## Problem Solved
After ShadowPod+StatefulSet migration, the shadow pod (`consumer-0-shadow`) was orphaned — not owned by the StatefulSet. No crash recovery, no ordered scaling. The identity swap fixes this by creating a correctly-named replacement pod that the StatefulSet can adopt.

## Two Fixes Implemented

### 1. Sequential + StatefulSet: ownerRef Removal
- In `handleFinalizing`, remove `StatefulMigration` ownerRef from target pod before scaling StatefulSet back up
- StatefulSet finds orphan pod (matching name + labels), adopts it
- Commit: `eb1ed79`

### 2. ShadowPod + StatefulSet: Local Identity Swap
6 sub-phases within Finalizing, tracked by `SwapSubPhase` status field:
1. **PrepareSwap**: Create secondary queue for message buffering during swap
2. **ReCheckpoint**: Checkpoint shadow pod on target node (local, no network)
3. **SwapTransfer**: Build OCI image from re-checkpoint tar, push to registry with `:recheckpoint` tag
4. **CreateReplacement**: Scale down STS, create `consumer-0` from `:recheckpoint` image, scale up STS with target nodeSelector
5. **MiniReplay**: Drain buffered messages into replacement, send START_REPLAY
6. **TrafficSwitch**: Delete shadow pod, send END_REPLAY

### Commits (11 total, pushed to origin/main)
```
d2a7a04 Add SwapSubPhase and ReplacementPod status fields for identity swap
17c268a Add failing test for ShadowPod+StatefulSet identity swap entry
e485a63 Implement identity swap entry and PrepareSwap sub-phase
a4889e6 Implement ReCheckpoint sub-phase for identity swap
fbceada Implement CreateReplacement sub-phase for identity swap
69ffbfe Implement MiniReplay sub-phase for identity swap
7ddba37 Implement TrafficSwitch sub-phase for identity swap
343629a Update ShadowPod+StatefulSet tests for identity swap behavior
3cf0bb1 Add end-to-end test for ShadowPod+StatefulSet identity swap
f03650f Update documentation for StatefulSet identity swap
c5f782b Add SwapTransfer sub-phase and fix identity swap bugs
```

## Overleaf Paper Updates
- Abstract: identity swap instead of "scaled down by one replica"
- Design section: full 5-step identity swap procedure added
- Trade-offs: "planned as future work" → implemented description
- Evaluation discussion: "temporarily decouples, identity swap restores"
- Conclusion: identity swap instead of "scaling down during finalization"
- Future work: re-adoption removed → multi-replica limitation added

## Scope Limitation
- **Single-replica StatefulSets only** — validated across 140 eval runs
- Multi-replica: StatefulSet scale-down always removes highest-ordinal pod, can't selectively remove a specific ordinal
- Investigated alternatives: `spec.ordinals` (1.26+), partition rolling updates, `pod-deletion-cost` — none solve the problem
- Direct pod deletion races with StatefulSet controller (would recreate pod with no state = data loss)

## Key Design Decisions
- Swap queue uses `.ms2m-replay` suffix (matches mock's CreateSecondaryQueue behavior)
- Replacement pod has NO controller ownerRef (allows StatefulSet adoption)
- Replacement pod gets source labels only (no migration labels)
- Phase chaining drives all sub-phases in a single Reconcile call when pods are Running
- `handleFinalizing` guards END_REPLAY/DeleteSecondaryQueue behind `SwapSubPhase == ""` to prevent re-running during swap

## Evaluation Note
- All 210 eval runs used **Registry transfer** (not Direct)
- Direct transfer (ms2m-agent) is implemented but NOT evaluated
- Paper correctly states "not included in the main evaluation matrix"
- Identity swap adds ~50s to Finalizing (observed: 50.5s in test-swap-13)
- Need to re-run evaluation to measure actual Finalizing overhead with identity swap

## Cluster-Tested Bugs Fixed (c5f782b)
- **Re-checkpoint image ref**: Initial code used `:checkpoint` tag for replacement pod; now uses `:recheckpoint` via new SwapTransfer sub-phase
- **STS adoption race**: STS at replicas=0 would adopt and delete our replacement pod, then recreate on wrong node. Fix: scale up STS + patch nodeSelector to target in single update after pod creation
- **Finalizing timing**: Was only capturing last reconcile (~29ms). Now uses persistent `Finalizing.start` key in PhaseTimings
- **SwapSubPhase re-entry**: After TrafficSwitch cleared SwapSubPhase to "", next reconcile matched `case ""` and re-entered PrepareSwap. Fix: check `ReplacementPod != ""` before entering swap
- **SwapSubPhase omitempty**: Removed `omitempty` from JSON tag so empty string is included in merge patches
- **CRIU cgroup path**: Patched `proc_parse.c` to handle systemd cgroup suffix mismatch (separate from this commit)
