# Plan: MS2M Kubernetes Migration Controller

This plan outlines the steps to implement the **Migration Manager** controller for the Message-based Stateful Microservice Migration (MS2M) framework.

## 1. Project Initialization
- [ ] Initialize Go module: `go mod init <module-name>`
- [ ] Install dependencies:
    - `sigs.k8s.io/controller-runtime`
    - `k8s.io/client-go`
    - `k8s.io/api`
    - `k8s.io/apimachinery`
    - Message Broker Client (e.g., `github.com/rabbitmq/amqp091-go` or NATS client)

## 2. API Definition (CRD: `StatefulMigration`)
- [ ] Define `StatefulMigration` Custom Resource:
    - **Spec**:
        - `SourcePod` (Name, Namespace)
        - `TargetNode` (Optional node selector)
        - `CheckpointImageRepository` (Registry to push checkpoint image)
        - `ReplayCutoffSeconds` (Threshold-based cutoff time)
        - `MessageQueueConfig` (Queue names, Broker URL)
    - **Status**:
        - `Phase` (Pending, Checkpointing, Transferring, Restoring, Replaying, Finalizing, Completed, Failed)
        - `SourceNode`
        - `CheckpointID`
        - `TargetPodName`
        - Conditions (Standard K8s conditions)

## 3. Controller Logic (Migration Manager)
The Reconciler will manage the state machine moving through the 5 phases:

### Phase 1: Checkpoint Creation
- [ ] **Action**:
    - Trigger message buffering (Create Secondary Queue).
    - Call Kubelet Checkpoint API: `POST /api/v1/nodes/{node}/proxy/checkpoint/...`
- [ ] **Validation**: Verify checkpoint tarball exists on Source Node (or success response).

### Phase 2: Checkpoint Transfer
- [ ] **Action**:
    - *Note: This requires execution on the Node.*
    - Launch a "Transfer Job" (Privileged Pod) or use a DaemonSet agent on the Source Node to:
        - Take the checkpoint file.
        - Build OCI Image (`buildah` or similar).
        - Push to `CheckpointImageRepository`.
- [ ] **Validation**: Verify Image exists in Registry.

### Phase 3: Service Restoration
- [ ] **Action**:
    - Create Target Pod manifest.
    - Add Annotation for checkpoint restoration (dependant on container runtime/CRIU integration).
    - Schedule on Target Node.
- [ ] **Validation**: Wait for Target Pod to be `Running`.

### Phase 4: Message Replay
- [ ] **Action**:
    - Send `START_REPLAY` control message to Target Pod.
    - Monitor lag/queue depth.
    - **Logic**: If lag > `ReplayCutoffSeconds` -> Stop Source Pod (Freeze).
- [ ] **Validation**: Wait for Target Pod to signal catch-up.

### Phase 5: Finalization
- [ ] **Action**:
    - Send `END_REPLAY` control message.
    - Switch Target Pod to Primary Queue (Live Traffic).
    - Delete/Terminate Source Pod.
- [ ] **Validation**: Migration marked `Completed`.

## 4. Components & Interfaces
- [ ] **Kubelet Client**: Wrapper for interacting with the Checkpoint API.
- [ ] **Messaging Client**: Interface for Queue switching and Control Messages.
- [ ] **Registry Client**: Helper to check image existence (optional).

## 5. Deployment Manifests
- [ ] **RBAC**:
    - `nodes/proxy` (For checkpoint API).
    - `pods/create`, `pods/delete`, `pods/exec`.
- [ ] **CRD**: `statefulmigrations.mydomain.io`.
- [ ] **Manager Deployment**: The Controller Pod.

## 6. Build & Test
- [ ] `Dockerfile` for Controller.
- [ ] `Makefile`.
- [ ] Unit Tests for State Machine logic.