package main

import (
	"io"
	"os"
	"testing"
)

func TestBuildCheckpointImage_InvalidPath(t *testing.T) {
	_, err := buildCheckpointImage("/nonexistent/path/checkpoint.tar", "test-container")
	if err == nil {
		t.Fatal("expected error for nonexistent file, got nil")
	}
}

func TestBuildCheckpointImage_ValidTar(t *testing.T) {
	// Create a minimal tar file (1024 zero bytes is a valid empty tar archive).
	tmpFile, err := os.CreateTemp(t.TempDir(), "checkpoint-*.tar")
	if err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}

	buf := make([]byte, 1024)
	if _, err := tmpFile.Write(buf); err != nil {
		tmpFile.Close()
		t.Fatalf("failed to write tar data: %v", err)
	}
	tmpFile.Close()

	img, err := buildCheckpointImage(tmpFile.Name(), "my-container")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if img == nil {
		t.Fatal("expected non-nil image")
	}

	layers, err := img.Layers()
	if err != nil {
		t.Fatalf("failed to get layers: %v", err)
	}
	if len(layers) != 1 {
		t.Fatalf("expected 1 layer, got %d", len(layers))
	}
}

func TestBuildCheckpointImage_NoCompression(t *testing.T) {
	// Verify that the layer is not gzip-compressed (NoCompression mode).
	// With gzip.NoCompression the compressed size should be close to (or
	// slightly larger than) the uncompressed size, not smaller.
	tmpFile, err := os.CreateTemp(t.TempDir(), "checkpoint-*.tar")
	if err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}

	// Write a compressible payload (repeated pattern)
	data := make([]byte, 64*1024)
	for i := range data {
		data[i] = byte(i % 7)
	}
	if _, err := tmpFile.Write(data); err != nil {
		tmpFile.Close()
		t.Fatalf("failed to write tar data: %v", err)
	}
	tmpFile.Close()

	img, err := buildCheckpointImage(tmpFile.Name(), "test")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	layers, _ := img.Layers()
	layer := layers[0]

	compressed, _ := layer.Compressed()
	compressedBytes, _ := io.ReadAll(compressed)

	uncompressed, _ := layer.Uncompressed()
	uncompressedBytes, _ := io.ReadAll(uncompressed)

	// With NoCompression, the compressed stream is the raw data wrapped in
	// gzip framing — it should be *larger* than the raw data (gzip header
	// overhead), not smaller. A real gzip-compressed stream would be much
	// smaller for this repetitive payload.
	ratio := float64(len(compressedBytes)) / float64(len(uncompressedBytes))
	if ratio < 0.95 {
		t.Errorf("layer appears to be gzip-compressed: compressed=%d, uncompressed=%d, ratio=%.2f",
			len(compressedBytes), len(uncompressedBytes), ratio)
	}
}
