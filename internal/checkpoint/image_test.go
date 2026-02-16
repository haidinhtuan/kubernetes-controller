package checkpoint

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBuildCheckpointImage(t *testing.T) {
	tmpDir := t.TempDir()
	tarPath := filepath.Join(tmpDir, "checkpoint.tar")
	if err := os.WriteFile(tarPath, []byte("fake checkpoint data"), 0644); err != nil {
		t.Fatal(err)
	}

	img, err := BuildCheckpointImage(tarPath, "mycontainer")
	if err != nil {
		t.Fatalf("BuildCheckpointImage failed: %v", err)
	}
	if img == nil {
		t.Fatal("expected non-nil image")
	}

	manifest, err := img.Manifest()
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Annotations["io.kubernetes.cri-o.annotations.checkpoint.name"] != "mycontainer" {
		t.Error("expected checkpoint annotation")
	}
}

func TestBuildCheckpointImage_NoContainerName(t *testing.T) {
	tmpDir := t.TempDir()
	tarPath := filepath.Join(tmpDir, "checkpoint.tar")
	os.WriteFile(tarPath, []byte("fake"), 0644)

	img, err := BuildCheckpointImage(tarPath, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if img == nil {
		t.Fatal("expected non-nil image")
	}
}

func TestBuildCheckpointImage_FileNotFound(t *testing.T) {
	_, err := BuildCheckpointImage("/nonexistent/path.tar", "test")
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}
