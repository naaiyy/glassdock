package backend

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	containerimages "github.com/containerd/containerd/v2/core/images"
	rootfsarchive "github.com/containerd/containerd/v2/pkg/archive"
	"github.com/containerd/errdefs"
	digest "github.com/opencontainers/go-digest"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"

	"github.com/glassdock/glassdock/guest/internal/api"
)

// CommitImage snapshots the active container root without committing the
// containerd snapshot itself. Committing the active snapshot would consume the
// snapshot key and make the source container unusable, so the diff is stored as
// a new image layer instead.
func (b *Backend) CommitImage(ctx context.Context, request api.ImageCommitRequest) (api.ImageResponse, error) {
	if request.Container == "" {
		return api.ImageResponse{}, errors.New("container reference is required")
	}

	ctx = b.ctx(ctx)
	container, err := b.client.LoadContainer(ctx, request.Container)
	if err != nil {
		return api.ImageResponse{}, err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return api.ImageResponse{}, err
	}
	if info.SnapshotKey == "" || info.Snapshotter == "" {
		return api.ImageResponse{}, errors.New("container root filesystem is unavailable")
	}

	source, err := b.client.GetImage(ctx, info.Image)
	if err != nil {
		return api.ImageResponse{}, err
	}
	manifest, err := containerimages.Manifest(ctx, source.ContentStore(), source.Target(), nil)
	if err != nil {
		return api.ImageResponse{}, err
	}
	configDescriptor, err := source.Config(ctx)
	if err != nil {
		return api.ImageResponse{}, err
	}
	configData, err := content.ReadBlob(ctx, source.ContentStore(), configDescriptor)
	if err != nil {
		return api.ImageResponse{}, err
	}
	var imageConfig imagespec.Image
	if err := json.Unmarshal(configData, &imageConfig); err != nil {
		return api.ImageResponse{}, fmt.Errorf("decode source image configuration: %w", err)
	}
	if err := applyCommitChanges(&imageConfig, request.Changes); err != nil {
		return api.ImageResponse{}, err
	}

	resume, err := pauseCommitTask(ctx, container, request.Pause)
	if err != nil {
		return api.ImageResponse{}, err
	}
	defer resume()

	currentRoot, currentCleanup, err := b.mountContainerRoot(ctx, request.Container, "glassdock-commit-current-")
	if err != nil {
		return api.ImageResponse{}, err
	}
	defer currentCleanup()

	service := b.client.SnapshotService(info.Snapshotter)
	snapshotInfo, err := service.Stat(ctx, info.SnapshotKey)
	if err != nil {
		return api.ImageResponse{}, err
	}
	parentRoot, parentCleanup, err := b.mountSnapshotParent(ctx, service, snapshotInfo.Parent)
	if err != nil {
		return api.ImageResponse{}, err
	}
	defer parentCleanup()

	layerFile, err := os.CreateTemp("", "glassdock-commit-layer-")
	if err != nil {
		return api.ImageResponse{}, err
	}
	layerPath := layerFile.Name()
	defer layerFile.Close()
	defer os.Remove(layerPath)

	diff := rootfsarchive.Diff(ctx, parentRoot, currentRoot)
	hasher := sha256.New()
	layerSize, err := io.Copy(io.MultiWriter(layerFile, hasher), diff)
	closeErr := diff.Close()
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("write container diff: %w", err)
	}
	if closeErr != nil {
		return api.ImageResponse{}, fmt.Errorf("close container diff: %w", closeErr)
	}
	if _, err := layerFile.Seek(0, io.SeekStart); err != nil {
		return api.ImageResponse{}, err
	}

	layerDescriptor := imagespec.Descriptor{
		MediaType: commitLayerMediaType(manifest),
		Digest:    digest.NewDigestFromBytes(digest.SHA256, hasher.Sum(nil)),
		Size:      layerSize,
	}
	leaseContext, releaseLease, err := b.client.WithLease(ctx)
	if err != nil {
		return api.ImageResponse{}, err
	}
	defer releaseLease(context.WithoutCancel(leaseContext))
	ctx = leaseContext
	if err := content.WriteBlob(
		ctx,
		b.client.ContentStore(),
		fmt.Sprintf("glassdock-commit-layer-%s", layerDescriptor.Digest.Encoded()),
		layerFile,
		layerDescriptor,
	); err != nil {
		return api.ImageResponse{}, fmt.Errorf("store container diff: %w", err)
	}

	now := time.Now().UTC()
	imageConfig.Created = &now
	imageConfig.RootFS.Type = "layers"
	imageConfig.RootFS.DiffIDs = append(imageConfig.RootFS.DiffIDs, layerDescriptor.Digest)
	imageConfig.History = append(imageConfig.History, imagespec.History{
		Created:    &now,
		Author:     request.Author,
		Comment:    request.Comment,
		CreatedBy:  "glassdock commit",
		EmptyLayer: false,
	})
	newConfigData, err := json.Marshal(imageConfig)
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("encode committed image configuration: %w", err)
	}
	newConfigDescriptor := imagespec.Descriptor{
		MediaType: configDescriptor.MediaType,
		Digest:    digest.FromBytes(newConfigData),
		Size:      int64(len(newConfigData)),
	}
	if newConfigDescriptor.MediaType == "" {
		newConfigDescriptor.MediaType = imagespec.MediaTypeImageConfig
	}
	if err := content.WriteBlob(
		ctx,
		b.client.ContentStore(),
		fmt.Sprintf("glassdock-commit-config-%s", newConfigDescriptor.Digest.Encoded()),
		bytes.NewReader(newConfigData),
		newConfigDescriptor,
	); err != nil {
		return api.ImageResponse{}, fmt.Errorf("store committed image configuration: %w", err)
	}

	manifest.MediaType = commitManifestMediaType(manifest.MediaType)
	manifest.Config = newConfigDescriptor
	manifest.Layers = append(append([]imagespec.Descriptor(nil), manifest.Layers...), layerDescriptor)
	manifestData, err := json.Marshal(manifest)
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("encode committed image manifest: %w", err)
	}
	manifestDescriptor := imagespec.Descriptor{
		MediaType: manifest.MediaType,
		Digest:    digest.FromBytes(manifestData),
		Size:      int64(len(manifestData)),
	}
	if err := content.WriteBlob(
		ctx,
		b.client.ContentStore(),
		fmt.Sprintf("glassdock-commit-manifest-%s", manifestDescriptor.Digest.Encoded()),
		bytes.NewReader(manifestData),
		manifestDescriptor,
	); err != nil {
		return api.ImageResponse{}, fmt.Errorf("store committed image manifest: %w", err)
	}

	name := commitImageName(request, newConfigDescriptor.Digest)
	created, err := b.client.ImageService().Create(ctx, containerimages.Image{
		Name:      name,
		Target:    manifestDescriptor,
		CreatedAt: now,
		UpdatedAt: now,
	})
	if err != nil {
		if !errdefs.IsAlreadyExists(err) {
			return api.ImageResponse{}, err
		}
		created, err = b.client.ImageService().Update(ctx, containerimages.Image{
			Name:      name,
			Target:    manifestDescriptor,
			UpdatedAt: now,
		}, "target", "updated_at")
		if err != nil {
			return api.ImageResponse{}, err
		}
	}
	return api.ImageResponse{Name: created.Name, Digest: newConfigDescriptor.Digest.String()}, nil
}

func pauseCommitTask(ctx context.Context, container containerd.Container, shouldPause bool) (func(), error) {
	if !shouldPause {
		return func() {}, nil
	}
	task, err := container.Task(ctx, nil)
	if err != nil {
		if errdefs.IsNotFound(err) {
			return func() {}, nil
		}
		return nil, err
	}
	status, err := task.Status(ctx)
	if err != nil {
		return nil, err
	}
	if status.Status != containerd.Running {
		return func() {}, nil
	}
	if err := task.Pause(ctx); err != nil {
		return nil, err
	}
	return func() { _ = task.Resume(context.WithoutCancel(ctx)) }, nil
}

func commitLayerMediaType(manifest imagespec.Manifest) string {
	if len(manifest.Layers) > 0 {
		switch manifest.Layers[0].MediaType {
		case containerimages.MediaTypeDockerSchema2Layer,
			containerimages.MediaTypeDockerSchema2LayerGzip,
			containerimages.MediaTypeDockerSchema2LayerZstd:
			return containerimages.MediaTypeDockerSchema2Layer
		}
	}
	if strings.Contains(manifest.MediaType, "docker") {
		return containerimages.MediaTypeDockerSchema2Layer
	}
	return imagespec.MediaTypeImageLayer
}

func commitManifestMediaType(mediaType string) string {
	if mediaType == "" {
		return imagespec.MediaTypeImageManifest
	}
	return mediaType
}

func commitImageName(request api.ImageCommitRequest, digest digest.Digest) string {
	if request.Repository != "" {
		tag := request.Tag
		if tag == "" {
			tag = "latest"
		}
		return request.Repository + ":" + tag
	}
	return "glassdock/commit:" + digest.Encoded()
}

func applyCommitChanges(image *imagespec.Image, raw string) error {
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		instruction := strings.ToUpper(parts[0])
		argument := ""
		if len(parts) == 2 {
			argument = strings.TrimSpace(parts[1])
		}
		switch instruction {
		case "CMD":
			values, err := commitCommandValues(argument)
			if err != nil {
				return err
			}
			image.Config.Cmd = values
		case "ENTRYPOINT":
			values, err := commitCommandValues(argument)
			if err != nil {
				return err
			}
			image.Config.Entrypoint = values
		case "ENV":
			if err := applyCommitEnvironment(&image.Config.Env, argument); err != nil {
				return err
			}
		case "LABEL":
			if err := applyCommitLabels(&image.Config.Labels, argument); err != nil {
				return err
			}
		case "EXPOSE":
			if err := applyCommitExposedPorts(&image.Config.ExposedPorts, argument); err != nil {
				return err
			}
		case "VOLUME":
			values, err := commitStringValues(argument, "VOLUME")
			if err != nil {
				return err
			}
			if image.Config.Volumes == nil {
				image.Config.Volumes = map[string]struct{}{}
			}
			for _, value := range values {
				image.Config.Volumes[value] = struct{}{}
			}
		case "USER":
			if argument == "" {
				return errors.New("USER change requires a value")
			}
			image.Config.User = argument
		case "WORKDIR":
			if argument == "" {
				return errors.New("WORKDIR change requires a value")
			}
			image.Config.WorkingDir = argument
		case "STOPSIGNAL":
			if argument == "" {
				return errors.New("STOPSIGNAL change requires a value")
			}
			image.Config.StopSignal = argument
		default:
			return fmt.Errorf("commit change %q is not supported", instruction)
		}
	}
	return nil
}

func commitCommandValues(argument string) ([]string, error) {
	values, err := commitStringValues(argument, "command")
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(strings.TrimSpace(argument), "[") {
		return values, nil
	}
	return []string{"/bin/sh", "-c", argument}, nil
}

func commitStringValues(argument, instruction string) ([]string, error) {
	argument = strings.TrimSpace(argument)
	if argument == "" {
		return nil, fmt.Errorf("%s change requires a value", instruction)
	}
	if strings.HasPrefix(argument, "[") {
		var values []string
		if err := json.Unmarshal([]byte(argument), &values); err != nil || len(values) == 0 {
			return nil, fmt.Errorf("%s change must contain a non-empty JSON string array", instruction)
		}
		return values, nil
	}
	return strings.Fields(argument), nil
}

func applyCommitEnvironment(environment *[]string, argument string) error {
	assignments, err := commitAssignments(argument, "ENV")
	if err != nil {
		return err
	}
	for _, assignment := range assignments {
		key, _, _ := strings.Cut(assignment, "=")
		updated := false
		for index, current := range *environment {
			if currentKey, _, ok := strings.Cut(current, "="); ok && currentKey == key {
				(*environment)[index] = assignment
				updated = true
				break
			}
		}
		if !updated {
			*environment = append(*environment, assignment)
		}
	}
	return nil
}

func applyCommitLabels(labels *map[string]string, argument string) error {
	assignments, err := commitAssignments(argument, "LABEL")
	if err != nil {
		return err
	}
	if *labels == nil {
		*labels = map[string]string{}
	}
	for _, assignment := range assignments {
		key, value, _ := strings.Cut(assignment, "=")
		(*labels)[key] = value
	}
	return nil
}

func commitAssignments(argument, instruction string) ([]string, error) {
	fields := strings.Fields(strings.TrimSpace(argument))
	if len(fields) == 0 {
		return nil, fmt.Errorf("%s change requires a value", instruction)
	}
	assignments := make([]string, 0, len(fields))
	if !strings.Contains(fields[0], "=") {
		if len(fields) < 2 {
			return nil, fmt.Errorf("%s change requires KEY=VALUE", instruction)
		}
		assignments = append(assignments, fields[0]+"="+strings.Join(fields[1:], " "))
		return assignments, nil
	}
	for _, field := range fields {
		key, _, ok := strings.Cut(field, "=")
		if !ok || key == "" {
			return nil, fmt.Errorf("%s change requires KEY=VALUE", instruction)
		}
		assignments = append(assignments, field)
	}
	return assignments, nil
}

func applyCommitExposedPorts(ports *map[string]struct{}, argument string) error {
	values, err := commitStringValues(argument, "EXPOSE")
	if err != nil {
		return err
	}
	if *ports == nil {
		*ports = map[string]struct{}{}
	}
	for _, value := range values {
		(*ports)[value] = struct{}{}
	}
	return nil
}
