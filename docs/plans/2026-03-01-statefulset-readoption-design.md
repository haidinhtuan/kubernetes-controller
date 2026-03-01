# StatefulSet Post-Migration Ownership

## Problem

After migration, target/shadow pods are orphaned from their StatefulSet. This manifests differently per strategy:

**Sequential strategy**: Target pod has the correct name (`consumer-0`) but `ownerReferences` point to the `StatefulMigration` CR with `controller: true`. The StatefulSet controller cannot adopt this pod and cannot create a new one (name conflict).

**ShadowPod strategy**: Shadow pod (`consumer-0-shadow`) cannot be adopted due to its name (fails the StatefulSet `isMemberOf()` regex). The shadow pod serves traffic correctly but if it crashes, nobody restarts it.

## Current State

### Sequential: Fixed

In `handleFinalizing`, the controller removes the `StatefulMigration` ownerReference from the target pod before scaling the StatefulSet back up. The StatefulSet controller finds the orphan pod (matching name + labels) and adopts it automatically. Full StatefulSet guarantees (crash recovery, ordered scaling) are restored.

### ShadowPod + StatefulSet: Fixed (Identity Swap)

The ShadowPod strategy achieves zero downtime for StatefulSet migration (confirmed across 140 evaluation runs). After migration completes, the controller performs a local identity swap:
- Re-checkpoints the shadow pod on the target node
- Creates a correctly-named replacement pod (`consumer-0`) from the checkpoint
- Replays buffered messages to the replacement pod
- Deletes the shadow pod and scales the StatefulSet back up for adoption

Full StatefulSet guarantees (crash recovery, ordered scaling) are restored. The swap executes as sub-phases within the Finalizing phase, tracked by the `SwapSubPhase` status field.

## Design: Local Identity Swap (Implemented)

### Approach

After ShadowPod migration completes, re-checkpoint the shadow pod locally on the target node, create a correctly-named replacement pod (`consumer-0`), replay buffered messages, and let the original StatefulSet adopt the replacement. All operations are node-local (no network transfer, no registry push).

### Alternatives Considered

1. **Rename shadow pod**: Kubernetes does not allow renaming pods after creation.
2. **Rename StatefulSet to match shadow pod**: Changes workload identity (`consumer` → `consumer-shadow`), breaks DNS, cascading reference updates, leaks migration history into production topology.
3. **Container runtime manipulation**: Modify pod metadata at containerd/CRI level. Bypasses Kubernetes API, fragile, version-dependent.
4. **StatefulSet controller patch**: Modify adoption logic to accept non-standard names. Fighting upstream Kubernetes internals.
5. **Direct state copy without checkpoint**: Inject state into replacement pod's memory. Requires application-specific knowledge, breaks encapsulation.

All alternatives were rejected. The local identity swap is the only approach that preserves workload identity, uses standard Kubernetes APIs, and reuses existing migration machinery.

### Sub-Phases within Finalizing

The swap executes as sub-phases inside the existing Finalizing phase. Only activates for `ShadowPod` + `StatefulSet` combinations. All other paths (Sequential+StatefulSet, ShadowPod+Deployment) are unchanged.

#### Sub-phase 1: PrepareSwap

- Create a secondary queue (fan-out binding) on the shadow pod's message queue
- This buffers all incoming messages from the moment the swap begins
- Verify the shadow pod is healthy and serving

#### Sub-phase 2: ReCheckpoint

- Call the kubelet checkpoint API on the shadow pod (target node, local)
- Produces a new checkpoint archive on the same node
- Shadow pod continues running during checkpoint (CRIU freeze is brief, ~100-500ms)
- No network transfer — checkpoint stays on the local node

#### Sub-phase 3: CreateReplacement

- Build OCI image from the local checkpoint (no registry push)
- Create pod `consumer-0` with:
  - Labels matching the StatefulSet's pod template selector (for adoption)
  - No `controller: true` ownerRef (so StatefulSet can claim it)
  - Same volumes, env vars, resource requests as the original pod template
- Wait for the replacement pod to reach Running state

#### Sub-phase 4: MiniReplay

- Drain the secondary queue (messages buffered since sub-phase 1) into the replacement pod
- Wait until secondary queue depth = 0
- Send a cutoff control message and wait for acknowledgment

#### Sub-phase 5: TrafficSwitch

- Delete the shadow pod (`consumer-0-shadow`)
- The replacement pod `consumer-0` already has matching labels — Service routes to it immediately
- Scale up the StatefulSet — it discovers the orphan pod (matching name + labels, no conflicting controller ownerRef) and adopts it
- Remove the secondary queue
- Clean up local checkpoint archive

### Traffic Interruption Analysis

| Sub-phase | Shadow Pod | Replacement Pod | Traffic Impact |
|-----------|-----------|----------------|----------------|
| PrepareSwap | Serving | Does not exist | None |
| ReCheckpoint | Serving (brief CRIU freeze ~100-500ms) | Does not exist | None |
| CreateReplacement | Serving | Starting up | None |
| MiniReplay | Serving | Receiving replay | None |
| TrafficSwitch | Deleted | Serving via Service | Immediate (label-based routing) |

**Total overhead**: ~7-10 seconds, all local operations on the target node.

### State Machine Tracking

New status field `SwapSubPhase` (string) tracks progress through the identity swap:

```
"" → "PrepareSwap" → "ReCheckpoint" → "CreateReplacement" → "MiniReplay" → "TrafficSwitch" → ""
```

When `SwapSubPhase` returns to `""`, normal Finalizing completion proceeds (mark Completed).

### Error Handling & Idempotency

Each sub-phase is idempotent. If the controller restarts mid-swap:

- **PrepareSwap**: Check if secondary queue exists, create only if missing
- **ReCheckpoint**: Re-checkpoint (overwrites previous archive)
- **CreateReplacement**: Check if `consumer-0` already exists, skip creation if so
- **MiniReplay**: Continue draining from wherever the secondary queue is
- **TrafficSwitch**: Check if shadow pod still exists, delete if so; check StatefulSet scale

If the entire swap fails, the shadow pod is still serving traffic. The system degrades gracefully to the current "working but orphaned" state, which is safe.

### CRD Changes

Add to `StatefulMigrationStatus`:

```go
// SwapSubPhase tracks progress of the local identity swap for ShadowPod+StatefulSet.
// Empty when not performing a swap.
SwapSubPhase string `json:"swapSubPhase,omitempty"`

// ReplacementPod is the name of the correctly-named replacement pod created during identity swap.
ReplacementPod string `json:"replacementPod,omitempty"`
```

### Scope

- **In scope**: ShadowPod + single-replica StatefulSet identity swap within Finalizing
- **Out of scope**: Changes to other migration strategies, changes to phases before Finalizing, multi-replica StatefulSet migration

### Multi-Replica Limitation

StatefulSet scale-down always removes the highest-ordinal pod. You cannot selectively remove a specific ordinal (e.g., ordinal 0 in a 3-replica set) without scaling to 0. For multi-replica StatefulSets, the identity swap is only safe when migrating the highest-ordinal pod (since it matches the scale-down target) or when replicas=1 (evaluated and validated across 140 runs). A future enhancement could use `StatefulSet.spec.ordinals` (K8s 1.26+) or partition-based rolling updates to support arbitrary ordinal migration.
