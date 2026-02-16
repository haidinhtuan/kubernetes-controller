package main

import (
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/crane"
	"github.com/haidinhtuan/kubernetes-controller/internal/checkpoint"
)

func main() {
	if len(os.Args) < 3 || len(os.Args) > 4 {
		fmt.Fprintf(os.Stderr, "usage: %s <checkpoint-tar-path> <image-ref-or-url> [container-name]\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "\nModes:\n")
		fmt.Fprintf(os.Stderr, "  Registry: provide an image reference (e.g. registry:5000/checkpoint:tag)\n")
		fmt.Fprintf(os.Stderr, "  Direct:   provide an HTTP URL (e.g. http://node:8080/upload)\n")
		os.Exit(1)
	}

	checkpointPath := os.Args[1]
	target := os.Args[2]
	containerName := ""
	if len(os.Args) == 4 {
		containerName = os.Args[3]
	}

	totalStart := time.Now()

	if strings.HasPrefix(target, "http") {
		if err := directTransfer(checkpointPath, target, containerName); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	} else {
		if err := registryTransfer(checkpointPath, target, containerName); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	}

	fmt.Printf("Total time: %s\n", time.Since(totalStart))
}

// registryTransfer builds an OCI image from the checkpoint and pushes it to a container registry.
func registryTransfer(checkpointPath, imageRef, containerName string) error {
	fmt.Printf("Building checkpoint image from %s\n", checkpointPath)
	buildStart := time.Now()
	img, err := checkpoint.BuildCheckpointImage(checkpointPath, containerName)
	if err != nil {
		return fmt.Errorf("building image: %w", err)
	}
	fmt.Printf("Image built in %s\n", time.Since(buildStart))

	fmt.Printf("Pushing image to %s\n", imageRef)
	pushStart := time.Now()

	opts := []crane.Option{crane.WithAuthFromKeychain(authn.DefaultKeychain)}
	if os.Getenv("INSECURE_REGISTRY") != "" {
		opts = append(opts, crane.Insecure)
	}

	if err := crane.Push(img, imageRef, opts...); err != nil {
		return fmt.Errorf("pushing image: %w", err)
	}

	fmt.Printf("Image pushed in %s\n", time.Since(pushStart))
	return nil
}

// directTransfer POSTs the checkpoint tar file directly to an ms2m-agent endpoint via HTTP.
func directTransfer(checkpointPath, targetURL, containerName string) error {
	fmt.Printf("Direct transfer: sending %s to %s\n", checkpointPath, targetURL)

	f, err := os.Open(checkpointPath)
	if err != nil {
		return fmt.Errorf("opening checkpoint file: %w", err)
	}
	defer f.Close()

	pr, pw := io.Pipe()
	writer := multipart.NewWriter(pw)

	// Write the multipart form in a goroutine to stream it without buffering the whole file.
	errCh := make(chan error, 1)
	go func() {
		defer pw.Close()

		if containerName != "" {
			if err := writer.WriteField("containerName", containerName); err != nil {
				errCh <- fmt.Errorf("writing containerName field: %w", err)
				return
			}
		}

		part, err := writer.CreateFormFile("checkpoint", "checkpoint.tar")
		if err != nil {
			errCh <- fmt.Errorf("creating form file: %w", err)
			return
		}

		if _, err := io.Copy(part, f); err != nil {
			errCh <- fmt.Errorf("copying checkpoint data: %w", err)
			return
		}

		errCh <- writer.Close()
	}()

	uploadStart := time.Now()
	resp, err := http.Post(targetURL, writer.FormDataContentType(), pr)
	if err != nil {
		return fmt.Errorf("posting checkpoint: %w", err)
	}
	defer resp.Body.Close()

	// Check for errors from the multipart writer goroutine.
	if writeErr := <-errCh; writeErr != nil {
		return writeErr
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("server returned %d: %s", resp.StatusCode, string(body))
	}

	fmt.Printf("Checkpoint transferred in %s\n", time.Since(uploadStart))
	return nil
}
