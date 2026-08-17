package backend

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const (
	maxBuildContextBytes = 8 * 1024 * 1024
	maxDockerfileBytes   = 1 * 1024 * 1024
)

type buildPlan struct {
	base    string
	changes []string
	runs    []string
}

// Build executes the Dockerfile instructions that can be represented by the
// guest containerd runtime. The build context is applied to a temporary
// container root, RUN instructions execute through the guest exec path, and
// the final root is committed as a normal containerd image.
func (b *Backend) Build(ctx context.Context, request api.ImageBuildRequest) (api.ImageResponse, error) {
	if len(request.Context) == 0 {
		return api.ImageResponse{}, errors.New("build context is empty")
	}
	if len(request.Context) > maxBuildContextBytes {
		return api.ImageResponse{}, fmt.Errorf("build context exceeds %d bytes", maxBuildContextBytes)
	}
	dockerfile := request.Dockerfile
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}
	dockerfileData, err := readBuildFile(request.Context, dockerfile)
	if err != nil {
		return api.ImageResponse{}, err
	}
	plan, err := parseBuildDockerfile(dockerfileData)
	if err != nil {
		return api.ImageResponse{}, err
	}
	if plan.base == "" {
		return api.ImageResponse{}, errors.New("Dockerfile does not contain a FROM instruction")
	}

	base, err := b.Pull(ctx, api.ImagePullRequest{
		Reference:   plan.base,
		Snapshotter: "overlayfs",
	})
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("pull build base image: %w", err)
	}

	id := fmt.Sprintf("glassdock-build-%d", time.Now().UnixNano())
	keepAlive := []string{"/bin/sh", "-c", "while :; do sleep 3600; done"}
	if _, err := b.Create(ctx, api.ContainerCreateRequest{
		ID:    id,
		Image: base.Name,
		Cmd:   &keepAlive,
	}); err != nil {
		return api.ImageResponse{}, fmt.Errorf("create build container: %w", err)
	}
	defer func() {
		_ = b.Delete(context.Background(), api.ContainerDeleteRequest{ID: id, Force: true})
	}()

	contextArchive, err := filterBuildContext(request.Context, dockerfile)
	if err != nil {
		return api.ImageResponse{}, err
	}
	if len(contextArchive) > 0 {
		if err := b.PutArchive(ctx, api.ContainerArchivePutRequest{
			ID: id, Path: "/", Data: contextArchive,
		}); err != nil {
			return api.ImageResponse{}, fmt.Errorf("apply build context: %w", err)
		}
	}

	if len(plan.runs) > 0 {
		if _, err := b.Start(ctx, api.ContainerStartRequest{ID: id}); err != nil {
			return api.ImageResponse{}, fmt.Errorf("start build container: %w", err)
		}
		for index, command := range plan.runs {
			exitCode, err := b.Exec(ctx, api.ContainerExecRequest{
				ID:     id,
				ExecID: fmt.Sprintf("%s-run-%d", id, index),
				Args:   []string{"/bin/sh", "-c", command},
			}, func(string, []byte) error { return nil })
			if err != nil {
				return api.ImageResponse{}, fmt.Errorf("run Dockerfile command %q: %w", command, err)
			}
			if exitCode != 0 {
				return api.ImageResponse{}, fmt.Errorf("Dockerfile command %q exited with code %d", command, exitCode)
			}
		}
		_ = b.Kill(ctx, id, 15)
		_, _, _ = b.Wait(ctx, id)
	}

	targets := append([]string(nil), request.Tags...)
	if len(targets) == 0 {
		targets = []string{"glassdock/build:latest"}
	}
	repository, tag := splitBuildTag(targets[0])
	image, err := b.CommitImage(ctx, api.ImageCommitRequest{
		Container:  id,
		Repository: repository,
		Tag:        tag,
		Changes:    strings.Join(plan.changes, "\n"),
		Comment:    "glassdock build",
	})
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("commit built image: %w", err)
	}
	for _, target := range targets[1:] {
		if _, err := b.TagImage(ctx, api.ImageTagRequest{Source: image.Name, Target: target}); err != nil {
			return api.ImageResponse{}, fmt.Errorf("tag built image %q: %w", target, err)
		}
	}
	return image, nil
}

func readBuildFile(contextData []byte, name string) ([]byte, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	expected := cleanBuildPath(name)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read build context: %w", err)
		}
		if cleanBuildPath(header.Name) != expected {
			continue
		}
		if header.Size < 0 || header.Size > maxDockerfileBytes {
			return nil, errors.New("Dockerfile is too large")
		}
		data, err := io.ReadAll(io.LimitReader(reader, maxDockerfileBytes+1))
		if err != nil {
			return nil, fmt.Errorf("read Dockerfile: %w", err)
		}
		if int64(len(data)) > maxDockerfileBytes {
			return nil, errors.New("Dockerfile is too large")
		}
		return data, nil
	}
	return nil, fmt.Errorf("Dockerfile %q is missing from the build context", name)
}

func parseBuildDockerfile(data []byte) (buildPlan, error) {
	var plan buildPlan
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 1024), maxDockerfileBytes)
	var pending string
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasSuffix(line, "\\") {
			pending += strings.TrimSpace(strings.TrimSuffix(line, "\\")) + " "
			continue
		}
		line = strings.TrimSpace(pending + line)
		pending = ""
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		instruction := strings.ToUpper(parts[0])
		argument := ""
		if len(parts) == 2 {
			argument = strings.TrimSpace(parts[1])
		}
		switch instruction {
		case "FROM":
			if plan.base != "" {
				return buildPlan{}, errors.New("multiple FROM stages are not supported")
			}
			fields := strings.Fields(argument)
			if len(fields) == 0 {
				return buildPlan{}, errors.New("FROM requires an image")
			}
			if strings.HasPrefix(fields[0], "--platform=") {
				fields = fields[1:]
			}
			if len(fields) == 0 {
				return buildPlan{}, errors.New("FROM requires an image")
			}
			plan.base = fields[0]
		case "RUN":
			if argument == "" {
				return buildPlan{}, errors.New("RUN requires a command")
			}
			plan.runs = append(plan.runs, argument)
		case "CMD", "ENTRYPOINT", "ENV", "LABEL", "EXPOSE", "VOLUME", "USER", "WORKDIR", "STOPSIGNAL":
			if argument == "" {
				return buildPlan{}, fmt.Errorf("%s requires a value", instruction)
			}
			plan.changes = append(plan.changes, instruction+" "+argument)
		case "COPY", "ADD", "ARG", "SHELL":
			// COPY and ADD are represented by the filtered build context.
			// ARG and SHELL affect Dockerfile parsing but not this image config.
		default:
			return buildPlan{}, fmt.Errorf("Dockerfile instruction %q is not supported", instruction)
		}
	}
	if err := scanner.Err(); err != nil {
		return buildPlan{}, fmt.Errorf("read Dockerfile: %w", err)
	}
	if pending != "" {
		return buildPlan{}, errors.New("Dockerfile ends with a continuation line")
	}
	return plan, nil
}

func filterBuildContext(contextData []byte, dockerfile string) ([]byte, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	expected := cleanBuildPath(dockerfile)
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	defer writer.Close()
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read build context: %w", err)
		}
		if cleanBuildPath(header.Name) == expected || cleanBuildPath(header.Name) == ".dockerignore" {
			continue
		}
		copyHeader := *header
		if err := writer.WriteHeader(&copyHeader); err != nil {
			return nil, fmt.Errorf("write build context: %w", err)
		}
		if header.Size > 0 {
			if _, err := io.CopyN(writer, reader, header.Size); err != nil {
				return nil, fmt.Errorf("copy build context: %w", err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("close build context: %w", err)
	}
	return output.Bytes(), nil
}

func buildTarReader(data []byte) (*tar.Reader, func(), error) {
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		gzipReader, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, func() {}, fmt.Errorf("open compressed build context: %w", err)
		}
		decompressed, err := io.ReadAll(io.LimitReader(gzipReader, maxBuildContextBytes+1))
		closeErr := gzipReader.Close()
		if err != nil {
			return nil, func() {}, fmt.Errorf("read compressed build context: %w", err)
		}
		if closeErr != nil {
			return nil, func() {}, fmt.Errorf("close compressed build context: %w", closeErr)
		}
		if len(decompressed) > maxBuildContextBytes {
			return nil, func() {}, fmt.Errorf("compressed build context exceeds %d bytes", maxBuildContextBytes)
		}
		return tar.NewReader(bytes.NewReader(decompressed)), func() {}, nil
	}
	return tar.NewReader(bytes.NewReader(data)), func() {}, nil
}

func cleanBuildPath(name string) string {
	name = strings.TrimPrefix(name, "./")
	cleaned := path.Clean(name)
	if cleaned == "." {
		return ""
	}
	return cleaned
}

func splitBuildTag(target string) (string, string) {
	target = strings.TrimSpace(target)
	if target == "" {
		return "glassdock/build", "latest"
	}
	lastSlash := strings.LastIndex(target, "/")
	lastColon := strings.LastIndex(target, ":")
	if lastColon > lastSlash && lastColon < len(target)-1 {
		return target[:lastColon], target[lastColon+1:]
	}
	return target, "latest"
}
