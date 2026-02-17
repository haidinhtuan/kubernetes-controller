#!/usr/bin/env bash
set -euo pipefail

# Evaluation parameters (matching dissertation methodology)
MSG_RATES=(1 4 7 10 13 16 19)
REPETITIONS=10
RESULTS_FILE="eval/results/migration-metrics-$(date +%Y%m%d-%H%M%S).csv"
NAMESPACE="${NAMESPACE:-default}"
TARGET_NODE="${TARGET_NODE:-}"  # must be set
CHECKPOINT_REPO="${CHECKPOINT_REPO:-registry.registry.svc.cluster.local:5000/checkpoints}"

mkdir -p "$(dirname "$RESULTS_FILE")"

# CSV header
echo "run,msg_rate,configuration,total_time_s,checkpoint_s,transfer_s,restore_s,replay_s,finalize_s,status" > "$RESULTS_FILE"

echo "=== MS2M Evaluation ==="
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
        echo "  Run $run_counter (rate=$rate, rep=$rep/$REPETITIONS)"

        MIGRATION_NAME="eval-run-${run_counter}"

        # Create StatefulMigration CR
        cat <<YAML | kubectl apply -n "$NAMESPACE" -f -
apiVersion: migration.ms2m.io/v1alpha1
kind: StatefulMigration
metadata:
  name: ${MIGRATION_NAME}
spec:
  sourcePod: consumer-0
  targetNode: ${TARGET_NODE}
  checkpointImageRepository: ${CHECKPOINT_REPO}
  replayCutoffSeconds: 120
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

        # Calculate total time by summing phase durations
        if [[ "$PHASE" == "Completed" ]]; then
            TOTAL_T=$(echo "$TIMINGS" | jq -r '
                [.status.phaseTimings | to_entries[] | .value |
                 if test("^[0-9.]+s$") then rtrimstr("s") | tonumber else 0 end] |
                add | tostring + "s"' 2>/dev/null || echo "N/A")
        else
            TOTAL_T="N/A"
        fi

        echo "$run_counter,$rate,statefulset-sequential,$TOTAL_T,$CHECKPOINT_T,$TRANSFER_T,$RESTORE_T,$REPLAY_T,$FINALIZE_T,$PHASE" >> "$RESULTS_FILE"

        # Cleanup: delete the migration CR
        kubectl delete statefulmigration "$MIGRATION_NAME" -n "$NAMESPACE" --ignore-not-found

        # Wait for consumer-0 to be re-created and ready
        echo -n "    Waiting for consumer-0 readiness..."
        for i in $(seq 1 60); do
            POD_STATUS=$(kubectl get pod consumer-0 -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
            if [[ -z "$POD_STATUS" ]]; then break; fi
            sleep 2
            echo -n "."
        done
        for i in $(seq 1 30); do
            if kubectl get pod consumer-0 -n "$NAMESPACE" &>/dev/null; then break; fi
            sleep 2
            echo -n "+"
        done
        kubectl wait --for=condition=Ready pod/consumer-0 -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
        sleep 5
        echo " ready"
    done
done

echo ""
echo "=== Evaluation Complete ==="
echo "Results saved to: $RESULTS_FILE"
echo "Total runs: $run_counter"
