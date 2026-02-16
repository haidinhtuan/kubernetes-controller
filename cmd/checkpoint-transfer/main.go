package main

import (
	"fmt"
	"os"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/crane"
	"github.com/haidinhtuan/kubernetes-controller/internal/checkpoint"
)

func main() {
	if len(os.Args) < 3 || len(os.Args) > 4 {
		fmt.Fprintf(os.Stderr, "usage: %s <checkpoint-tar-path> <image-ref> [container-name]\n", os.Args[0])
		os.Exit(1)
	}

	checkpointPath := os.Args[1]
	imageRef := os.Args[2]
	containerName := ""
	if len(os.Args) == 4 {
		containerName = os.Args[3]
	}

	totalStart := time.Now()

	fmt.Printf("Building checkpoint image from %s\n", checkpointPath)
	buildStart := time.Now()
	img, err := checkpoint.BuildCheckpointImage(checkpointPath, containerName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error building image: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Image built in %s\n", time.Since(buildStart))

	fmt.Printf("Pushing image to %s\n", imageRef)
	pushStart := time.Now()

	opts := []crane.Option{crane.WithAuthFromKeychain(authn.DefaultKeychain)}
	if os.Getenv("INSECURE_REGISTRY") != "" {
		opts = append(opts, crane.Insecure)
	}

	if err := crane.Push(img, imageRef, opts...); err != nil {
		fmt.Fprintf(os.Stderr, "error pushing image: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Image pushed in %s (total: %s)\n", time.Since(pushStart), time.Since(totalStart))
}
