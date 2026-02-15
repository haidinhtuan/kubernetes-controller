#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="eval/infra/state.env"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

CRIO_VERSION="1.28"
K8S_VERSION="1.28"
CALICO_VERSION="3.26.4"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "ERROR: State file not found at $STATE_FILE"
    echo "Run setup_ionos.sh first."
    exit 1
fi

source "$STATE_FILE"

ALL_IPS=("$CONTROL_PLANE_IP" "$WORKER_1_IP" "$WORKER_2_IP")
ALL_NAMES=("control-plane" "worker-1" "worker-2")

# Helper: run a command on a remote node via SSH
run_on() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"
}

# Helper: copy a file to a remote node
copy_to() {
    local ip="$1"
    local src="$2"
    local dst="$3"
    scp $SSH_OPTS "$src" "${SSH_USER}@${ip}:${dst}"
}

wait_for_ssh() {
    local ip="$1"
    local name="$2"
    echo "  Waiting for SSH on $name ($ip)..."
    for attempt in $(seq 1 30); do
        if ssh $SSH_OPTS -o BatchMode=yes "${SSH_USER}@${ip}" true 2>/dev/null; then
            echo "  $name is reachable."
            return 0
        fi
        sleep 10
    done
    echo "ERROR: Timed out waiting for $name ($ip)"
    exit 1
}

echo "=== MS2M Kubernetes Cluster Installation ==="
echo "Control Plane: $CONTROL_PLANE_IP"
echo "Worker 1:      $WORKER_1_IP"
echo "Worker 2:      $WORKER_2_IP"
echo ""

# ------------------------------------------------------------------
# Step 0: Wait for all nodes to be reachable
# ------------------------------------------------------------------
echo "[0/7] Waiting for nodes to become reachable..."
for idx in "${!ALL_IPS[@]}"; do
    wait_for_ssh "${ALL_IPS[$idx]}" "${ALL_NAMES[$idx]}"
done

# ------------------------------------------------------------------
# Step 1: Install CRI-O, CRIU, and kubeadm on every node
# ------------------------------------------------------------------
echo "[1/7] Installing CRI-O, CRIU, and Kubernetes packages on all nodes..."

install_node_packages() {
    local ip="$1"
    local name="$2"
    echo "  Configuring $name ($ip)..."

    run_on "$ip" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Disable swap (required by kubelet)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load required kernel modules
cat > /etc/modules-load.d/k8s.conf <<MOD
overlay
br_netfilter
MOD
modprobe overlay
modprobe br_netfilter

# Sysctl params for kubernetes networking
cat > /etc/sysctl.d/k8s.conf <<SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system >/dev/null 2>&1

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg2 software-properties-common

# Install CRIU (checkpoint/restore support)
apt-get install -y -qq criu

# Install CRI-O
OS="xUbuntu_22.04"
CRIO_VER="1.28"
curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key" \
    | gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg
curl -fsSL "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VER/$OS/Release.key" \
    | gpg --dearmor -o /usr/share/keyrings/libcontainers-crio-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" \
    > /etc/apt/sources.list.d/libcontainers.list
echo "deb [signed-by=/usr/share/keyrings/libcontainers-crio-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VER/$OS/ /" \
    > /etc/apt/sources.list.d/cri-o.list

apt-get update -qq
apt-get install -y -qq cri-o cri-o-runc
systemctl enable --now crio

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
    | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Enable the ContainerCheckpoint feature gate in kubelet
mkdir -p /etc/default
if ! grep -q "ContainerCheckpoint" /etc/default/kubelet 2>/dev/null; then
    echo 'KUBELET_EXTRA_ARGS="--feature-gates=ContainerCheckpoint=true"' > /etc/default/kubelet
fi

systemctl enable kubelet
REMOTE_SCRIPT

    echo "  $name done."
}

for idx in "${!ALL_IPS[@]}"; do
    install_node_packages "${ALL_IPS[$idx]}" "${ALL_NAMES[$idx]}"
done

# ------------------------------------------------------------------
# Step 2: Initialize the control plane
# ------------------------------------------------------------------
echo "[2/7] Initializing Kubernetes control plane..."

run_on "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Calico expects 192.168.0.0/16 by default
kubeadm init \
    --pod-network-cidr=192.168.0.0/16 \
    --cri-socket=unix:///var/run/crio/crio.sock \
    --upload-certs

# Set up kubeconfig for root
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
REMOTE_SCRIPT

# Retrieve the join command for worker nodes
JOIN_CMD=$(run_on "$CONTROL_PLANE_IP" "kubeadm token create --print-join-command")
echo "  Join command retrieved."

# ------------------------------------------------------------------
# Step 3: Join worker nodes to the cluster
# ------------------------------------------------------------------
echo "[3/7] Joining worker nodes to the cluster..."

for idx in 1 2; do
    ip="${ALL_IPS[$idx]}"
    name="${ALL_NAMES[$idx]}"
    echo "  Joining $name ($ip)..."
    run_on "$ip" "$JOIN_CMD --cri-socket=unix:///var/run/crio/crio.sock"
    echo "  $name joined."
done

# ------------------------------------------------------------------
# Step 4: Install Calico CNI
# ------------------------------------------------------------------
echo "[4/7] Installing Calico CNI..."

run_on "$CONTROL_PLANE_IP" bash -s <<REMOTE_SCRIPT
set -euo pipefail
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

# Wait for calico pods to be ready (timeout after 3 minutes)
echo "  Waiting for Calico pods..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=180s || true
REMOTE_SCRIPT

echo "  Calico installed."

# ------------------------------------------------------------------
# Step 5: Deploy RabbitMQ
# ------------------------------------------------------------------
echo "[5/7] Deploying RabbitMQ..."

run_on "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

kubectl create namespace rabbitmq --dry-run=client -o yaml | kubectl apply -f -

cat <<'RABBITMQ_MANIFEST' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: rabbitmq
spec:
  selector:
    app: rabbitmq
  ports:
  - name: amqp
    port: 5672
    targetPort: 5672
  - name: management
    port: 15672
    targetPort: 15672
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: rabbitmq
spec:
  serviceName: rabbitmq
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
      - name: rabbitmq
        image: rabbitmq:3.12-management
        ports:
        - containerPort: 5672
          name: amqp
        - containerPort: 15672
          name: management
        env:
        - name: RABBITMQ_DEFAULT_USER
          value: guest
        - name: RABBITMQ_DEFAULT_PASS
          value: guest
        volumeMounts:
        - name: data
          mountPath: /var/lib/rabbitmq
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
RABBITMQ_MANIFEST

echo "  Waiting for RabbitMQ to be ready..."
kubectl -n rabbitmq wait --for=condition=Ready pod/rabbitmq-0 --timeout=180s || true
REMOTE_SCRIPT

echo "  RabbitMQ deployed."

# ------------------------------------------------------------------
# Step 6: Deploy a local container registry
# ------------------------------------------------------------------
echo "[6/7] Deploying container registry..."

run_on "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f -

cat <<'REGISTRY_MANIFEST' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
      volumes:
      - name: data
        emptyDir: {}
REGISTRY_MANIFEST

echo "  Waiting for registry to be ready..."
kubectl -n registry wait --for=condition=Available deployment/registry --timeout=120s || true

# Get the NodePort for configuring CRI-O insecure registries
NODEPORT=$(kubectl -n registry get svc registry -o jsonpath='{.spec.ports[0].nodePort}')
echo "  Registry available on NodePort: $NODEPORT"
REMOTE_SCRIPT

echo "  Container registry deployed."

# ------------------------------------------------------------------
# Step 7: Apply CRD, RBAC, and copy kubeconfig
# ------------------------------------------------------------------
echo "[7/7] Applying CRD, RBAC, and copying kubeconfig..."

# Copy CRD and RBAC manifests to control plane and apply them
CRD_FILE="config/crd/bases/migration.ms2m.io_statefulmigrations.yaml"
RBAC_FILE="config/rbac/role.yaml"

if [[ -f "$CRD_FILE" ]]; then
    copy_to "$CONTROL_PLANE_IP" "$CRD_FILE" "/tmp/crd.yaml"
    run_on "$CONTROL_PLANE_IP" "kubectl apply -f /tmp/crd.yaml"
    echo "  CRD applied."
else
    echo "  WARNING: CRD file not found at $CRD_FILE, skipping."
fi

if [[ -f "$RBAC_FILE" ]]; then
    copy_to "$CONTROL_PLANE_IP" "$RBAC_FILE" "/tmp/rbac.yaml"
    run_on "$CONTROL_PLANE_IP" "kubectl apply -f /tmp/rbac.yaml"
    echo "  RBAC applied."
else
    echo "  WARNING: RBAC file not found at $RBAC_FILE, skipping."
fi

# Copy kubeconfig to local machine
KUBECONFIG_LOCAL="eval/infra/kubeconfig"
mkdir -p "$(dirname "$KUBECONFIG_LOCAL")"
scp $SSH_OPTS "${SSH_USER}@${CONTROL_PLANE_IP}:/etc/kubernetes/admin.conf" "$KUBECONFIG_LOCAL"

# Replace the internal API server address with the public IP
sed -i "s|https://.*:6443|https://${CONTROL_PLANE_IP}:6443|g" "$KUBECONFIG_LOCAL"

echo "  Kubeconfig saved to: $KUBECONFIG_LOCAL"

echo ""
echo "=== Cluster Installation Complete ==="
echo ""
echo "To use the cluster:"
echo "  export KUBECONFIG=$(pwd)/$KUBECONFIG_LOCAL"
echo "  kubectl get nodes"
echo ""
echo "RabbitMQ management UI (from within cluster):"
echo "  kubectl -n rabbitmq port-forward svc/rabbitmq 15672:15672"
echo ""
echo "Container registry (from within cluster):"
echo "  registry.registry.svc.cluster.local:5000"
