---
name: exchange-fence-design
description: Exchange-Fence Convergence — implemented in controller with adaptive strategy, all tests passing
type: project
---

## Exchange-Fence Convergence (2026-03-15) — IMPLEMENTED, ALL TESTS PASSING

**Why:** MiniReplay during identity swap has duplicate + state gap flaws. Exchange-Fence eliminates both via broker topology as consistent-cut primitive.

**How to apply:** Controlled via `identitySwapMode` CRD field: "ExchangeFence", "Cutoff", or "None".

### Implementation Status (2026-03-15)
- **All code complete**: 4 new sub-phases + adaptive decision + rollback + restructured accumulation window
- **8 new tests** + 10 existing tests updated — all passing
- **New interface methods**: `DeclareAndBindQueue`, `DeleteQueue` added to BrokerClient
- **Not yet evaluated on cluster** — needs IONOS cluster for real testing

### Sub-phases (ExchangeFence path)
1. PrepareSwap → ReCheckpoint → SwapTransfer → CreateReplacement (shared with Cutoff)
2. **PreFenceDrain**: START_REPLAY(swap), measure rates for 3s, adaptive decision
3. **ExchangeFence**: DeclareAndBind buffer → Unbind primary → Unbind swap
4. **ParallelDrain**: Poll both queues→0 (30s stall detection, 120s timeout)
5. **FenceCutover**: Kill shadow → Rebind primary → Drain buffer → END_REPLAY → cleanup

### Adaptive Decision (in PreFenceDrain)
- Records initial swap depth, measures current after 3s
- Net drain rate = (initial - current) / elapsed
- If net rate ≤ 0 (ρ ≥ 1): falls back to MiniReplay (Cutoff)
- If estimated fence time > 60s: falls back to MiniReplay
- Otherwise: proceeds to Exchange-Fence

### Restructured Accumulation Window
- STS scale-down starts in PrepareSwap (early, async)
- Overlaps with re-checkpoint + transfer, saving ~7-15s
- CreateReplacement handles it idempotently if PrepareSwap didn't do it

### Rollback (handleSwapFenceRollback)
- Triggered by stall (30s) or timeout (120s) during ParallelDrain
- Rebinds primary + swap queues, deletes buffer queue
- Falls back to MiniReplay (Cutoff mode)

### Files Changed
- `internal/messaging/client.go` — 2 new interface methods
- `internal/messaging/rabbitmq.go` — 2 new implementations
- `internal/messaging/mock.go` — 2 new mock implementations
- `internal/controller/statefulmigration_controller.go` — 5 new handlers + routing + restructured PrepareSwap
- `internal/controller/statefulmigration_controller_test.go` — 8 new tests + 10 test fixes

### Remaining Work
1. **Cluster evaluation**: Run SS-Shadow-Swap config on IONOS cluster
2. **Update Overleaf**: ~~Methodology sections updated (4 configs, 280 runs)~~ DONE. Charts/tables still needed after evaluation data collected.
3. **Consumer verification**: Ensure CRIU restore doesn't auto-reconnect to primary
