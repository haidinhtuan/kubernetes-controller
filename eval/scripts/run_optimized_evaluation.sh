#!/usr/bin/env bash
set -euo pipefail

# Configuration: which optimized setup to evaluate
CONFIGURATION="${CONFIGURATION:-deployment-registry}"
# Options:
#   "statefulset-sequential" — baseline (uses consumer.yaml StatefulSet)
#   "deployment-registry"    — Deployment + ShadowPod + Registry transfer
#   "deployment-direct"      — Deployment + ShadowPod + Direct transfer

# Evaluation parameters (matching dissertation methodology)
MSG_RATES=(1 4 7 10 13 16 19)
REPETITIONS=10
RESULTS_FILE="eval/results/migration-metrics-${CONFIGURATION}-$(date +%Y%m%d-%H%M%S).csv"
NAMESPACE="${NAMESPACE:-default}"
CHECKPOINT_REPO="${CHECKPOINT_REPO:-registry.registry.svc.cluster.local:5000/checkpoints}"

# Worker nodes — target is dynamically chosen to be opposite of source
WORKER_1="${WORKER_1:-worker-1}"
WORKER_2="${WORKER_2:-worker-2}"

mkdir -p "$(dirname "$RESULTS_FILE")"

# CSV header
echo "run,msg_rate,configuration,total_time_s,checkpoint_s,transfer_s,restore_s,replay_s,finalize_s,status" > "$RESULTS_FILE"

echo "=== MS2M Optimized Evaluation ==="
echo "Configuration: $CONFIGURATION"
echo "Message rates: ${MSG_RATES[*]}"
echo "Repetitions: $REPETITIONS"
echo "Results: $RESULTS_FILE"
echo ""

run_counter=0

for rate in "${MSG_RATES[@]}"; do
    echo "--- Rate: $rate msg/s ---"

    # Update producer rate
    kubectl set env deployment/message-producer MSG_RATE="$rate" -n "$NAMESPACE"

    # Wait for producer to stabilize
    kubectl rollout status deployment/message-producer -n "$NAMESPACE" --timeout=60s
    sleep 10  # let queue reach steady state

    for rep in $(seq 1 $REPETITIONS); do
        run_counter=$((run_counter + 1))
        echo "  Run $run_counter (rate=$rate, rep=$rep/$REPETITIONS, config=$CONFIGURATION)"

        MIGRATION_NAME="eval-run-${run_counter}"

        # Determine source pod name
        if [[ "$CONFIGURATION" == statefulset-* ]]; then
            SOURCE_POD="consumer-0"
        else
            # Deployment pods have generated names; look up dynamically
            SOURCE_POD=$(kubectl get pods -n "$NAMESPACE" -l app=consumer -o jsonpath='{.items[0].metadata.name}')
            if [[ -z "$SOURCE_POD" ]]; then
                echo "    ERROR: No consumer pod found"
                echo "$run_counter,$rate,$CONFIGURATION,N/A,N/A,N/A,N/A,N/A,N/A,NoPod" >> "$RESULTS_FILE"
                continue
            fi
            echo "    Source pod: $SOURCE_POD"
        fi

        # Dynamically determine target node (must differ from source node)
        SOURCE_NODE=$(kubectl get pod "$SOURCE_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
        if [[ "$SOURCE_NODE" == "$WORKER_1" ]]; then
            DYNAMIC_TARGET="$WORKER_2"
        else
            DYNAMIC_TARGET="$WORKER_1"
        fi
        echo "    Source: $SOURCE_POD on $SOURCE_NODE -> Target: $DYNAMIC_TARGET"

        # Build optional CR fields based on configuration
        if [[ "$CONFIGURATION" == "deployment-direct" ]]; then
            TRANSFER_MODE_FIELD="  transferMode: Direct"
        else
            TRANSFER_MODE_FIELD=""
        fi

        if [[ "$CONFIGURATION" == statefulset-* ]]; then
            STRATEGY_FIELD=""
        else
            STRATEGY_FIELD="  migrationStrategy: ShadowPod"
        fi

        # Create StatefulMigration CR
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
${TRANSFER_MODE_FIELD}
  messageQueueConfig:
    queueName: app.events
    brokerUrl: amqp://guest:guest@rabbitmq.rabbitmq.svc.cluster.local:5672/
    exchangeName: app.fanout
YAML

        # Wait for completion (timeout 10 minutes)
        echo -n "    Waiting..."
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

        # Calculate total time by summing phase durations (more robust than timestamp math)
        if [[ "$PHASE" == "Completed" ]]; then
            TOTAL_T=$(echo "$TIMINGS" | jq -r '
                [.status.phaseTimings | to_entries[] | .value |
                 if test("^[0-9.]+s$") then rtrimstr("s") | tonumber else 0 end] |
                add | tostring + "s"' 2>/dev/null || echo "N/A")
        else
            TOTAL_T="N/A"
        fi

        echo "$run_counter,$rate,$CONFIGURATION,$TOTAL_T,$CHECKPOINT_T,$TRANSFER_T,$RESTORE_T,$REPLAY_T,$FINALIZE_T,$PHASE" >> "$RESULTS_FILE"

        # Cleanup: delete the migration CR
        kubectl delete statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" --ignore-not-found

        # Wait for consumer to be ready for next run
        if [[ "$CONFIGURATION" == statefulset-* ]]; then
            # StatefulSet: wait for old pod termination, then recreation and readiness
            echo -n "    Waiting for consumer-0 readiness..."
            # Wait for old pod to fully terminate (owned by deleted CR)
            for i in $(seq 1 60); do
                POD_STATUS=$(kubectl get pod consumer-0 -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
                # Break when pod either has no deletionTimestamp or doesn't exist at all
                if [[ -z "$POD_STATUS" ]]; then break; fi
                sleep 2
                echo -n "."
            done
            # Wait for StatefulSet to recreate the pod (may take a few seconds after deletion)
            for i in $(seq 1 30); do
                if kubectl get pod consumer-0 -n "$NAMESPACE" &>/dev/null; then break; fi
                sleep 2
                echo -n "+"
            done
            # Wait for the pod to become Ready
            kubectl wait --for=condition=Ready pod/consumer-0 -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
            sleep 5
            echo " ready"
        else
            # Deployment: source pod is deleted during Finalizing, Deployment
            # controller recreates a new pod. Wait for it to be ready.
            kubectl rollout status deployment/consumer -n "$NAMESPACE" --timeout=120s || true
            sleep 10
        fi
    done
done

echo ""
echo "=== Evaluation Complete ==="
echo "Configuration: $CONFIGURATION"
echo "Results saved to: $RESULTS_FILE"
echo "Total runs: $run_counter"
