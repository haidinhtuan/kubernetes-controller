# Evaluation State (2026-02-17)

## Cluster Info
- **Datacenter**: ms2m-eval-20260216-201022 (ID: 56497e75-2297-4af7-9eef-e52230cd7164)
- **Control-plane**: 87.106.89.85
- **Worker-1**: 87.106.88.64
- **Worker-2**: 85.215.138.186
- **SSH**: `ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -o StrictHostKeyChecking=no root@<IP>`
- **State file**: `eval/infra/state.env`

## Running Evaluation (Restarted 12:43 UTC for configs 2+3)
- **Config 1** (statefulset-sequential): COMPLETE — 70 runs at `/root/eval/results/migration-metrics-statefulset-sequential-20260217-084512.csv`
- **Config 2** (deployment-registry): IN PROGRESS — `/root/eval/eval/results/migration-metrics-deployment-registry-20260217-124348.csv`
- **Config 3** (deployment-direct): PENDING — will start after config 2
- **Process**: nohup bash running `run_optimized_evaluation.sh` for each config
- **Logs**: `/root/eval/logs/deploy-registry.log`, `/root/eval/logs/deploy-direct.log`
- **Configuration**: 7 rates × 10 reps = 70 runs per config, 140 remaining
- **MSG_RATES**: (10 20 40 60 80 100 120)
- **PROCESSING_DELAY_MS**: 10 (effective rate ~78 msg/s)
- **Note**: Config 2 run 1 has elevated replay (24.7s) due to leftover queue messages — should be treated as outlier

## What's Deployed
- Controller: `localhost/ms2m-controller:latest` — **UPDATED** with hostname fix (no .Spec.Hostname on shadow pod)
- Consumer: `consumer-deployment.yaml` — **UPDATED** to read /etc/hostname instead of socket.gethostname()
- ms2m-agent: `localhost/ms2m-agent:latest` DaemonSet on workers
- checkpoint-transfer: `localhost/checkpoint-transfer:latest`
- RabbitMQ: rabbitmq namespace
- Registry: registry namespace (ClusterIP: 10.102.183.52)
- Producer: message-producer Deployment in default namespace
- RBAC: ClusterRole manager-role **UPDATED** with `watch` for Deployments

## Key Config on Nodes
- `/etc/hosts` has `10.102.183.52 registry.registry.svc.cluster.local` on all nodes
- CRIU 4.0 + patched crun 1.19.1 installed on both workers via `setup_criu.sh`
- CRI-O configured with crun-wrapper at `/usr/local/bin/crun-wrapper`
- CRI-O systemd override for LD_LIBRARY_PATH=/usr/local/lib

## Bugs Fixed (this session)
- **jq ms/m parsing order**: "358ms" matched `^[0-9]+m`. Fix: check ms$ before m.
- **jq XmYs format**: Added Go durations >1 minute handling
- **total_time_s**: Now computed as sum of phases
- **ShadowPod hostname mismatch (CRITICAL)**: Controller sent START_REPLAY to `ms2m.control.<pod-name>-shadow` but consumer listened on `ms2m.control.<source-hostname>` (from CRIU UTS restore). Two fixes:
  1. Controller: removed `.Spec.Hostname` from shadow pod (no longer sets hostname to source pod name)
  2. Consumer: reads `/etc/hostname` (bind-mounted by CRI-O, correct after restore) instead of `socket.gethostname()` (reads CRIU-restored UTS namespace, returns source pod name)
- **RBAC**: Added `watch` verb for Deployments in manager-role ClusterRole
- **Eval script cleanup**: Added proper wait for terminating pods between Deployment runs

## Key Finding: CRIU UTS Namespace
- After CRIU restore, `socket.gethostname()` returns the checkpointed hostname (source pod)
- `/etc/hostname` is bind-mounted by CRI-O → has correct shadow pod hostname
- `HOSTNAME` env var (from `kubectl exec`) shows correct value, but CRIU-restored Python process has OLD env from checkpoint
- For reliable pod identity after CRIU restore, always read `/etc/hostname`

## Uncommitted Changes
- `internal/controller/statefulmigration_controller.go`: removed .Spec.Hostname from shadow pod + checkpoint-transfer image ref
- `internal/controller/statefulmigration_controller_test.go`: updated hostname test assertion
- `config/rbac/role.yaml`: added `watch` for Deployments
- `eval/workloads/consumer-deployment.yaml`: /etc/hostname fix + PROCESSING_DELAY_MS=10
- `eval/workloads/consumer.yaml`: /etc/hostname fix + PROCESSING_DELAY_MS=10
- `eval/scripts/run_optimized_evaluation.sh`: Fixed jq, improved Deployment cleanup, MSG_RATES
- `eval/scripts/run_evaluation.sh`: Fixed jq
- `eval/scripts/run_all_evaluations.sh`: Dynamic target node

## To Continue
1. Check eval progress: `ssh root@87.106.89.85 "tail -20 /root/eval/logs/deploy-registry.log && wc -l /root/eval/eval/results/*.csv"`
2. Config 2 results: `/root/eval/eval/results/migration-metrics-deployment-registry-*.csv`
3. Config 3 results: will be in `/root/eval/eval/results/migration-metrics-deployment-direct-*.csv`
4. Config 1 results: `/root/eval/results/migration-metrics-statefulset-sequential-20260217-084512.csv`
5. After evaluation: commit changes, download results, teardown IONOS cluster
6. Teardown: `ionosctl datacenter delete --datacenter-id 56497e75-2297-4af7-9eef-e52230cd7164`
