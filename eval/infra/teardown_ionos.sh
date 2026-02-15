#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="eval/infra/state.env"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No state file found at $STATE_FILE. Nothing to tear down."
    exit 0
fi

source "$STATE_FILE"

echo "=== MS2M Evaluation Infrastructure Teardown ==="
echo "Datacenter: $DATACENTER_NAME ($DATACENTER_ID)"

read -p "Are you sure you want to destroy all resources? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "[1/2] Deleting datacenter (cascades to all resources)..."
ionosctl datacenter delete --datacenter-id "$DATACENTER_ID" --force -w

echo "[2/2] Deleting IP block..."
ionosctl ipblock delete --ipblock-id "$IP_BLOCK_ID" --force -w

rm -f "$STATE_FILE"

echo "=== Teardown Complete ==="
