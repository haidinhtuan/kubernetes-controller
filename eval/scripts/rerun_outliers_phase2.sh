#!/usr/bin/env bash
set -euo pipefail

# Phase 2: Rerun StatefulSet outliers (consumer already switched to StatefulSet)

NAMESPACE="default"
CHECKPOINT_REPO="registry.registry.svc.cluster.local:5000/checkpoints"
WORKER_1="worker-1"
WORKER_2="worker-2"
RESULTS_DIR="eval/results/rerun-outliers"

RMQ_POD=$(kubectl get pods -n rabbitmq -o jsonpath='{.items[0].metadata.name}')

run_single_migration() {
    local CONFIG="$1"
    local RATE="$2"
    local RUN_NUM="$3"
    local MIGRATION_NAME="rerun-${CONFIG}-r${RATE}-n${RUN_NUM}"

    echo ""
    echo "=== Rerunning: $CONFIG rate=$RATE run=$RUN_NUM ==="

    kubectl set env deployment/message-producer MSG_RATE="$RATE" -n "$NAMESPACE"
    kubectl rollout status deployment/message-producer -n "$NAMESPACE" --timeout=60s
    sleep 15

    SOURCE_POD="consumer-0"
    SOURCE_NODE=$(kubectl get pod "$SOURCE_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
    if [[ "$SOURCE_NODE" == "$WORKER_1" ]]; then
        DYNAMIC_TARGET="$WORKER_2"
    else
        DYNAMIC_TARGET="$WORKER_1"
    fi
    echo "  Source: $SOURCE_POD on $SOURCE_NODE -> Target: $DYNAMIC_TARGET"

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

    kubectl exec -n rabbitmq "$RMQ_POD" -- rabbitmqctl purge_queue app.events 2>/dev/null || true
    kubectl exec -n rabbitmq "$RMQ_POD" -- rabbitmqctl delete_queue app.events.ms2m-replay 2>/dev/null || true
    sleep 3

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

    kubectl delete statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" --ignore-not-found

    # Recovery
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
    else
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
    fi
}

echo "=== Phase 2: StatefulSet outliers (13 runs) ==="

# SS-Seq (6 runs)
run_single_migration "statefulset-sequential" 20 13
run_single_migration "statefulset-sequential" 40 21
run_single_migration "statefulset-sequential" 40 27
run_single_migration "statefulset-sequential" 40 28
run_single_migration "statefulset-sequential" 100 53
run_single_migration "statefulset-sequential" 120 62

# SS-Shadow (4 runs)
run_single_migration "statefulset-shadowpod" 10 1
run_single_migration "statefulset-shadowpod" 20 15
run_single_migration "statefulset-shadowpod" 60 37
run_single_migration "statefulset-shadowpod" 80 46

# SS-Swap (3 runs)
run_single_migration "statefulset-shadowpod-swap" 60 33
run_single_migration "statefulset-shadowpod-swap" 100 52
run_single_migration "statefulset-shadowpod-swap" 120 69

echo ""
echo "=== Phase 2 complete (13 runs) ==="
echo "Now switch back to Deployment manually if needed."
