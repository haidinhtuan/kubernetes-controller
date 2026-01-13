# Kubernetes Controller Demo

This repository contains a simple Kubernetes Controller written in Go, along with Terraform code to provision a GKE cluster.

## Prerequisites

- Go 1.25+
- Docker
- Terraform
- Google Cloud SDK (`gcloud`)

## Project Structure

- `main.go`: The source code for the controller.
- `Dockerfile`: Instructions to build the container image.
- `terraform/`: Terraform configuration to provision GKE.
- `manifests/`: Kubernetes manifests (Deployment, RBAC).

## Local Development (Running locally)

You can run the controller locally against a remote cluster or a local cluster (like kind or minikube).

1. Ensure your `~/.kube/config` is pointing to the correct cluster.
2. Run the controller:
   ```bash
   go run main.go
   ```

## deploying to GKE

### 1. Provision Infrastructure

Navigate to the `terraform` directory and apply the configuration:

```bash
cd terraform
terraform init
terraform apply -var="project_id=YOUR_PROJECT_ID"
```

Connect to the cluster:

```bash
gcloud container clusters get-credentials my-k8s-controller-cluster --region us-central1-a
```

### 2. Build and Push Image

Build the Docker image and push it to Google Container Registry (GCR) or Artifact Registry.

```bash
export PROJECT_ID=YOUR_PROJECT_ID
docker build -t gcr.io/$PROJECT_ID/k8s-controller:latest .
docker push gcr.io/$PROJECT_ID/k8s-controller:latest
```

### 3. Deploy Controller

Update `manifests/deployment.yaml` with your image name (`gcr.io/YOUR_PROJECT_ID/k8s-controller:latest`).

Apply the manifests:

```bash
kubectl apply -f manifests/rbac.yaml
kubectl apply -f manifests/deployment.yaml
```

### 4. Verify

Check the logs of the controller:

```bash
kubectl get pods
kubectl logs -f deployment/k8s-controller
```

You should see output indicating the number of pods in the cluster.
