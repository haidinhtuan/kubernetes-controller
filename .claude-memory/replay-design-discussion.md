---
name: replay-design-discussion
description: Full history of replay design exploration — Cutoff, Drain, Barrier, Buffer Queue, and final Exchange-Fence decision
type: project
---

# Replay Design Discussion (2026-03-01 → 2026-03-15)

## Status: RESOLVED → Exchange-Fence Convergence
See [exchange-fence-design.md](exchange-fence-design.md) for the agreed design.

**Why:** The main Replay phase and MiniReplay during identity swap both had state gap and duplicate problems. After exploring 5 approaches and multi-model review, Exchange-Fence was chosen.

**How to apply:** Exchange-Fence applies to MiniReplay (identity swap). Main Replay phase still uses Cutoff/Drain modes (simpler, gap is acceptable since shadow keeps processing).

## Consumer Throughput
- `PROCESSING_DELAY_MS: 10` → theoretical max ~100 msg/s
- Real observed throughput: **~73 msg/s** (from evaluation data)
- At 120 msg/s: consumer CANNOT keep up (R_in > R_out)
- At 10-60 msg/s: consumer keeps up (R_out > R_in)

## Approaches Explored (chronological)

### 1. Cutoff Mode (default, implemented)
- Secondary queue stays bound during replay, time-based cutoff
- Gap at high rates (~292 msgs at 120 msg/s)

### 2. Drain Mode (implemented 2026-03-01)
- Unbinds secondary before replay → fixed set, stall detection
- Faster than Cutoff but still has gap (~294 msgs at 120 msg/s)

### 3. In-Band Barrier (Chandy-Lamport inspired)
- Requires consumer SDK changes → rejected (controller-only scope)

### 4. Buffer Queue
- Zero gap, zero loss, no consumer changes, but complex
- Evolved into Exchange-Fence

### 5. Exchange-Fence Convergence (CHOSEN, 2026-03-15)
- Unbind BOTH primary and swap from exchange simultaneously
- Buffer queue catches post-fence messages
- Both consumers drain finite sets → identical state
- See [exchange-fence-design.md](exchange-fence-design.md)

## Key Insight
Perfect sync already exists when R_out > R_in. Gap only matters at R_in > R_out. But for identity swap MiniReplay, the gap is ALWAYS problematic because shadow's state is lost when killed.

## Literature Validation (Claude Extended Research, 2026-03-15)
- No existing work treats AMQP bind/unbind as consistent-cut primitive
- Beaver (OSDI 2024): closest parallel — L4 infra-as-marker
- MS2M (Dinh-Tuan 2022/2025): uses message-level cutoff, not topology
- Novelty claim confirmed as genuine
