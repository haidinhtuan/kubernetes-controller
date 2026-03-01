# StatefulSet Re-Adoption Design

## Problem

After migration of StatefulSet-owned pods, the target pod is orphaned from its StatefulSet. This affects both migration strategies:

**Sequential strategy**: Target pod is named correctly (`consumer-0`) but has `ownerReferences` pointing to the `StatefulMigration` CR with `controller: true`. The StatefulSet controller cannot adopt this pod (another controller owns it) and cannot create a new one (name conflict). The StatefulSet gets stuck.

**ShadowPod strategy**: Shadow pod is named `consumer-0-shadow`, which fails the StatefulSet controller's `isMemberOf()` regex check (`(.*)-([0-9]+)$`). Even without the ownerRef conflict, the name prevents adoption entirely.

In both cases, if the shadow/target pod crashes, nobody restarts it. The StatefulSet's guarantees (stable identity, ordered scaling, PVC binding, crash recovery) are lost.

## Constraints

- Kubernetes does not allow renaming a running pod
- StatefulSet adoption requires: (1) matching label selector, (2) pod name matching `<sts-name>-<ordinal>`, (3) no conflicting controller ownerRef
- The shadow pod's live state (accumulated during replay + normal operation) must not be lost during re-adoption
- No new phases added to the state machine; all re-adoption logic lives within Finalizing
- Multi-replica StatefulSets must not have non-migrated pods disrupted

## Solution: Strategy-Specific Re-Adoption in Finalizing

### Sequential Strategy (Simple Path)

The target pod already has the correct StatefulSet-compatible name (`consumer-0`). Fix:

1. Remove StatefulMigration `ownerReferences` from target pod (makes it an orphan)
2. Scale StatefulSet back to `OriginalReplicas`
3. StatefulSet controller finds orphan pod with matching name + labels, adopts it automatically
4. Close broker, mark Completed

No re-checkpoint needed. One patch call + one scale operation.

### ShadowPod Strategy (Re-Checkpoint Swap with Mini-Replay)

The shadow pod (`consumer-0-shadow`) cannot be adopted due to its name. Solution: re-checkpoint the shadow pod, create a correctly-named replacement, and use a mini-replay round to ensure zero state loss.

**Queue naming**: The mini-replay queue reuses the name `<queue>.ms2m-replay` — the same suffix as the original secondary queue. This works because `handleFinalizing` deletes the original secondary queue before entering the re-adoption flow. `CreateSecondaryQueue` hardcodes this suffix, so we reuse it rather than introducing a new naming convention.

**Broker cleanup ordering**: On first entry to `handleFinalizing`, the standard broker cleanup (END_REPLAY + delete secondary queue) runs before entering the re-adoption flow. On subsequent reconciles (when `AdoptionSubPhase` is already set), `handleFinalizing` skips directly to `handleShadowPodAdoption`, bypassing the broker cleanup to avoid error noise from operating on already-deleted queues.

**Source pod removal**: The source pod is deleted directly (not via StatefulSet scaling). This avoids disrupting non-migrated pods in multi-replica StatefulSets. With `OrderedReady` policy, scaling down removes the highest ordinal — not necessarily the source pod. Direct deletion avoids this problem entirely. The StatefulSet controller will attempt to recreate the pod, but the replacement pod (created immediately after deletion) occupies the name slot. The StatefulSet then adopts the replacement as an orphan.

Sequence within `handleFinalizing`:

```
 1. Send END_REPLAY                        -> shadow pod switches to primary queue
 2. Delete original secondary queue        -> standard cleanup
 3. Create mini-replay queue               -> reuses .ms2m-replay suffix via CreateSecondaryQueue
 4. Re-checkpoint shadow pod               -> kubelet API on target node, captures current state
 5. Run transfer job on target node        -> builds OCI image (respects TransferMode spec)
 6. Delete source pod directly             -> frees the name slot for replacement
 7. Create `consumer-0` pod               -> from re-checkpoint image, on target node
                                              labels match StatefulSet selector
                                              NO ownerRef (created as orphan)
 8. Wait for `consumer-0` Running
 9. Send START_REPLAY to `consumer-0`      -> consumes from mini-replay queue
10. Poll mini-replay queue depth           -> wait until drained (~10-20s of messages)
11. Send END_REPLAY to `consumer-0`        -> switches to primary queue
12. Delete shadow pod                      -> traffic moves to consumer-0
13. Delete mini-replay queue
14. Close broker, mark Completed
    StatefulSet automatically adopts consumer-0 (orphan with matching name + labels)
```

### Why Mini-Replay Eliminates the State Gap

- Step 3 creates a fanout exchange, so every message after this point goes to BOTH the primary queue (shadow pod consumes) AND the mini-replay queue
- Step 4 captures the shadow pod's state at this exact moment
- Between steps 4-12, the shadow pod continues processing from the primary queue. Those same messages accumulate in the mini-replay queue
- `consumer-0` starts from the re-checkpoint snapshot (step 4) and replays the mini-replay queue to reach identical state
- Once the mini-replay queue is drained, `consumer-0` has the same state as the shadow pod
- Shadow pod deletion is safe; `consumer-0` takes over seamlessly

This reuses the exact same machinery as the main migration (CreateSecondaryQueue, SendControlMessage, GetQueueDepth).

## Sub-Phase Tracking

Since this is a multi-step async process within Finalizing, track progress using an `AdoptionSubPhase` status field:

| Sub-phase | Meaning |
|---|---|
| (empty) | First entry: broker cleanup, mini-replay queue setup, re-checkpoint |
| `transferring` | Transfer job running on target node |
| `replacing` | Source pod deleted, replacement pod created, waiting for Running |
| `replaying` | Mini-replay in progress, polling queue depth |
| `adopted` | Replacement pod running, shadow pod deleted, completing |

On re-entry (when `AdoptionSubPhase != ""`), `handleFinalizing` dispatches directly to the sub-phase handler, skipping the standard broker cleanup.

## Changes Required

| Component | Change |
|---|---|
| `api/v1alpha1/types.go` | Add `AdoptionSubPhase string` and `ReCheckpointID string` to `StatefulMigrationStatus` |
| `internal/controller/statefulmigration_controller.go` | Extend `handleFinalizing`: early dispatch when sub-phase set; Sequential path removes ownerRef + scales up; ShadowPod path runs re-checkpoint swap with mini-replay |
| `internal/messaging/client.go` | No change. Reuse `CreateSecondaryQueue`, `DeleteSecondaryQueue`, `SendControlMessage`, `GetQueueDepth` |
| `config/crd/bases/migration.ms2m.io_statefulmigrations.yaml` | Add `adoptionSubPhase` and `reCheckpointID` fields to CRD status |
| `internal/controller/statefulmigration_controller_test.go` | Tests for both re-adoption paths |

## Non-StatefulSet Pods

No change for Deployments or standalone pods. The re-adoption logic only activates when `m.Status.StatefulSetName != ""`. The existing Finalizing flow (Deployment nodeAffinity patching, source pod deletion) remains unchanged.

## Failure Modes

| Failure | Impact | Recovery |
|---|---|---|
| Re-checkpoint fails | Shadow pod still serving, no data loss | Controller retries on next reconcile (AdoptionSubPhase still empty) |
| Transfer job fails | Shadow pod still serving | Retry transfer job (idempotent job check) |
| Replacement pod fails to start | Shadow pod still serving | Controller retries pod creation |
| Mini-replay queue stalls | Shadow pod serving, consumer-0 catching up | Replay cutoff timeout applies |
| Source pod delete races with StatefulSet recreate | StatefulSet tries to create consumer-0, gets AlreadyExists | StatefulSet's next reconcile adopts the orphan pod |
| StatefulSet adoption fails | consumer-0 running as orphan | Eventually consistent; StatefulSet reconcile loop will adopt on next cycle |

The shadow pod acts as a safety net throughout the entire process. At no point is traffic interrupted or state lost due to a failure in the re-adoption flow.
