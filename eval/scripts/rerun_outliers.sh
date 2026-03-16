#!/usr/bin/env bash
set -euo pipefail

# Rerun outlier migrations and output replacement CSV lines
# Usage: KUBECONFIG=eval/infra/kubeconfig bash eval/scripts/rerun_outliers.sh

NAMESPACE="default"
CHECKPOINT_REPO="registry.registry.svc.cluster.local:5000/checkpoints"
WORKER_1="worker-1"
WORKER_2="worker-2"
RESULTS_DIR="eval/results/rerun-outliers"
mkdir -p "$RESULTS_DIR"

RMQ_POD=$(kubectl get pods -n rabbitmq -o jsonpath='{.items[0].metadata.name}')

run_single_migration() {
    local CONFIG="$1"
    local RATE="$2"
    local RUN_NUM="$3"
    local MIGRATION_NAME="rerun-${CONFIG}-r${RATE}-n${RUN_NUM}"

    echo ""
    echo "=== Rerunning: $CONFIG rate=$RATE run=$RUN_NUM ==="

    # Set producer rate
    kubectl set env deployment/message-producer MSG_RATE="$RATE" -n "$NAMESPACE"
    kubectl rollout status deployment/message-producer -n "$NAMESPACE" --timeout=60s
    sleep 15  # let queue reach steady state

    # Determine source pod
    if [[ "$CONFIG" == statefulset-* ]]; then
        SOURCE_POD="consumer-0"
    else
        SOURCE_POD=$(kubectl get pods -n "$NAMESPACE" -l app=consumer -o jsonpath='{.items[0].metadata.name}')
    fi

    # Determine target node
    SOURCE_NODE=$(kubectl get pod "$SOURCE_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
    if [[ "$SOURCE_NODE" == "$WORKER_1" ]]; then
        DYNAMIC_TARGET="$WORKER_2"
    else
        DYNAMIC_TARGET="$WORKER_1"
    fi
    echo "  Source: $SOURCE_POD on $SOURCE_NODE -> Target: $DYNAMIC_TARGET"

    # Build CR fields
    STRATEGY_FIELD=""
    SWAP_MODE_FIELD=""
    if [[ "$CONFIG" == "statefulset-sequential" ]]; then
        STRATEGY_FIELD=""
    else
        STRATEGY_FIELD="  migrationStrategy: ShadowPod"
    fi
    if [[ "$CONFIG" == "statefulset-shadowpod-swap" ]]; then
        SWAP_MODE_FIELD="  identitySwapMode: ExchangeFence"
    fi

    # Purge queues
    kubectl exec -n rabbitmq "$RMQ_POD" -- rabbitmqctl purge_queue app.events 2>/dev/null || true
    kubectl exec -n rabbitmq "$RMQ_POD" -- rabbitmqctl delete_queue app.events.ms2m-replay 2>/dev/null || true
    sleep 3

    # Create migration CR
    cat <<YAML | kubectl apply -n "$NAMESPACE" -f -
apiVersion: migration.ms2m.io/v1alpha1
kind: StatefulMigration
metadata:
  name: ${MIGRATION_NAME}
spec:
  sourcePod: ${SOURCE_POD}
  targetNode: ${DYNAMIC_TARGET}
  checkpointImageRepository: ${CHECKPOINT_REPO}
  replayCutoffSeconds: 120
${STRATEGY_FIELD}
${SWAP_MODE_FIELD}
  messageQueueConfig:
    queueName: app.events
    brokerUrl: amqp://guest:guest@rabbitmq.rabbitmq.svc.cluster.local:5672/
    exchangeName: app.fanout
YAML

    # Wait for completion
    echo -n "  Waiting..."
    for i in $(seq 1 120); do
        PHASE=$(kubectl get statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$PHASE" == "Completed" || "$PHASE" == "Failed" ]]; then
            break
        fi
        sleep 5
        echo -n "."
    done
    echo " $PHASE"

    # Extract metrics
    TIMINGS=$(kubectl get statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" -o json)
    CHECKPOINT_T=$(echo "$TIMINGS" | jq -r '.status.phaseTimings.Checkpointing // "N/A"')
    TRANSFER_T=$(echo "$TIMINGS" | jq -r '.status.phaseTimings.Transferring // "N/A"')
    RESTORE_T=$(echo "$TIMINGS" | jq -r '.status.phaseTimings.Restoring // "N/A"')
    REPLAY_T=$(echo "$TIMINGS" | jq -r '.status.phaseTimings.Replaying // "N/A"')
    FINALIZE_T=$(echo "$TIMINGS" | jq -r '.status.phaseTimings.Finalizing // "N/A"')

    if [[ "$PHASE" == "Completed" ]]; then
        TOTAL_T=$(echo "$TIMINGS" | jq -r '
            [.status.phaseTimings | to_entries[] | .value |
             if test("^[0-9.]+ms$") then rtrimstr("ms") | tonumber / 1000 elif test("^[0-9]+m") then (split("m") | (.[0] | tonumber) * 60 + (.[1] | rtrimstr("s") | tonumber)) elif test("^[0-9.]+s$") then rtrimstr("s") | tonumber else 0 end] |
            add | tostring + "s"' 2>/dev/null || echo "N/A")
    else
        TOTAL_T="N/A"
    fi

    local CSV_LINE="$RUN_NUM,$RATE,$CONFIG,$TOTAL_T,$CHECKPOINT_T,$TRANSFER_T,$RESTORE_T,$REPLAY_T,$FINALIZE_T,$PHASE"
    echo "$CSV_LINE" >> "$RESULTS_DIR/replacements.csv"
    echo "  RESULT: $CSV_LINE"

    # Cleanup CR
    kubectl delete statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" --ignore-not-found

    # Wait for consumer recovery
    if [[ "$CONFIG" == "statefulset-shadowpod" || "$CONFIG" == "statefulset-shadowpod-swap" ]]; then
        echo -n "  Recovering StatefulSet..."
        kubectl scale statefulset consumer --replicas=1 -n "$NAMESPACE" 2>/dev/null || true
        for i in $(seq 1 60); do
            if kubectl get pod consumer-0 -n "$NAMESPACE" &>/dev/null; then break; fi
            sleep 2; echo -n "."
        done
        kubectl wait --for=condition=Ready pod/consumer-0 -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        sleep 5
        echo " ready"
    elif [[ "$CONFIG" == statefulset-* ]]; then
        echo -n "  Waiting for consumer-0..."
        for i in $(seq 1 60); do
            POD_STATUS=$(kubectl get pod consumer-0 -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
            if [[ -z "$POD_STATUS" ]]; then break; fi
            sleep 2; echo -n "."
        done
        for i in $(seq 1 30); do
            if kubectl get pod consumer-0 -n "$NAMESPACE" &>/dev/null; then break; fi
            sleep 2; echo -n "+"
        done
        kubectl wait --for=condition=Ready pod/consumer-0 -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        sleep 5
        echo " ready"
    else
        echo -n "  Waiting for Deployment recovery..."
        for i in $(seq 1 60); do
            TERMINATING=$(kubectl get pods -n "$NAMESPACE" -l app=consumer \
                --field-selector=status.phase!=Running -o name 2>/dev/null | wc -l)
            SHADOW=$(kubectl get pod -n "$NAMESPACE" -l "migration.ms2m.io/role=target" \
                -o name 2>/dev/null | wc -l)
            if [[ "$TERMINATING" -eq 0 && "$SHADOW" -eq 0 ]]; then break; fi
            sleep 2; echo -n "."
        done
        kubectl rollout status deployment/consumer -n "$NAMESPACE" --timeout=120s || true
        sleep 5
        echo " ready"
    fi
}

switch_to_statefulset() {
    echo ""
    echo "=========================================="
    echo "SWITCHING consumer to StatefulSet workload"
    echo "=========================================="
    kubectl delete deployment consumer -n "$NAMESPACE" --ignore-not-found
    sleep 5
    kubectl apply -f eval/workloads/consumer.yaml -n "$NAMESPACE"
    echo -n "Waiting for consumer-0..."
    for i in $(seq 1 60); do
        if kubectl get pod consumer-0 -n "$NAMESPACE" &>/dev/null; then break; fi
        sleep 2; echo -n "."
    done
    kubectl wait --for=condition=Ready pod/consumer-0 -n "$NAMESPACE" --timeout=180s
    sleep 10
    echo " ready"
}

switch_to_deployment() {
    echo ""
    echo "========================================="
    echo "SWITCHING consumer to Deployment workload"
    echo "========================================="
    kubectl delete statefulset consumer -n "$NAMESPACE" --ignore-not-found
    kubectl delete service consumer -n "$NAMESPACE" --ignore-not-found
    sleep 5
    kubectl apply -f eval/workloads/consumer-deployment.yaml -n "$NAMESPACE"
    kubectl rollout status deployment/consumer -n "$NAMESPACE" --timeout=180s
    sleep 10
    echo " Deployment ready"
}

# Header for replacements file
echo "run,msg_rate,configuration,total_time_s,checkpoint_s,transfer_s,restore_s,replay_s,finalize_s,status" > "$RESULTS_DIR/replacements.csv"

echo "=== Rerunning 17 outliers ==="
echo "Phase 1: D-Reg outliers (consumer is already Deployment)"

# D-Reg outliers (4 runs) — consumer is already Deployment
run_single_migration "deployment-registry" 10 1
run_single_migration "deployment-registry" 80 41
run_single_migration "deployment-registry" 120 66
run_single_migration "deployment-registry" 120 67

echo ""
echo "Phase 2: StatefulSet outliers (switching workload)"
switch_to_statefulset

# SS-Seq outliers (6 runs) — group by rate to minimize rate switches
run_single_migration "statefulset-sequential" 20 13
run_single_migration "statefulset-sequential" 40 21
run_single_migration "statefulset-sequential" 40 27
run_single_migration "statefulset-sequential" 40 28
run_single_migration "statefulset-sequential" 100 53
run_single_migration "statefulset-sequential" 120 62

# SS-Shadow outliers (4 runs)
run_single_migration "statefulset-shadowpod" 10 1
run_single_migration "statefulset-shadowpod" 20 15
run_single_migration "statefulset-shadowpod" 60 37
run_single_migration "statefulset-shadowpod" 80 46

# SS-Swap outliers (3 runs)
run_single_migration "statefulset-shadowpod-swap" 60 33
run_single_migration "statefulset-shadowpod-swap" 100 52
run_single_migration "statefulset-shadowpod-swap" 120 69

echo ""
echo "Phase 3: Switch back to Deployment (restore original state)"
switch_to_deployment

echo ""
echo "=== All 17 outliers rerun complete ==="
echo "Replacement data in: $RESULTS_DIR/replacements.csv"
echo "Run the Python script to apply replacements to the main CSV files."
