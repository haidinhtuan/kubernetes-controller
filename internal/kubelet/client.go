package kubelet

import (
	"context"
	"encoding/json"
	"fmt"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// CheckpointResponse holds the result of a kubelet checkpoint API call.
type CheckpointResponse struct {
	Items []string `json:"items"`
}

// Client wraps a Kubernetes REST client to interact with the kubelet
// checkpoint API through the API server proxy.
type Client struct {
	restClient rest.Interface
}

// NewClient creates a new kubelet Client from a Kubernetes clientset.
// It uses the CoreV1 REST client, which provides access to the
// /api/v1/nodes/{node}/proxy/... endpoints.
func NewClient(clientset kubernetes.Interface) *Client {
	return &Client{
		restClient: clientset.CoreV1().RESTClient(),
	}
}

// buildCheckpointPath constructs the full API path for a checkpoint request.
func buildCheckpointPath(nodeName, namespace, podName, containerName string) string {
	return fmt.Sprintf("/api/v1/nodes/%s/proxy/checkpoint/%s/%s/%s",
		nodeName, namespace, podName, containerName)
}

// Checkpoint triggers a container checkpoint via the kubelet API, proxied
// through the Kubernetes API server. It returns the checkpoint response
// containing the list of checkpoint archive paths.
func (c *Client) Checkpoint(ctx context.Context, nodeName, namespace, podName, containerName string) (*CheckpointResponse, error) {
	result := c.restClient.Post().
		Resource("nodes").
		Name(nodeName).
		SubResource("proxy", "checkpoint", namespace, podName, containerName).
		Do(ctx)

	if err := result.Error(); err != nil {
		return nil, fmt.Errorf("checkpoint request for container %s/%s/%s on node %s failed: %w",
			namespace, podName, containerName, nodeName, err)
	}

	rawBody, err := result.Raw()
	if err != nil {
		return nil, fmt.Errorf("reading checkpoint response body: %w", err)
	}

	var resp CheckpointResponse
	if err := json.Unmarshal(rawBody, &resp); err != nil {
		return nil, fmt.Errorf("parsing checkpoint response: %w", err)
	}

	return &resp, nil
}
