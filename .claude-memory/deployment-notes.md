# Bare-Metal CRIU Deployment Notes

## CRI-O + CRIU Setup
- **crun must be dynamically linked**: Bundled CRI-O crun (`/usr/libexec/crio/crun`) is static; dlopen of libcriu.so.2 causes error -52. Build from source: `./configure --with-libcriu`
- **CRIU 4.0 required**: Ubuntu 22.04's CRIU 3.16.1 incompatible with crun 1.19.1
- **LD_LIBRARY_PATH**: CRI-O systemd override needed for crun to find libcriu.so.2
- **conmon path**: Custom crun CRI-O config needs `monitor_path = "/usr/libexec/crio/conmon"`
- **Setup script**: `eval/infra/setup_criu.sh` — automates full CRIU 4.0 + patched crun build on each worker

## crun patches (1.19.1-dirty, built from source on each worker)
- Source at `/tmp/crun-src/` on both workers, binary at `/usr/local/bin/crun`
- **tcp_close patch**: `criu_set_tcp_close(true)` called whenever `tcp_established` is set during restore. Without this, CRIU fails to restore containers with established TCP connections on a different node (IP mismatch → "Can't bind inet socket back"). Consumer reconnects automatically after restore.
- **cgroup_root patch**: `criu_add_cg_root(NULL, status->cgroup_path)` called during restore. Without this, re-checkpoint of restored containers fails with -EBADE (cgroup namespace root mismatch). Same as upstream commit `c954b1b6` in crun >= 1.21.
- No crun-wrapper needed — patches are in the C code directly
- Vanilla crun 1.26 binary backed up at `/usr/local/bin/crun-1.19.1.bak` (misleading name)

## CRIU Global Config (`/etc/criu/default.conf`)
- CRIU reads this file directly, bypassing crun entirely
- Use this for CRIU-specific flags that crun doesn't support
- **`skip-in-flight`**: Required when consumer has HTTP health server (port 8080). Readiness probes create half-open connections (SYN_RECV) that cause CRIU error -52 ("In-flight connection (l)"). `--tcp-established` handles ESTABLISHED connections but NOT in-flight/listening sockets.
- Create on all workers: `echo "skip-in-flight" > /etc/criu/default.conf`
- Does NOT affect CRI-O's feature detection (unlike adding flags to crun-wrapper)

## CRI-O Configuration
- **Signature policy**: Remove `signature_policy` line from `10-crio.conf`; CRI-O rejects restore if any policy is explicitly configured
- **OCI manifest for checkpoint images**: CRI-O only reads checkpoint annotations from OCI format, not Docker v2. Set both manifest AND config media types to OCI in go-containerregistry
- **Config file location**: `/etc/crio/crio.conf.d/10-ms2m.conf` — must have `enable_criu_support = true`

## Image Loading (Non-Registry Approach)
- **CRI-O uses host DNS, NOT cluster DNS**: kubelet/CRI-O can't resolve `svc.cluster.local` names
- **Fix for registry**: Add registry ClusterIP to `/etc/hosts` on all nodes
- **Local images**: Load via `skopeo copy docker-archive:... containers-storage:localhost/...` then reference as `localhost/<image>:latest` with `imagePullPolicy: IfNotPresent`
- **Checkpoint images**: Still use in-cluster registry; fix DNS via /etc/hosts

## Image Pull Policies
- **imagePullPolicy: Always** for checkpoint images: Target pod must use `PullAlways`; otherwise kubelet caches stale images from previous migrations under the same tag
- **imagePullPolicy: IfNotPresent** for pre-loaded images via skopeo containers-storage (transfer job, controller)
- **imagePullPolicy: Never** for Direct transfer mode: ms2m-agent loads image into local CRI-O store, no registry pull needed
- **localhost/ prefix**: CRI-O stores images loaded via containers-storage with `localhost/` prefix. Controller references must match (e.g., `localhost/checkpoint-transfer:latest`)

## Network & Access
- **Transfer job needs root**: Checkpoint files at /var/lib/kubelet/checkpoints/ are 0600 root:root
- **ContainerCheckpoint**: Beta in K8s 1.30+ (no feature gate needed)

## Application Requirements
- **Consumer app must handle broken connections**: After CRIU restore with `--tcp-close`, TCP connections are broken. App needs reconnection logic (pika BrokenPipeError → reconnect)

## CRI-O Restart Gotchas
- Restarting CRI-O kills all running containers → CrashLoopBackOff across cluster
- After CRI-O restart, delete all pods that were running to let controllers recreate them fresh
- Port conflicts may occur if old container state lingers (e.g., "bind: address already in use")

## OriginalReplicas Persistence Bug (2026-03-15)
- When patching status with `MergeFrom(m.DeepCopy())`, the DeepCopy must be taken BEFORE any in-memory modifications, otherwise the modified fields aren't included in the patch diff
- Affected PrepareSwap: OriginalReplicas was set in memory before DeepCopy → lost on patch → CreateReplacement couldn't scale up StatefulSet
- Fix: Move DeepCopy before modifications + add fallback to 1 replica in CreateReplacement

## Cleanup Between Evaluation Runs
- Must clean up thoroughly between runs to avoid interference:
  - Delete migration CRs, shadow pods, stale jobs
  - Purge queues (app.events), delete replay/control queues
  - Clean checkpoint images on workers (crictl rmi + rm /var/lib/kubelet/checkpoints/*.tar)
  - Wait for consumer pods to fully stabilize before next run
