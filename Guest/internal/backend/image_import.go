package backend

import (
	"bytes"
	"context"
	"errors"

	containerd "github.com/containerd/containerd/v2/client"

	"github.com/glassdock/glassdock/guest/internal/api"
)

func (b *Backend) ImportImages(ctx context.Context, request api.ImageImportRequest) (api.ImageImportResponse, error) {
	if len(request.Data) == 0 {
		return api.ImageImportResponse{}, errors.New("image archive is empty")
	}
	options := []containerd.ImportOpt{containerd.WithAllPlatforms(true)}
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
