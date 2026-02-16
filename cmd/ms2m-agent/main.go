package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/layout"
	"github.com/haidinhtuan/kubernetes-controller/internal/checkpoint"
)

type checkpointHandler struct {
	storageDir string
	skipLoad   bool // for testing: skip skopeo load
}

func (h *checkpointHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if err := r.ParseMultipartForm(500 << 20); err != nil {
		http.Error(w, fmt.Sprintf("parse form: %v", err), http.StatusBadRequest)
		return
	}

	file, _, err := r.FormFile("checkpoint")
	if err != nil {
		http.Error(w, fmt.Sprintf("get file: %v", err), http.StatusBadRequest)
		return
	}
	defer file.Close()

	containerName := r.FormValue("containerName")

	// Write tar to local storage
	tarPath := filepath.Join(h.storageDir, fmt.Sprintf("checkpoint-%d.tar", time.Now().UnixNano()))
	out, err := os.Create(tarPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("create file: %v", err), http.StatusInternalServerError)
		return
	}
	if _, err := io.Copy(out, file); err != nil {
		out.Close()
		http.Error(w, fmt.Sprintf("write file: %v", err), http.StatusInternalServerError)
		return
	}
	out.Close()

	fmt.Printf("Received checkpoint tar: %s (%s)\n", tarPath, containerName)

	// Build OCI image from tar
	img, err := checkpoint.BuildCheckpointImage(tarPath, containerName)
	if err != nil {
		http.Error(w, fmt.Sprintf("build image: %v", err), http.StatusInternalServerError)
		return
	}

	// Save as OCI layout for skopeo to load
	layoutDir := tarPath + "-oci"
	if err := os.MkdirAll(layoutDir, 0755); err != nil {
		http.Error(w, fmt.Sprintf("mkdir: %v", err), http.StatusInternalServerError)
		return
	}

	p, err := layout.Write(layoutDir, empty.Index)
	if err != nil {
		http.Error(w, fmt.Sprintf("write layout: %v", err), http.StatusInternalServerError)
		return
	}

	if err := p.AppendImage(img); err != nil {
		http.Error(w, fmt.Sprintf("append image: %v", err), http.StatusInternalServerError)
		return
	}

	if !h.skipLoad {
		imageTag := fmt.Sprintf("localhost/checkpoint/%s:latest", containerName)
		cmd := exec.Command("skopeo", "copy",
			"oci:"+layoutDir,
			"containers-storage:"+imageTag)
		output, err := cmd.CombinedOutput()
		if err != nil {
			http.Error(w, fmt.Sprintf("skopeo copy: %v: %s", err, output), http.StatusInternalServerError)
			return
		}
		fmt.Printf("Loaded image into CRI-O: %s\n", imageTag)
	}

	// Cleanup
	os.Remove(tarPath)
	os.RemoveAll(layoutDir)

	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "checkpoint loaded successfully")
}

func main() {
	storageDir := os.Getenv("STORAGE_DIR")
	if storageDir == "" {
		storageDir = "/var/lib/ms2m/incoming"
	}
	os.MkdirAll(storageDir, 0755)

	handler := &checkpointHandler{storageDir: storageDir}

	port := os.Getenv("PORT")
	if port == "" {
		port = "9443"
	}

	fmt.Printf("ms2m-agent listening on :%s\n", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
