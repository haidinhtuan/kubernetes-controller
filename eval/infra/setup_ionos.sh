#!/usr/bin/env bash
set -euo pipefail

# Configuration
DATACENTER_NAME="ms2m-eval-$(date +%Y%m%d-%H%M%S)"
LOCATION="de/txl"
NODE_COUNT=3
CORES=2
RAM_GB=4
DISK_SIZE_GB=30
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
STATE_FILE="eval/infra/state.env"

echo "=== MS2M Evaluation Infrastructure Setup ==="
echo "Datacenter: $DATACENTER_NAME"
echo "Location: $LOCATION"
echo "Nodes: $NODE_COUNT"

# Step 1: Create datacenter
echo "[1/$((NODE_COUNT + 4))] Creating datacenter..."
DC_ID=$(ionosctl datacenter create \
    --name "$DATACENTER_NAME" \
    --location "$LOCATION" \
    -w -o json | jq -r '.id')
echo "Datacenter ID: $DC_ID"

# Step 2: Allocate public IPs
echo "[2/$((NODE_COUNT + 4))] Allocating IP block..."
IP_BLOCK=$(ionosctl ipblock create \
    --name "${DATACENTER_NAME}-ips" \
    --location "$LOCATION" \
    --size "$NODE_COUNT" \
    -w -o json)
IP_BLOCK_ID=$(echo "$IP_BLOCK" | jq -r '.id')
# Extract IPs array
IPS=($(echo "$IP_BLOCK" | jq -r '.properties.ips[]'))

# Step 3: Create public LAN
echo "[3/$((NODE_COUNT + 4))] Creating LAN..."
LAN_ID=$(ionosctl lan create \
    --datacenter-id "$DC_ID" \
    --name "${DATACENTER_NAME}-lan" \
    --public=true \
    -w -o json | jq -r '.id')

# Step 4: Create servers (VCPU type for cost efficiency)
declare -a SERVER_IDS
for i in $(seq 0 $((NODE_COUNT - 1))); do
    STEP=$((4 + i))
    NODE_NAME="${DATACENTER_NAME}-node-${i}"
    echo "[$STEP/$((NODE_COUNT + 4))] Creating server: $NODE_NAME..."

    # Create VCPU server
    SRV_ID=$(ionosctl server create \
        --datacenter-id "$DC_ID" \
        --name "$NODE_NAME" \
        --type VCPU \
        --cores "$CORES" \
        --ram "${RAM_GB}GB" \
        -w -o json | jq -r '.id')
    SERVER_IDS+=("$SRV_ID")

    # Create boot volume with Ubuntu
    VOL_ID=$(ionosctl volume create \
        --datacenter-id "$DC_ID" \
        --name "${NODE_NAME}-boot" \
        --image-alias "ubuntu:22.04" \
        --ssh-key-paths "$SSH_KEY_PATH" \
        --type SSD \
        --size "${DISK_SIZE_GB}" \
        -w -o json | jq -r '.id')

    # Attach volume to server
    ionosctl server volume attach \
        --datacenter-id "$DC_ID" \
        --server-id "$SRV_ID" \
        --volume-id "$VOL_ID" -w

    # Create NIC with public IP
    ionosctl nic create \
        --datacenter-id "$DC_ID" \
        --server-id "$SRV_ID" \
        --name "${NODE_NAME}-nic" \
        --lan-id "$LAN_ID" \
        --ips "${IPS[$i]}" \
        -w

    echo "  Server $NODE_NAME: IP=${IPS[$i]}"
done

# Save state for teardown
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" << EOF
DATACENTER_ID=$DC_ID
DATACENTER_NAME=$DATACENTER_NAME
IP_BLOCK_ID=$IP_BLOCK_ID
CONTROL_PLANE_IP=${IPS[0]}
WORKER_1_IP=${IPS[1]}
WORKER_2_IP=${IPS[2]}
EOF

echo ""
echo "=== Setup Complete ==="
echo "State saved to: $STATE_FILE"
echo ""
echo "Control Plane: ${IPS[0]}"
echo "Worker 1:      ${IPS[1]}"
echo "Worker 2:      ${IPS[2]}"
echo ""
echo "Next steps:"
echo "  1. Wait a few minutes for servers to boot"
echo "  2. Run: bash eval/infra/install_k8s.sh"
