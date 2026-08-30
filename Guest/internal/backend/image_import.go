package backend

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	containerimages "github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/errdefs"
	digest "github.com/opencontainers/go-digest"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"

	"github.com/glassdock/glassdock/guest/internal/api"
)

func (b *Backend) ImportImages(ctx context.Context, request api.ImageImportRequest) (api.ImageImportResponse, error) {
	if len(request.Data) == 0 {
		return api.ImageImportResponse{}, errors.New("image archive is empty")
	}

	if isRootfsTarball(request.Data) {
		return b.importRootfsTarball(ctx, request)
	}

	// Default platform handling: containerd records whichever platform
	// manifests are present and readable. WithAllPlatforms(true) would instead
	// require blobs for every platform named in an index, which fails for
	// single-platform archives such as our own exports.
	options := []containerd.ImportOpt{}
	if request.Reference != "" {
		options = append(options, containerd.WithIndexName(request.Reference))
	}
	imported, err := b.client.Import(b.ctx(ctx), bytes.NewReader(request.Data), options...)
	if err != nil {
		return api.ImageImportResponse{}, err
	}
	response := api.ImageImportResponse{Images: make([]api.ImageResponse, 0, len(imported))}
	for _, image := range imported {
		if image.Name == "" {
			continue
		}
		response.Images = append(response.Images, api.ImageResponse{
			Name:   image.Name,
			Digest: image.Target.Digest.String(),
		})
	}
	if len(response.Images) == 0 {
		return api.ImageImportResponse{}, errors.New("image archive contains no named images")
	}
	return response, nil
}

// isRootfsTarball reports whether the archive is a plain rootfs tarball — the
// input format of `docker import` — rather than an OCI layout or a
// `docker save` archive. Both image-archive formats carry a metadata entry in
// their first tar entries; rootfs tarballs start with filesystem paths.
func isRootfsTarball(data []byte) bool {
	reader := tar.NewReader(bytes.NewReader(data))
	for {
		header, err := reader.Next()
		if err != nil {
			return true
		}
		switch header.Name {
		case "index.json", "manifest.json", "oci-layout":
			return false
		}
	}
}

// importRootfsTarball implements `docker import`: it turns an unstructured
// rootfs tarball into a single-layer image. The tarball is stored verbatim as
// an uncompressed OCI layer blob, wrapped with a generated config and a
// schema-2 manifest, and tagged with the requested reference.
func (b *Backend) importRootfsTarball(
	ctx context.Context, request api.ImageImportRequest,
) (api.ImageImportResponse, error) {
	ctx = b.ctx(ctx)
	store := b.client.ContentStore()

	// Docker import ships the layer gzipped; containerd's unpack path is
	// happiest with the compressed media type, so store it that way.
	var gzipped bytes.Buffer
	gzipWriter := gzip.NewWriter(&gzipped)
	if _, err := gzipWriter.Write(request.Data); err != nil {
		return api.ImageImportResponse{}, err
	}
	if err := gzipWriter.Close(); err != nil {
		return api.ImageImportResponse{}, err
	}
	compressed := gzipped.Bytes()
	compressedDigest := digest.FromBytes(compressed)
	diffID := digest.FromBytes(request.Data)

	// The lease keeps every blob written below safe from the garbage collector
	// until the image record references them.
	ctx, done, err := b.client.WithLease(ctx)
	if err != nil {
		return api.ImageImportResponse{}, fmt.Errorf("create import lease: %w", err)
	}
	defer done(ctx)

	// Unique per attempt: containerd writers keyed by ref interact badly with
	// committed transactions from previous imports of identical content.
	layerRef := fmt.Sprintf("import-rootfs-%s-%d", compressedDigest, time.Now().UnixNano())
	if err := writeContentBlob(ctx, store, layerRef+"-layer", compressed, nil); err != nil {
		return api.ImageImportResponse{}, fmt.Errorf("store rootfs layer: %w", err)
	}

	now := time.Now()
	config := imagespec.Image{
		Created: &now,
		Platform: imagespec.Platform{
			Architecture: runtime.GOARCH,
			OS:           "linux",
		},
		RootFS: imagespec.RootFS{
			Type:    "layers",
			DiffIDs: []digest.Digest{diffID},
		},
		History: []imagespec.History{{
			Created:   &now,
			CreatedBy: "glassdock import",
			Comment:   "imported from rootfs tarball",
		}},
	}
	configJSON, err := json.Marshal(config)
	if err != nil {
		return api.ImageImportResponse{}, err
	}
	configDigest := digest.FromBytes(configJSON)
	if err := writeContentBlob(ctx, store, layerRef+"-config", configJSON, nil); err != nil {
		return api.ImageImportResponse{}, fmt.Errorf("store image config: %w", err)
	}
	if _, err := store.Info(ctx, configDigest); err != nil {
		return api.ImageImportResponse{}, fmt.Errorf("config blob vanished right after write: %w", err)
	}

	manifest := imagespec.Manifest{
		MediaType: imagespec.MediaTypeImageManifest,
		Config: imagespec.Descriptor{
			MediaType: imagespec.MediaTypeImageConfig,
			Digest:    configDigest,
			Size:      int64(len(configJSON)),
		},
		Layers: []imagespec.Descriptor{{
			MediaType: imagespec.MediaTypeImageLayerGzip,
			Digest:    compressedDigest,
			Size:      int64(len(compressed)),
		}},
	}
	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		return api.ImageImportResponse{}, err
	}
	manifestDescriptor := imagespec.Descriptor{
		MediaType: imagespec.MediaTypeImageManifest,
		Digest:    digest.FromBytes(manifestJSON),
		Size:      int64(len(manifestJSON)),
	}
	// The garbage collector tracks blob dependencies through these labels.
	// Without them the config and layer look unreferenced once the import
	// lease is gone and get collected within seconds.
	manifestLabels := map[string]string{
		"containerd.io/gc.ref.content.config": configDigest.String(),
		"containerd.io/gc.ref.content.l.0":    compressedDigest.String(),
	}
	if err := writeContentBlob(ctx, store, layerRef+"-manifest", manifestJSON, manifestLabels); err != nil {
		return api.ImageImportResponse{}, fmt.Errorf("store image manifest: %w", err)
	}

	name := request.Reference
	if name == "" {
		name = fmt.Sprintf("imported-%s:latest", diffID.Encoded()[:12])
	}
	record := containerimages.Image{
		Name:      name,
		Target:    manifestDescriptor,
		CreatedAt: now,
	}
	if _, err := b.client.ImageService().Create(ctx, record); err != nil {
		if errdefs.IsAlreadyExists(err) && request.Reference != "" {
			// docker import re-runs overwrite the tag.
			if _, updateErr := b.client.ImageService().Update(ctx, record); updateErr != nil {
				return api.ImageImportResponse{}, updateErr
			}
		} else if errdefs.IsAlreadyExists(err) {
			_ = b.client.ImageService().Delete(ctx, name)
			if _, createErr := b.client.ImageService().Create(ctx, record); createErr != nil {
				return api.ImageImportResponse{}, createErr
			}
		} else {
			return api.ImageImportResponse{}, err
		}
	}
	// Unlike pulls, imports do not unpack automatically; without this the
	// first container creation fails on a missing parent snapshot.
	if image, err := b.client.GetImage(ctx, name); err == nil {
		if err := b.ensureImageUnpacked(ctx, image, b.snapshotter); err != nil {
			return api.ImageImportResponse{}, fmt.Errorf("unpack imported image: %w", err)
		}
	}
	return api.ImageImportResponse{Images: []api.ImageResponse{{
		Name:   name,
		Digest: manifestDescriptor.Digest.String(),
	}}}, nil
}

func writeContentBlob(
	ctx context.Context, store content.Store, ref string, data []byte, labels map[string]string,
) error {
	writer, err := store.Writer(ctx, content.WithRef(ref), content.WithDescriptor(imagespec.Descriptor{
		Digest: digest.FromBytes(data),
		Size:   int64(len(data)),
	}))
	if err != nil {
		return err
	}
	defer writer.Close()
	if _, err := io.Copy(writer, bytes.NewReader(data)); err != nil {
		return err
	}
	if labels == nil {
		return writer.Commit(ctx, int64(len(data)), digest.FromBytes(data))
	}
	return writer.Commit(ctx, int64(len(data)), digest.FromBytes(data), content.WithLabels(labels))
}
