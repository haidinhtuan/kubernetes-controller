package main

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHandleCheckpointUpload(t *testing.T) {
	tmpDir := t.TempDir()
	handler := &checkpointHandler{storageDir: tmpDir, skipLoad: true}

	tarData := []byte("fake tar content for testing")
	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)
	part, _ := writer.CreateFormFile("checkpoint", "checkpoint.tar")
	part.Write(tarData)
	writer.WriteField("containerName", "mycontainer")
	writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/checkpoint", &buf)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleCheckpointUpload_MethodNotAllowed(t *testing.T) {
	handler := &checkpointHandler{storageDir: t.TempDir(), skipLoad: true}
	req := httptest.NewRequest(http.MethodGet, "/checkpoint", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", rr.Code)
	}
}

func TestHandleCheckpointUpload_NoFile(t *testing.T) {
	handler := &checkpointHandler{storageDir: t.TempDir(), skipLoad: true}
	req := httptest.NewRequest(http.MethodPost, "/checkpoint", nil)
	req.Header.Set("Content-Type", "multipart/form-data; boundary=xxx")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rr.Code)
	}
}
