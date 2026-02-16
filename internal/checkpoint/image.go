package checkpoint

import (
	"compress/gzip"
	"fmt"

	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/tarball"
	ocitype "github.com/google/go-containerregistry/pkg/v1/types"
)

// BuildCheckpointImage creates a single-layer OCI image from a CRIU checkpoint tarball.
// It skips gzip compression since the image is pushed over a local cluster network
// where CPU cost of compression outweighs the bandwidth savings.
func BuildCheckpointImage(checkpointPath, containerName string) (v1.Image, error) {
	layer, err := tarball.LayerFromFile(checkpointPath, tarball.WithCompressionLevel(gzip.NoCompression))
	if err != nil {
		return nil, fmt.Errorf("creating layer from checkpoint: %w", err)
	}

	// Use OCI media types so CRI-O can detect the checkpoint annotation.
	// empty.Image produces Docker v2 by default; both manifest and config
	// must be OCI to avoid "invalid mixed OCI image" errors.
	base := mutate.MediaType(empty.Image, ocitype.OCIManifestSchema1)
	base = mutate.ConfigMediaType(base, ocitype.OCIConfigJSON)

	img, err := mutate.AppendLayers(base, layer)
	if err != nil {
		return nil, fmt.Errorf("appending layer to image: %w", err)
	}

	if containerName != "" {
		img = mutate.Annotations(img, map[string]string{
			"io.kubernetes.cri-o.annotations.checkpoint.name": containerName,
		}).(v1.Image)
	}

	return img, nil
}
