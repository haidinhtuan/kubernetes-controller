---
name: criu-recheckpoint-limitation
description: CRIU re-checkpoint + cross-node restore — both fixed with patched crun 1.19.1, verified 2026-03-16
type: project
---

## CRIU Re-Checkpoint + Cross-Node Restore — FIXED AND VERIFIED (2026-03-16)

Two separate issues were fixed by patching crun. Both patches are in the fork `github.com/haidinhtuan/crun` branch `fix/cgroup-root-restore`.

### Issue 1: Re-Checkpoint Failure (cgroup namespace root mismatch)

**Symptom:** Re-checkpoint of CRIU-restored containers fails with error -52 (-EBADE).

**Root cause:** crun 1.19.1 doesn't call `criu_add_cg_root()` during restore. CRIU restores the process into the OLD cgroup path from the checkpoint image, then `unshare(CLONE_NEWCGROUP)` pins the cgroupns root to that stale path. CRI-O then moves the process to a NEW cgroup scope, but the namespace root is already immutable. On re-checkpoint, `proc_parse.c` suffix validation fails.

**Fix:** Added `criu_add_cg_root(NULL, status->cgroup_path)` call during restore. This triggers CRIU's `rewrite_cgsets()` to remap old cgroup paths BEFORE `move_in_cgroup()` + `unshare()`. Same as upstream commit `c954b1b6` in crun >= 1.21.

### Issue 2: Cross-Node Restore Failure (TCP connection IP mismatch)

**Symptom:** CRIU restore fails with "Can't bind inet socket back: Cannot assign requested address" (soccr/soccr.c:499).

**Root cause:** Checkpoint contains ESTABLISHED TCP connections (e.g., AMQP to RabbitMQ) with the source pod's IP. When restoring on a different node, the source IP doesn't exist, so CRIU can't re-bind the socket. CRI-O/crun sets `--tcp-established` for both checkpoint and restore but never sets `--tcp-close`. The `/etc/criu/default.conf` `tcp-close` option is NOT honored when `tcp-established` is set via libcriu API (the API call takes precedence).

**Fix:** Added `criu_set_tcp_close(true)` call in the restore function whenever `tcp_established` is set. This tells CRIU to drop all TCP connections on restore instead of re-establishing them. The consumer's pika reconnection logic handles recovery automatically.

### Patches in `src/libcrun/criu.c` (3 changes)

```c
// 1. Added to struct libcriu_wrapper_s:
void (*criu_set_tcp_close) (bool tcp_close);

// 2. Added to load_wrapper():
LOAD_CRIU_FUNCTION (criu_set_tcp_close, false);

// 3. Added to libcrun_container_restore_linux_criu(), after criu_set_tcp_established:
if (cr_options->tcp_established && libcriu_wrapper->criu_set_tcp_close)
  libcriu_wrapper->criu_set_tcp_close (true);
```

(The cgroup_root patch — `criu_add_cg_root` — was already applied in a previous commit on the same branch.)

### Verification (2026-03-16)

Full ShadowPod + ExchangeFence migration at 40 msg/s:
- Initial restore on different node: **SUCCESS** (tcp_close)
- Re-checkpoint of restored shadow pod: **SUCCESS** (cgroup_root)
- Identity swap with replacement pod: **SUCCESS**
- Total migration time: **~22s**, 0ms downtime

### Current Deployment

- Both workers run patched crun 1.19.1-dirty (built from `/tmp/crun-src/`)
- `/etc/criu/default.conf`: `skip-in-flight` + `tcp-close` (tcp-close in config is belt-and-suspenders, the real fix is in the C code)
- Fork pushed: `github.com/haidinhtuan/crun` branch `fix/cgroup-root-restore`

### Upstream References

- **crun #1651**: cgroup root fix — closed by upstream `c954b1b6` (crun >= 1.21)
- **CRIU #1793** (Adrian Reber, 2022): "runc/crun, cgroups and CRIU" — OPEN
- **K8s Checkpoint Restore WG** (Jan 2026): Pod migration listed as priority use case
- Note: `tcp_close` is NOT in upstream crun — our patch is custom. Upstream assumes same-node restore.
