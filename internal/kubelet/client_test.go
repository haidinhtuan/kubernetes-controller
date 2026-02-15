package kubelet

import (
	"encoding/json"
	"testing"
)

func TestCheckpointResponse_Parse(t *testing.T) {
	raw := `{"items":["checkpoint-myapp-2024-01-15T10:30:00Z.tar","checkpoint-myapp-2024-01-15T10:31:00Z.tar"]}`

	var resp CheckpointResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("failed to unmarshal checkpoint response: %v", err)
	}

	if len(resp.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(resp.Items))
	}

	expected := []string{
		"checkpoint-myapp-2024-01-15T10:30:00Z.tar",
		"checkpoint-myapp-2024-01-15T10:31:00Z.tar",
	}
	for i, item := range resp.Items {
		if item != expected[i] {
			t.Errorf("item[%d]: expected %q, got %q", i, expected[i], item)
		}
	}
}

func TestCheckpointResponse_ParseEmpty(t *testing.T) {
	raw := `{"items":[]}`

	var resp CheckpointResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("failed to unmarshal empty checkpoint response: %v", err)
	}

	if len(resp.Items) != 0 {
		t.Fatalf("expected 0 items, got %d", len(resp.Items))
	}
}

func TestBuildCheckpointPath(t *testing.T) {
	tests := []struct {
		name          string
		nodeName      string
		namespace     string
		podName       string
		containerName string
		want          string
	}{
		{
			name:          "standard path",
			nodeName:      "worker-1",
			namespace:     "default",
			podName:       "myapp-pod",
			containerName: "myapp",
			want:          "/api/v1/nodes/worker-1/proxy/checkpoint/default/myapp-pod/myapp",
		},
		{
			name:          "custom namespace",
			nodeName:      "node-pool-abc",
			namespace:     "production",
			podName:       "api-server-0",
			containerName: "server",
			want:          "/api/v1/nodes/node-pool-abc/proxy/checkpoint/production/api-server-0/server",
		},
		{
			name:          "names with hyphens and numbers",
			nodeName:      "gke-cluster-1-pool-0-abc123",
			namespace:     "kube-system",
			podName:       "redis-master-0",
			containerName: "redis-6379",
			want:          "/api/v1/nodes/gke-cluster-1-pool-0-abc123/proxy/checkpoint/kube-system/redis-master-0/redis-6379",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buildCheckpointPath(tt.nodeName, tt.namespace, tt.podName, tt.containerName)
			if got != tt.want {
				t.Errorf("buildCheckpointPath() = %q, want %q", got, tt.want)
			}
		})
	}
}
