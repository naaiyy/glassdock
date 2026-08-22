package backend

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	cgroup1stats "github.com/containerd/cgroups/v3/cgroup1/stats"
	cgroup2stats "github.com/containerd/cgroups/v3/cgroup2/stats"
	runcoptions "github.com/containerd/containerd/api/types/runc/options"
	containerd "github.com/containerd/containerd/v2/client"
	containerrecords "github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/core/content"
	containerimages "github.com/containerd/containerd/v2/core/images"
	containerarchive "github.com/containerd/containerd/v2/core/images/archive"
	containermount "github.com/containerd/containerd/v2/core/mount"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/core/snapshots"
	rootfsarchive "github.com/containerd/containerd/v2/pkg/archive"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	"github.com/containerd/platforms"
	"github.com/containerd/typeurl/v2"
	registryreference "github.com/distribution/reference"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/opencontainers/runtime-spec/specs-go"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const runtimeMetadataLabel = "io.glassdock.runtime-metadata"
const maxConcurrentTaskCreations = 1
const execCleanupAttempts = 5
const execCleanupAttemptTimeout = 2 * time.Second
const networkCleanupAttempts = 5
const daemonLostExitCode uint32 = 255

func encodeRuntimeMetadata(metadata api.ContainerMetadata) (string, error) {
	data, err := json.Marshal(metadata)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func decodeRuntimeMetadata(labels map[string]string) api.ContainerMetadata {
	var metadata api.ContainerMetadata
	if value := labels[runtimeMetadataLabel]; value != "" {
		_ = json.Unmarshal([]byte(value), &metadata)
	}
	return metadata
}

type Backend struct {
	client        *containerd.Client
	namespace     string
	snapshotter   string
	runtime       string
	runtimeBinary string
	logsDir       string
	logCaptures   sync.Map
	containers    sync.Map
	networks      sync.Map // map[string]*networkPreparation
	createMu      sync.Mutex
	metadataMu    sync.Mutex
	statsMu       sync.Mutex
	lastStats     map[string]api.ContainerStatsResponse
	healthMu      sync.Mutex
	healthStops   map[string]chan struct{}
	execMu        sync.Mutex
	execProcesses map[string]containerd.Process
	network       *NetworkManager
	taskCreates   chan struct{}
	cleanups      orderedCleanupBarrier
	bindMount     bindMountConfiguration
}

type bindMountConfiguration struct {
	hostSource         string
	guestRoot          string
	excludedHostSource string
}

func (b *Backend) ConfigureBindMount(hostSource, guestRoot, excludedHostSource string) {
	b.bindMount = bindMountConfiguration{
		hostSource:         filepath.Clean(hostSource),
		guestRoot:          filepath.Clean(guestRoot),
		excludedHostSource: filepath.Clean(excludedHostSource),
	}
}

func pathContains(parent, child string) bool {
	relative, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(child))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func resolveBindSource(source string, configuration bindMountConfiguration) (string, error) {
	cleanSource := filepath.Clean(source)
	if pathContains(cleanSource, configuration.excludedHostSource) ||
		pathContains(configuration.excludedHostSource, cleanSource) {
		return "", fmt.Errorf("bind source %q overlaps excluded engine state %q", source, configuration.excludedHostSource)
	}
	relative, err := filepath.Rel(configuration.hostSource, cleanSource)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("bind source %q is outside host bind source %q", source, configuration.hostSource)
	}
	resolvedRoot, err := filepath.EvalSymlinks(configuration.guestRoot)
	if err != nil {
		return "", fmt.Errorf("resolve guest bind root %q: %w", configuration.guestRoot, err)
	}
	guestSource := filepath.Join(resolvedRoot, relative)
	resolvedSource, err := filepath.EvalSymlinks(guestSource)
	if err != nil {
		return "", fmt.Errorf("resolve guest bind source %q: %w", guestSource, err)
	}
	resolvedRelative, err := filepath.Rel(resolvedRoot, resolvedSource)
	if err != nil || resolvedRelative == ".." || strings.HasPrefix(resolvedRelative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("bind source %q escapes guest bind root %q", source, configuration.guestRoot)
	}
	resolvedHostSource := filepath.Join(configuration.hostSource, resolvedRelative)
	if pathContains(resolvedHostSource, configuration.excludedHostSource) ||
		pathContains(configuration.excludedHostSource, resolvedHostSource) {
		return "", fmt.Errorf("bind source %q resolves into excluded engine state %q", source, configuration.excludedHostSource)
	}
	return resolvedSource, nil
}

type orderedCleanupBarrier struct {
	mu   sync.Mutex
	tail *cleanupResult
}

type cleanupResult struct {
	done chan struct{}
	err  error
}

// networkPreparation records private network setup started while a container
// is being created. The namespace is not joined and no publication rules are
// installed until Start; this only overlaps expensive netlink work with
// container metadata and snapshot setup.
type networkPreparation struct {
	done chan struct{}
	err  error
}

func (b *orderedCleanupBarrier) enqueue(cleanup func() error) {
	b.mu.Lock()
	prior := b.tail
	result := &cleanupResult{done: make(chan struct{})}
	b.tail = result
	b.mu.Unlock()
	go func() {
		if prior != nil {
			<-prior.done
		}
		for attempt := 0; attempt < networkCleanupAttempts; attempt++ {
			result.err = cleanup()
			if result.err == nil {
				break
			}
			if attempt+1 < networkCleanupAttempts {
				time.Sleep(50 * time.Millisecond)
			}
		}
		close(result.done)
	}()
}

func (b *orderedCleanupBarrier) wait(ctx context.Context) error {
	b.mu.Lock()
	tail := b.tail
	b.mu.Unlock()
	if tail == nil {
		return nil
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-tail.done:
		if tail.err != nil {
			b.mu.Lock()
			if b.tail == tail {
				b.tail = nil
			}
			b.mu.Unlock()
		}
		return tail.err
	}
}

type containerRecord struct {
	container     containerd.Container
	snapshotter   string
	snapshotKey   string
	mu            sync.Mutex
	task          containerd.Task
	taskReaped    bool
	taskReaping   chan struct{}
	stdinWriter   io.WriteCloser
	spec          *specs.Spec
	persistedExit bool
	persistedCode uint32
}

func (r *containerRecord) setTask(task containerd.Task) {
	r.mu.Lock()
	r.task = task
	r.taskReaped = false
	r.taskReaping = nil
	r.mu.Unlock()
}

func (r *containerRecord) setStdinWriter(writer io.WriteCloser) {
	r.mu.Lock()
	r.stdinWriter = writer
	r.mu.Unlock()
}

func (r *containerRecord) getStdinWriter() io.WriteCloser {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.stdinWriter
}

func (r *containerRecord) taskState() (containerd.Task, bool, <-chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.task, r.taskReaped, r.taskReaping
}

func (r *containerRecord) beginTaskReap() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.taskReaped || r.taskReaping != nil {
		return false
	}
	r.taskReaping = make(chan struct{})
	return true
}

func (r *containerRecord) finishTaskReap(reaped bool) {
	r.mu.Lock()
	if reaped {
		r.taskReaped = true
		r.task = nil
	}
	if r.taskReaping != nil {
		close(r.taskReaping)
		r.taskReaping = nil
	}
	r.mu.Unlock()
}

func (r *containerRecord) cachedSpec() *specs.Spec {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spec
}

func (r *containerRecord) setSpec(spec *specs.Spec) {
	r.mu.Lock()
	r.spec = spec
	r.mu.Unlock()
}

func (r *containerRecord) hasPersistedExit() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persistedExit
}

func (r *containerRecord) persistedExitResult() (uint32, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persistedCode, r.persistedExit
}

func (r *containerRecord) setPersistedExit(value bool, code uint32) {
	r.mu.Lock()
	r.persistedExit = value
	r.persistedCode = code
	r.mu.Unlock()
}

func New(address, namespace, snapshotter, runtimeName, runtimeBinary string) (*Backend, error) {
	client, err := containerd.New(address)
	if err != nil {
		return nil, err
	}
	return &Backend{
		client: client, namespace: namespace, snapshotter: snapshotter,
		runtime: runtimeName, runtimeBinary: runtimeBinary,
		logsDir: "/var/lib/containerd/io.glassdock.logs",
		network: NewNetworkManager(commandRunner{}), taskCreates: make(chan struct{}, maxConcurrentTaskCreations),
		healthStops: make(map[string]chan struct{}),
	}, nil
}

func (b *Backend) beginNetworkPreparation(id string) *networkPreparation {
	preparation := &networkPreparation{done: make(chan struct{})}
	actual, loaded := b.networks.LoadOrStore(id, preparation)
	if loaded {
		return actual.(*networkPreparation)
	}
	go func() {
		_, preparation.err = b.network.Create(id)
		close(preparation.done)
	}()
	return preparation
}

func (b *Backend) waitNetworkPreparation(ctx context.Context, id string) error {
	value, ok := b.networks.Load(id)
	if !ok {
		return nil
	}
	preparation := value.(*networkPreparation)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-preparation.done:
		return preparation.err
	}
}

func (b *Backend) Close() error             { return b.client.Close() }
func (b *Backend) InitializeNetwork() error { return b.network.Initialize() }

func (b *Backend) Networks(ctx context.Context) ([]api.NetworkResource, error) {
	if err := b.network.Initialize(); err != nil {
		return nil, err
	}
	return b.network.ListNetworks(), nil
}

func (b *Backend) Network(ctx context.Context, id string) (api.NetworkResource, error) {
	if err := b.network.Initialize(); err != nil {
		return api.NetworkResource{}, err
	}
	return b.network.InspectNetwork(id)
}

func (b *Backend) CreateNetwork(ctx context.Context, request api.NetworkCreateRequest) (api.NetworkResource, error) {
	return b.network.CreateNetwork(request)
}

func (b *Backend) DeleteNetwork(ctx context.Context, id string) error {
	return b.network.DeleteNetwork(id)
}

func (b *Backend) PruneNetworks(ctx context.Context, request api.NetworkPruneRequest) (api.NetworkPruneResponse, error) {
	return b.network.PruneNetworks(request.Filters), nil
}

func (b *Backend) ConnectNetwork(ctx context.Context, request api.NetworkConnectRequest) (api.NetworkResource, error) {
	resource, err := b.network.ConnectNetwork(request)
	if err != nil {
		return api.NetworkResource{}, err
	}
	if err := b.syncNetworkFiles(ctx, request.ContainerID); err != nil {
		return api.NetworkResource{}, err
	}
	return resource, nil
}

func (b *Backend) DisconnectNetwork(ctx context.Context, request api.NetworkDisconnectRequest) (api.NetworkResource, error) {
	resource, err := b.network.DisconnectNetwork(request)
	if err != nil {
		return api.NetworkResource{}, err
	}
	if err := b.syncNetworkFiles(ctx, request.ContainerID); err != nil {
		return api.NetworkResource{}, err
	}
	return resource, nil
}

func (b *Backend) syncNetworkFiles(ctx context.Context, id string) error {
	hosts, nameservers, err := b.network.HostsFile(id)
	if err != nil {
		return err
	}
	root, cleanup, err := b.mountContainerRoot(ctx, id, "glassdock-network-")
	if err != nil {
		return err
	}
	defer cleanup()
	etc := filepath.Join(root, "etc")
	if err := os.MkdirAll(etc, 0o755); err != nil {
		return err
	}
	if err := writeManagedNetworkFile(filepath.Join(etc, "hosts"), hosts, "hosts"); err != nil {
		return err
	}
	if len(nameservers) != 0 {
		var resolver strings.Builder
		resolver.WriteString("# glassdock managed resolv.conf begin\n")
		for _, nameserver := range nameservers {
			resolver.WriteString("nameserver ")
			resolver.WriteString(nameserver)
			resolver.WriteByte('\n')
		}
		resolver.WriteString("# glassdock managed resolv.conf end\n")
		if err := writeManagedNetworkFile(filepath.Join(etc, "resolv.conf"), resolver.String(), "resolv.conf"); err != nil {
			return err
		}
	}
	return nil
}

func writeManagedNetworkFile(path, managed, kind string) error {
	begin := "# glassdock managed " + kind + " begin"
	end := "# glassdock managed " + kind + " end"
	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(existing), "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	inside := false
	for _, line := range lines {
		if line == begin {
			inside = true
			continue
		}
		if inside && line == end {
			inside = false
			continue
		}
		if !inside {
			filtered = append(filtered, line)
		}
	}
	for len(filtered) > 0 && filtered[len(filtered)-1] == "" {
		filtered = filtered[:len(filtered)-1]
	}
	if managed != "" {
		filtered = append(filtered, strings.TrimSuffix(managed, "\n"))
	}
	content := strings.Join(filtered, "\n") + "\n"
	if info, statErr := os.Lstat(path); statErr == nil && info.Mode()&os.ModeSymlink != 0 {
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("replace %s symlink: %w", kind, err)
		}
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

func (b *Backend) acquireTaskCreation(ctx context.Context) error {
	select {
	case b.taskCreates <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (b *Backend) releaseTaskCreation() { <-b.taskCreates }

func (b *Backend) ctx(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, b.namespace)
}

func (b *Backend) Version(ctx context.Context) (string, error) {
	v, err := b.client.Version(b.ctx(ctx))
	if err != nil {
		return "", err
	}
	return v.Version, nil
}

func (b *Backend) Push(ctx context.Context, request api.ImagePushRequest) (api.ImageResponse, error) {
	if request.Source == "" || request.Target == "" {
		return api.ImageResponse{}, errors.New("source and target image references are required")
	}
	ctx = b.ctx(ctx)
	image, err := b.Image(ctx, request.Source)
	if err != nil {
		return api.ImageResponse{}, err
	}
	source, err := b.client.GetImage(ctx, image.References[0])
	if err != nil {
		return api.ImageResponse{}, err
	}
	resolverOptions := docker.ResolverOptions{}
	if request.Username != "" {
		resolverOptions.Credentials = func(_ string) (string, string, error) {
			return request.Username, request.Secret, nil
		}
	}
	pushOptions := []containerd.RemoteOpt{
		containerd.WithResolver(docker.NewResolver(resolverOptions)),
	}
	if request.Platform != "" {
		pushOptions = append(pushOptions, containerd.WithPlatform(request.Platform))
	}
	if err := b.client.Push(ctx, request.Target, source.Target(), pushOptions...); err != nil {
		return api.ImageResponse{}, err
	}
	return api.ImageResponse{Name: request.Target, Digest: image.ID}, nil
}

func (b *Backend) ExportImages(ctx context.Context, request api.ImageExportRequest, stream StreamFunc) error {
	if len(request.References) == 0 {
		return errors.New("at least one image reference is required")
	}
	ctx = b.ctx(ctx)
	options := make([]containerarchive.ExportOpt, 0, len(request.References))
	for _, reference := range request.References {
		if _, err := b.Image(ctx, reference); err != nil {
			return err
		}
		record, err := b.client.ImageService().Get(ctx, reference)
		if err != nil {
			return err
		}
		// Pulls only download blobs for one platform, while an image target is
		// often a multi-platform index. Exporting that index verbatim yields an
		// archive whose sibling manifests are missing ("content digest not
		// found" on load), so pin the archive to this platform's manifest.
		desc := record.Target
		if containerimages.IsIndexType(desc.MediaType) {
			resolved, err := selectPlatformManifest(ctx, b.client.ContentStore(), desc)
			if err != nil {
				return err
			}
			desc = resolved
		}
		options = append(options, containerarchive.WithManifest(desc, reference))
	}
	return b.client.Export(ctx, streamWriter{stream: "stdout", send: stream}, options...)
}

// selectPlatformManifest resolves a multi-platform index to the single
// manifest matching the guest platform.
func selectPlatformManifest(
	ctx context.Context, store content.Store, indexDesc imagespec.Descriptor,
) (imagespec.Descriptor, error) {
	p, err := content.ReadBlob(ctx, store, indexDesc)
	if err != nil {
		return imagespec.Descriptor{}, err
	}
	var index imagespec.Index
	if err := json.Unmarshal(p, &index); err != nil {
		return imagespec.Descriptor{}, err
	}
	for _, m := range index.Manifests {
		// Exact OS/architecture match. containerd's platforms.Match treats
		// arm64 as compatible with arm/vN ("Only" semantics), which silently
		// selects foreign-platform manifests whose blobs were never pulled.
		if m.Platform == nil {
			continue
		}
		log.Printf("DEBUG-SELECT: child %s platform=%s", m.Digest, platforms.Format(*m.Platform))
		if m.Platform.OS == platforms.DefaultSpec().OS &&
			m.Platform.Architecture == platforms.DefaultSpec().Architecture {
			return m, nil
		}
	}
	return imagespec.Descriptor{}, fmt.Errorf(
		"index %s has no manifest for platform %s/%s",
		indexDesc.Digest, platforms.DefaultSpec().OS, platforms.DefaultSpec().Architecture,
	)
}

func (b *Backend) Pull(ctx context.Context, request api.ImagePullRequest) (api.ImageResponse, error) {
	if request.Reference == "" {
		return api.ImageResponse{}, errors.New("image reference is required")
	}
	if (request.Username == "") != (request.Secret == "") {
		return api.ImageResponse{}, errors.New("username and secret must be specified together")
	}
	snapshotter := request.Snapshotter
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	resolverOptions := docker.ResolverOptions{}
	if request.Username != "" {
		named, err := registryreference.ParseNormalizedNamed(request.Reference)
		if err != nil {
			return api.ImageResponse{}, fmt.Errorf("parse image reference: %w", err)
		}
		registryHost := registryreference.Domain(named)
		resolverOptions.Credentials = func(host string) (string, string, error) {
			if !sameRegistryHost(registryHost, host) {
				return "", "", nil
			}
			return request.Username, request.Secret, nil
		}
	}
	// containerd requires a fully qualified reference ("object required"
	// otherwise), so short names such as "alpine" must be normalized even
	// when no credentials are involved.
	qualified, err := registryreference.ParseDockerRef(request.Reference)
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("parse image reference: %w", err)
	}
	pullOptions := []containerd.RemoteOpt{
		containerd.WithResolver(docker.NewResolver(resolverOptions)),
		containerd.WithPullSnapshotter(snapshotter),
		containerd.WithPullUnpack,
	}
	if request.Platform != "" {
		pullOptions = append(pullOptions, containerd.WithPlatform(request.Platform))
	}
	image, err := b.client.Pull(b.ctx(ctx), qualified.String(), pullOptions...)
	if err != nil {
		return api.ImageResponse{}, err
	}
	return api.ImageResponse{Name: image.Name(), Digest: image.Target().Digest.String()}, nil
}

func sameRegistryHost(expected, challenged string) bool {
	if expected == challenged {
		return true
	}
	dockerHub := map[string]bool{"docker.io": true, "registry-1.docker.io": true, "index.docker.io": true}
	return dockerHub[expected] && dockerHub[challenged]
}

func (b *Backend) Images(ctx context.Context) ([]api.Image, error) {
	ctx = b.ctx(ctx)
	records, err := b.client.ListImages(ctx)
	if err != nil {
		return nil, err
	}
	grouped := make(map[string]*api.Image)
	for _, record := range records {
		config, err := record.Config(ctx)
		if err != nil {
			return nil, err
		}
		id := config.Digest.String()
		item := grouped[id]
		if item == nil {
			size, err := record.Size(ctx)
			if err != nil {
				return nil, err
			}
			spec, err := record.Spec(ctx)
			if err != nil {
				return nil, err
			}
			created := record.Metadata().CreatedAt
			if spec.Created != nil {
				created = *spec.Created
			}
			layers := make([]string, 0, len(spec.RootFS.DiffIDs))
			for _, layer := range spec.RootFS.DiffIDs {
				layers = append(layers, layer.String())
			}
			history := make([]api.ImageHistory, 0, len(spec.History))
			for _, entry := range spec.History {
				createdAt := created
				if entry.Created != nil {
					createdAt = *entry.Created
				}
				history = append(history, api.ImageHistory{
					Created: createdAt, CreatedBy: entry.CreatedBy,
					Comment: entry.Comment, Empty: entry.EmptyLayer,
				})
			}
			configLabels := spec.Config.Labels
			labels := record.Labels()
			if len(labels) == 0 {
				labels = configLabels
			}
			dockerExtras := readDockerImageConfig(ctx, record)
			item = &api.Image{
				ID: id, Digest: record.Target().Digest.String(), CreatedAt: created, Size: size,
				Labels: labels, Author: spec.Author, Architecture: spec.Architecture,
				OS: spec.OS, OSVersion: spec.OSVersion, Variant: spec.Variant,
				Config: api.ImageConfig{
					User: spec.Config.User, ExposedPorts: spec.Config.ExposedPorts,
					Env: spec.Config.Env, Entrypoint: spec.Config.Entrypoint,
					Cmd: spec.Config.Cmd, Volumes: spec.Config.Volumes,
					WorkingDir: spec.Config.WorkingDir, Labels: configLabels,
					StopSignal:  spec.Config.StopSignal,
					Healthcheck: dockerExtras.Healthcheck,
					OnBuild:     dockerExtras.OnBuild, Shell: dockerExtras.Shell,
				},
				RootFSLayers: layers, History: history,
			}
			grouped[id] = item
		}
		item.References = append(item.References, record.Name())
	}
	out := make([]api.Image, 0, len(grouped))
	for _, item := range grouped {
		sort.Strings(item.References)
		out = append(out, *item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

type dockerImageConfig struct {
	Healthcheck *api.HealthConfig
	OnBuild     []string
	Shell       []string
}

// OCI image configuration does not define Docker's Healthcheck, OnBuild, or
// Shell extensions. Read those fields from the original config blob when it
// is available, while keeping ordinary OCI images fully valid.
func readDockerImageConfig(ctx context.Context, image containerd.Image) dockerImageConfig {
	descriptor, err := image.Config(ctx)
	if err != nil {
		return dockerImageConfig{}
	}
	data, err := content.ReadBlob(ctx, image.ContentStore(), descriptor)
	if err != nil {
		return dockerImageConfig{}
	}
	var document struct {
		Config struct {
			Healthcheck *api.HealthConfig `json:"Healthcheck"`
			OnBuild     []string          `json:"OnBuild"`
			Shell       []string          `json:"Shell"`
		} `json:"config"`
	}
	if err := json.Unmarshal(data, &document); err != nil {
		return dockerImageConfig{}
	}
	return dockerImageConfig{
		Healthcheck: document.Config.Healthcheck,
		OnBuild:     document.Config.OnBuild,
		Shell:       document.Config.Shell,
	}
}

func (b *Backend) Image(ctx context.Context, reference string) (api.Image, error) {
	images, err := b.Images(ctx)
	if err != nil {
		return api.Image{}, err
	}
	var matches []api.Image
	for _, image := range images {
		matched := image.ID == reference || image.Digest == reference || strings.HasPrefix(image.ID, reference) || strings.HasPrefix(strings.TrimPrefix(image.ID, "sha256:"), strings.TrimPrefix(reference, "sha256:"))
		for _, name := range image.References {
			matched = matched || name == reference
		}
		if matched {
			matches = append(matches, image)
		}
	}
	if len(matches) != 1 {
		return api.Image{}, fmt.Errorf("image %s not found or ambiguous", reference)
	}
	return matches[0], nil
}

func (b *Backend) DeleteImage(ctx context.Context, request api.ImageDeleteRequest) (api.ImageDeleteResponse, error) {
	ctx = b.ctx(ctx)
	image, err := b.Image(ctx, request.Reference)
	if err != nil {
		return api.ImageDeleteResponse{}, err
	}
	if !request.Force {
		containers, err := b.client.Containers(ctx)
		if err != nil {
			return api.ImageDeleteResponse{}, err
		}
		for _, container := range containers {
			info, err := container.Info(ctx)
			if err == nil && contains(image.References, info.Image) {
				return api.ImageDeleteResponse{}, fmt.Errorf("image is used by container %s", container.ID())
			}
		}
	}
	name := request.Reference
	if !contains(image.References, name) {
		if len(image.References) != 1 {
			return api.ImageDeleteResponse{}, fmt.Errorf("image ID is referenced by multiple tags")
		}
		name = image.References[0]
	}
	if err := b.client.ImageService().Delete(ctx, name, containerimages.SynchronousDelete()); err != nil {
		return api.ImageDeleteResponse{}, err
	}
	result := api.ImageDeleteResponse{Untagged: []string{name}}
	remaining, err := b.Images(ctx)
	if err == nil {
		stillPresent := false
		for _, candidate := range remaining {
			stillPresent = stillPresent || candidate.ID == image.ID
		}
		if !stillPresent {
			result.Deleted = []string{image.ID}
			result.Reclaimed = image.Size
		}
	}
	return result, nil
}

func (b *Backend) PruneImages(ctx context.Context, request api.ImagePruneRequest) (api.ImageDeleteResponse, error) {
	images, err := b.Images(ctx)
	if err != nil {
		return api.ImageDeleteResponse{}, err
	}
	result := api.ImageDeleteResponse{}
	for _, image := range images {
		if !request.All && !isDanglingImage(image) {
			continue
		}
		if !matchesImagePruneFilters(image, request.Filters) {
			continue
		}
		for _, reference := range append([]string(nil), image.References...) {
			deleted, err := b.DeleteImage(ctx, api.ImageDeleteRequest{Reference: reference})
			if err != nil {
				if strings.Contains(err.Error(), "image is used by container") {
					continue
				}
				return result, fmt.Errorf("prune image %s: %w", reference, err)
			}
			result.Deleted = append(result.Deleted, deleted.Deleted...)
			result.Untagged = append(result.Untagged, deleted.Untagged...)
			result.Reclaimed += deleted.Reclaimed
		}
	}
	return result, nil
}

func matchesImagePruneFilters(image api.Image, filters map[string][]string) bool {
	for key, values := range filters {
		if len(values) == 0 {
			continue
		}
		matched := false
		for _, value := range values {
			switch key {
			case "dangling":
				want := value == "true" || value == "1"
				matched = want == isDanglingImage(image)
			case "label":
				parts := strings.SplitN(value, "=", 2)
				actual, exists := image.Labels[parts[0]]
				matched = exists && (len(parts) == 1 || actual == parts[1])
			case "until":
				cutoff, ok := parseImagePruneTime(value)
				matched = ok && image.CreatedAt.Before(cutoff)
			default:
				matched = false
			}
			if matched {
				break
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

func parseImagePruneTime(value string) (time.Time, bool) {
	if seconds, err := strconv.ParseInt(value, 10, 64); err == nil {
		return time.Unix(seconds, 0), true
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, true
		}
	}
	if duration, err := time.ParseDuration(value); err == nil {
		return time.Now().Add(-duration), true
	}
	return time.Time{}, false
}

func isDanglingImage(image api.Image) bool {
	if len(image.References) == 0 {
		return true
	}
	for _, reference := range image.References {
		if reference != "<none>:<none>" && !strings.HasPrefix(reference, "sha256:") && !strings.Contains(reference, "@sha256:") {
			return false
		}
	}
	return true
}

func (b *Backend) TagImage(ctx context.Context, request api.ImageTagRequest) (api.ImageResponse, error) {
	ctx = b.ctx(ctx)
	image, err := b.Image(ctx, request.Source)
	if err != nil {
		return api.ImageResponse{}, err
	}
	source, err := b.client.GetImage(ctx, image.References[0])
	if err != nil {
		return api.ImageResponse{}, err
	}
	created, err := b.client.ImageService().Create(ctx, containerimages.Image{Name: request.Target, Target: source.Target()})
	if err != nil {
		if !errdefs.IsAlreadyExists(err) {
			return api.ImageResponse{}, err
		}
		created, err = b.client.ImageService().Get(ctx, request.Target)
		if err != nil || created.Target.Digest != source.Target().Digest {
			return api.ImageResponse{}, fmt.Errorf("target image already exists")
		}
	}
	return api.ImageResponse{Name: created.Name, Digest: image.ID}, nil
}

func contains(items []string, value string) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

func (b *Backend) List(ctx context.Context) ([]api.Container, error) {
	containers, err := b.client.Containers(b.ctx(ctx))
	if err != nil {
		return nil, err
	}
	out := make([]api.Container, 0, len(containers))
	for _, container := range containers {
		item, err := b.inspect(ctx, container)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, nil
}

func (b *Backend) Inspect(ctx context.Context, id string) (api.Container, error) {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return api.Container{}, err
	}
	return b.inspect(ctx, container)
}

func (b *Backend) inspect(ctx context.Context, container containerd.Container) (api.Container, error) {
	ctx = b.ctx(ctx)
	info, err := container.Info(ctx)
	if err != nil {
		return api.Container{}, err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	result := api.Container{ID: container.ID(), Image: info.Image, Status: "created", CreatedAt: info.CreatedAt, Metadata: metadata}
	result.Health = metadata.Health
	result.SizeRw, result.SizeRootFs = b.containerUsage(ctx, info)
	task, err := container.Task(ctx, nil)
	if err != nil {
		applyPersistedLifecycle(&result, metadata)
		return result, nil
	}
	status, err := task.Status(ctx)
	if err != nil {
		if errdefs.IsNotFound(err) {
			applyPersistedLifecycle(&result, metadata)
			return result, nil
		}
		return api.Container{}, err
	}
	result.Status, result.PID = string(status.Status), task.Pid()
	if status.Status == containerd.Stopped {
		code := status.ExitStatus
		result.ExitCode = &code
	}
	result.Health = metadata.Health
	return result, nil
}

func (b *Backend) containerUsage(ctx context.Context, info containerrecords.Container) (int64, int64) {
	var writable int64
	if info.SnapshotKey != "" && info.Snapshotter != "" {
		if usage, err := b.client.SnapshotService(info.Snapshotter).Usage(ctx, info.SnapshotKey); err == nil {
			writable = usage.Size
		}
	}
	var rootFilesystem int64 = writable
	if image, err := b.client.GetImage(ctx, info.Image); err == nil {
		if size, sizeErr := image.Size(ctx); sizeErr == nil {
			rootFilesystem += size
		}
	}
	return writable, rootFilesystem
}

func applyPersistedLifecycle(result *api.Container, metadata api.ContainerMetadata) {
	if metadata.LifecycleState == "running" {
		result.Status = "exited"
		code := daemonLostExitCode
		result.ExitCode = &code
		return
	}
	if metadata.LifecycleState != "exited" || metadata.LastExitCode == nil {
		return
	}
	result.Status = "exited"
	code := *metadata.LastExitCode
	result.ExitCode = &code
}

func (b *Backend) Create(ctx context.Context, request api.ContainerCreateRequest) (api.Container, error) {
	if request.ID == "" || request.Image == "" {
		return api.Container{}, errors.New("id and image are required")
	}
	if err := b.cleanups.wait(ctx); err != nil {
		return api.Container{}, fmt.Errorf("wait for private network cleanup: %w", err)
	}
	var privateNetwork bool
	sharedNetworkPath := ""
	switch request.Network.Mode {
	case "host":
	case "", "private":
		privateNetwork = true
	case "none":
		// The runtime keeps the container in an isolated network namespace
		// without provisioning a guest bridge endpoint.
	case "path":
		if request.Network.Path == "" {
			return api.Container{}, errors.New("network.path is required for path mode")
		}
	case "container":
		return api.Container{}, errors.New("network.container mode requires a target container")
	default:
		if strings.HasPrefix(request.Network.Mode, "container:") {
			targetID := strings.TrimPrefix(request.Network.Mode, "container:")
			if targetID == "" {
				return api.Container{}, errors.New("network.container target is required")
			}
			target, err := b.client.LoadContainer(b.ctx(ctx), targetID)
			if err != nil {
				return api.Container{}, fmt.Errorf("network container %q not found: %w", targetID, err)
			}
			task, err := target.Task(b.ctx(ctx), nil)
			if err != nil {
				return api.Container{}, fmt.Errorf("network container %q is not running: %w", targetID, err)
			}
			status, err := task.Status(b.ctx(ctx))
			if err != nil || status.Status != containerd.Running {
				return api.Container{}, fmt.Errorf("network container %q is not running", targetID)
			}
			sharedNetworkPath = filepath.Join("/proc", strconv.FormatUint(uint64(task.Pid()), 10), "ns", "net")
		} else {
			return api.Container{}, fmt.Errorf("unsupported network mode %q", request.Network.Mode)
		}
	}
	var networkReady *networkPreparation
	keepNetwork := false
	if privateNetwork {
		networkReady = b.beginNetworkPreparation(request.ID)
		defer func() {
			if keepNetwork || networkReady == nil {
				return
			}
			<-networkReady.done
			if networkReady.err == nil {
				_ = b.network.Delete(request.ID)
			}
			b.networks.Delete(request.ID)
		}()
	}
	ctx = b.ctx(ctx)
	image, err := b.client.GetImage(ctx, request.Image)
	if err != nil {
		return api.Container{}, fmt.Errorf("image must already exist: %w", err)
	}
	effectiveHealthcheck := request.Healthcheck
	if effectiveHealthcheck == nil {
		effectiveHealthcheck = readDockerImageConfig(ctx, image).Healthcheck
	}
	snapshotter := request.Snapshotter
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	runtimeName := request.Runtime
	if runtimeName == "" {
		runtimeName = b.runtime
	}
	runtimeBinary := request.RuntimeBinary
	if runtimeBinary == "" {
		runtimeBinary = b.runtimeBinary
	}
	specOpts := []oci.SpecOpts{oci.WithImageConfig(image)}
	if request.Entrypoint != nil || request.Cmd != nil {
		args, err := resolveProcessArgs(ctx, image, request.Entrypoint, request.Cmd)
		if err != nil {
			return api.Container{}, err
		}
		if len(args) == 0 {
			return api.Container{}, errors.New("container command is empty")
		}
		specOpts = append(specOpts, oci.WithProcessArgs(args...))
	} else if len(request.Args) > 0 {
		specOpts = append(specOpts, oci.WithProcessArgs(request.Args...))
	}
	if len(request.Env) > 0 {
		specOpts = append(specOpts, oci.WithEnv(request.Env))
	}
	if request.Cwd != "" {
		specOpts = append(specOpts, oci.WithProcessCwd(request.Cwd))
	}
	if request.User != "" {
		specOpts = append(specOpts, oci.WithUser(request.User))
	}
	if request.Hostname != "" {
		specOpts = append(specOpts, oci.WithHostname(request.Hostname))
	}
	if request.ReadonlyRootfs {
		specOpts = append(specOpts, oci.WithRootFSReadonly())
	}
	if resourceOpt := initialResourceOpt(request.Resources); resourceOpt != nil {
		specOpts = append(specOpts, resourceOpt)
	}
	mounts, err := toOCIMounts(request.Mounts)
	if err != nil {
		return api.Container{}, err
	}
	for index := range mounts {
		if mounts[index].Type != "bind" {
			continue
		}
		if b.bindMount.hostSource == "" || b.bindMount.guestRoot == "" || b.bindMount.excludedHostSource == "" {
			return api.Container{}, errors.New("bind mount translation is not configured")
		}
		mounts[index].Source, err = resolveBindSource(mounts[index].Source, b.bindMount)
		if err != nil {
			return api.Container{}, err
		}
	}
	if len(mounts) > 0 {
		specOpts = append(specOpts, oci.WithMounts(mounts))
	}
	switch request.Network.Mode {
	case "host":
		specOpts = append(specOpts, oci.WithHostNamespace(specs.NetworkNamespace))
	case "", "private":
		networkPath := b.network.Path(request.ID)
		specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: networkPath}))
	case "path":
		specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: request.Network.Path}))
	case "none":
		// Leave the runtime's isolated network namespace without a bridge.
	default:
		if sharedNetworkPath != "" {
			specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: sharedNetworkPath}))
		}
	}
	b.createMu.Lock()
	defer b.createMu.Unlock()
	labels := make(map[string]string, len(request.Labels)+1)
	for key, value := range request.Labels {
		labels[key] = value
	}
	if request.AutoRemove {
		labels["com.glassdock.auto-remove"] = "true"
	}
	metadata := request.Metadata
	if metadata.Name == "" {
		metadata.Name = request.ID
	}
	if metadata.Args == nil {
		metadata.Args = request.Args
	}
	if metadata.Labels == nil {
		metadata.Labels = request.Labels
	}
	if request.Entrypoint != nil {
		metadata.Entrypoint = append([]string(nil), (*request.Entrypoint)...)
	}
	if request.Cmd != nil {
		metadata.Cmd = append([]string(nil), (*request.Cmd)...)
	}
	metadata.Env = append([]string(nil), request.Env...)
	metadata.Cwd = request.Cwd
	metadata.User = request.User
	metadata.Hostname = request.Hostname
	metadata.AutoRemove = metadata.AutoRemove || request.AutoRemove
	metadata.Mounts = append([]api.Mount(nil), request.Mounts...)
	metadata.ReadonlyRootfs = request.ReadonlyRootfs
	metadata.DNS = append([]string(nil), request.DNS...)
	metadata.DNSSearch = append([]string(nil), request.DNSSearch...)
	metadata.ExtraHosts = append([]string(nil), request.ExtraHosts...)
	metadata.Healthcheck = effectiveHealthcheck
	metadata.Resources = request.Resources
	if request.StopSignal != "" {
		metadata.StopSignal = request.StopSignal
	}
	if effectiveHealthcheck != nil && len(effectiveHealthcheck.Test) > 0 && effectiveHealthcheck.Test[0] != "NONE" {
		metadata.Health = &api.Health{Status: "starting"}
	}
	if metadata.RestartPolicy.Name == "" {
		metadata.RestartPolicy = request.RestartPolicy
	}
	if metadata.RestartPolicy.Name == "" {
		metadata.RestartPolicy.Name = "no"
	}
	metadata.NetworkMode = request.Network.Mode
	if privateNetwork {
		// Docker create stores network intent. The network namespace is
		// allocated when start realizes that intent.
		metadata.PublishedPorts = append([]api.PublishedPort(nil), request.PublishedPorts...)
	}
	encodedMetadata, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return api.Container{}, fmt.Errorf("encode runtime metadata: %w", err)
	}
	labels[runtimeMetadataLabel] = encodedMetadata
	snapshotCreated := false
	newSnapshot := containerd.WithNewSnapshot(request.ID, image)
	trackedSnapshot := func(ctx context.Context, client *containerd.Client, record *containerrecords.Container) error {
		if err := newSnapshot(ctx, client, record); err != nil {
			return err
		}
		snapshotCreated = true
		return nil
	}
	opts := []containerd.NewContainerOpts{containerd.WithImage(image), containerd.WithSnapshotter(snapshotter), trackedSnapshot, containerd.WithNewSpec(specOpts...), containerd.WithContainerLabels(labels)}
	if runtimeName != "" {
		var runtimeOptions any
		if runtimeBinary != "" {
			runtimeOptions = &runcoptions.Options{BinaryName: runtimeBinary}
		}
		opts = append(opts, containerd.WithRuntime(runtimeName, runtimeOptions))
	}
	container, err := b.client.NewContainer(ctx, request.ID, opts...)
	if err != nil {
		if snapshotCreated {
			_ = b.client.SnapshotService(snapshotter).Remove(ctx, request.ID)
		}
		return api.Container{}, err
	}
	record := &containerRecord{
		container: container, snapshotter: snapshotter, snapshotKey: request.ID,
	}
	b.containers.Store(request.ID, record)
	info, err := container.Info(ctx)
	if err != nil {
		return api.Container{}, err
	}
	keepNetwork = true
	b.network.SetContainerIdentity(request.ID, metadata.Name, request.Hostname)
	return api.Container{
		ID: container.ID(), Image: info.Image, Status: "created", CreatedAt: info.CreatedAt, Metadata: metadata,
		Health: metadata.Health,
	}, nil
}

func resolveProcessArgs(ctx context.Context, image containerd.Image, entrypoint, cmd *[]string) ([]string, error) {
	descriptor, err := image.Config(ctx)
	if err != nil {
		return nil, err
	}
	if !containerimages.IsConfigType(descriptor.MediaType) {
		return nil, fmt.Errorf("unknown image config media type %s", descriptor.MediaType)
	}
	data, err := content.ReadBlob(ctx, image.ContentStore(), descriptor)
	if err != nil {
		return nil, err
	}
	var imageConfig imagespec.Image
	if err := json.Unmarshal(data, &imageConfig); err != nil {
		return nil, err
	}
	return resolveImageProcessArgs(
		imageConfig.Config.Entrypoint, imageConfig.Config.Cmd, entrypoint, cmd,
	), nil
}

func resolveImageProcessArgs(imageEntrypoint, imageCmd []string, entrypoint, cmd *[]string) []string {
	resolvedEntrypoint := imageEntrypoint
	resolvedCmd := imageCmd
	if entrypoint != nil {
		resolvedEntrypoint = *entrypoint
	}
	if cmd != nil {
		resolvedCmd = *cmd
	}
	return append(append([]string(nil), resolvedEntrypoint...), resolvedCmd...)
}

func initialResourceOpt(request api.Resources) oci.SpecOpts {
	if request.Memory == 0 && request.MemorySwap == 0 && request.MemoryReservation == 0 &&
		request.NanoCPUs == 0 &&
		request.CPUShares == 0 && request.CPUPeriod == 0 && request.CPUQuota == 0 &&
		request.CPUSetCPUs == "" && request.CPUSetMems == "" && request.PidsLimit == 0 {
		return nil
	}
	return func(_ context.Context, _ oci.Client, _ *containerrecords.Container, spec *oci.Spec) error {
		if spec.Linux == nil {
			spec.Linux = &specs.Linux{}
		}
		if spec.Linux.Resources == nil {
			spec.Linux.Resources = &specs.LinuxResources{}
		}
		resources := spec.Linux.Resources
		if request.NanoCPUs != 0 || request.CPUShares != 0 || request.CPUPeriod != 0 || request.CPUQuota != 0 ||
			request.CPUSetCPUs != "" || request.CPUSetMems != "" {
			if resources.CPU == nil {
				resources.CPU = &specs.LinuxCPU{}
			}
			if request.CPUShares != 0 {
				value := uint64(request.CPUShares)
				resources.CPU.Shares = &value
			}
			if request.NanoCPUs != 0 && request.CPUQuota == 0 {
				period := uint64(100000)
				if request.CPUPeriod != 0 {
					period = uint64(request.CPUPeriod)
				}
				resources.CPU.Period = &period
				quota := nanoCPUQuota(request.NanoCPUs, period)
				resources.CPU.Quota = &quota
			}
			if request.CPUPeriod != 0 {
				value := uint64(request.CPUPeriod)
				resources.CPU.Period = &value
			}
			if request.CPUQuota != 0 {
				value := request.CPUQuota
				resources.CPU.Quota = &value
			}
			if request.CPUSetCPUs != "" {
				resources.CPU.Cpus = request.CPUSetCPUs
			}
			if request.CPUSetMems != "" {
				resources.CPU.Mems = request.CPUSetMems
			}
		}
		if request.Memory != 0 || request.MemorySwap != 0 || request.MemoryReservation != 0 {
			if resources.Memory == nil {
				resources.Memory = &specs.LinuxMemory{}
			}
			if request.Memory != 0 {
				value := request.Memory
				resources.Memory.Limit = &value
			}
			if request.MemorySwap != 0 {
				value := request.MemorySwap
				resources.Memory.Swap = &value
			}
			if request.MemoryReservation != 0 {
				value := request.MemoryReservation
				resources.Memory.Reservation = &value
			}
		}
		if request.PidsLimit != 0 {
			resources.Pids = &specs.LinuxPids{Limit: request.PidsLimit}
		}
		return nil
	}
}

func (b *Backend) persistRunningState(ctx context.Context, container containerd.Container, published []api.PublishedPort) error {
	return b.updateRuntimeMetadata(ctx, container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "running"
		metadata.LastExitCode = nil
		metadata.PublishedPorts = published
	})
}

func (b *Backend) updateRuntimeMetadata(ctx context.Context, container containerd.Container, update func(*api.ContainerMetadata)) error {
	b.metadataMu.Lock()
	defer b.metadataMu.Unlock()
	ctx = b.ctx(ctx)
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	update(&metadata)
	encoded, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return err
	}
	if info.Labels == nil {
		info.Labels = make(map[string]string)
	}
	info.Labels[runtimeMetadataLabel] = encoded
	return container.Update(ctx, func(_ context.Context, _ *containerd.Client, record *containerrecords.Container) error {
		record.Labels = info.Labels
		return nil
	})
}

func (b *Backend) prepareNetwork(id string, publishedPorts []api.PublishedPort) ([]api.PublishedPort, error) {
	if _, err := b.network.Create(id); err != nil {
		return nil, err
	}
	published, err := b.network.Publish(id, publishedPorts)
	if err != nil {
		_ = b.network.Delete(id)
		return nil, err
	}
	return published, nil
}

func (b *Backend) persistExitState(ctx context.Context, record *containerRecord, code uint32) error {
	err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "exited"
		metadata.LastExitCode = &code
	})
	if err == nil {
		record.setPersistedExit(true, code)
	}
	return err
}

func (b *Backend) clearExitState(ctx context.Context, record *containerRecord) error {
	if !record.hasPersistedExit() {
		return nil
	}
	err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = ""
		metadata.LastExitCode = nil
	})
	if err == nil {
		record.setPersistedExit(false, 0)
	}
	return err
}

func (b *Backend) UpdateContainerMetadata(ctx context.Context, request api.ContainerMetadataUpdateRequest) error {
	b.metadataMu.Lock()
	defer b.metadataMu.Unlock()
	ctx = b.ctx(ctx)
	container, err := b.client.LoadContainer(ctx, request.ID)
	if err != nil {
		return err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	if request.Name != "" {
		metadata.Name = request.Name
	}
	if request.PortBindings != nil {
		metadata.PortBindings = request.PortBindings
	}
	if request.RestartCount != nil {
		if *request.RestartCount < 0 {
			return errors.New("restart count must be non-negative")
		}
		metadata.RestartCount = *request.RestartCount
	}
	encoded, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return err
	}
	info.Labels[runtimeMetadataLabel] = encoded
	if err := container.Update(ctx, func(_ context.Context, _ *containerd.Client, record *containerrecords.Container) error {
		record.Labels = info.Labels
		return nil
	}); err != nil {
		return err
	}
	if request.Name != "" {
		b.network.SetContainerIdentity(request.ID, metadata.Name, "")
		if err := b.syncNetworkFiles(ctx, request.ID); err != nil {
			return err
		}
	}
	return nil
}

func (b *Backend) UpdateContainer(ctx context.Context, request api.ContainerUpdateRequest) ([]string, error) {
	if request.ID == "" {
		return nil, errors.New("container id is required")
	}
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(request.ID)
	if !ok {
		container, err := b.client.LoadContainer(ctx, request.ID)
		if err != nil {
			return nil, err
		}
		record, err = b.record(ctx, request.ID, container)
		if err != nil {
			return nil, err
		}
	}

	resources, hasResources := containerUpdateResources(request)
	if hasResources {
		task, _, _ := record.taskState()
		if task == nil {
			loadedTask, err := record.container.Task(ctx, nil)
			if err == nil {
				task = loadedTask
				record.setTask(task)
			} else if !errdefs.IsNotFound(err) {
				return nil, err
			}
		}
		if task != nil {
			status, err := task.Status(ctx)
			if err != nil && !errdefs.IsNotFound(err) {
				return nil, err
			}
			if err == nil && status.Status != containerd.Stopped {
				if err := task.Update(ctx, containerd.WithResources(resources)); err != nil {
					return nil, err
				}
			}
		}

		spec, err := record.container.Spec(ctx)
		if err != nil {
			return nil, err
		}
		if err := applyContainerUpdateToSpec(spec, request); err != nil {
			return nil, err
		}
		encoded, err := typeurl.MarshalAny(spec)
		if err != nil {
			return nil, err
		}
		if err := record.container.Update(ctx, func(
			_ context.Context, _ *containerd.Client, container *containerrecords.Container,
		) error {
			container.Spec = encoded
			return nil
		}); err != nil {
			return nil, err
		}
		record.setSpec(spec)
	}
	if request.RestartPolicy != nil {
		if err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
			metadata.RestartPolicy = *request.RestartPolicy
		}); err != nil {
			return nil, err
		}
	}
	if hasResources {
		if err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
			resources := metadata.Resources
			if request.NanoCPUs != nil {
				resources.NanoCPUs = *request.NanoCPUs
			}
			if request.Memory != nil {
				resources.Memory = *request.Memory
			}
			if request.MemorySwap != nil {
				resources.MemorySwap = *request.MemorySwap
			}
			if request.MemoryReservation != nil {
				resources.MemoryReservation = *request.MemoryReservation
			}
			if request.CPUShares != nil {
				resources.CPUShares = int64(*request.CPUShares)
			}
			if request.CPUPeriod != nil {
				resources.CPUPeriod = int64(*request.CPUPeriod)
			}
			if request.CPUQuota != nil {
				resources.CPUQuota = *request.CPUQuota
			}
			if request.CPUSetCPUs != nil {
				resources.CPUSetCPUs = *request.CPUSetCPUs
			}
			if request.CPUSetMems != nil {
				resources.CPUSetMems = *request.CPUSetMems
			}
			if request.PidsLimit != nil {
				resources.PidsLimit = *request.PidsLimit
			}
			metadata.Resources = resources
		}); err != nil {
			return nil, err
		}
	}
	return []string{}, nil
}

func containerUpdateResources(request api.ContainerUpdateRequest) (*specs.LinuxResources, bool) {
	resources := &specs.LinuxResources{}
	hasResources := false

	if request.NanoCPUs != nil || request.CPUShares != nil || request.CPUPeriod != nil || request.CPUQuota != nil ||
		request.CPUSetCPUs != nil || request.CPUSetMems != nil {
		cpu := &specs.LinuxCPU{}
		if request.NanoCPUs != nil && request.CPUQuota == nil {
			period := uint64(100000)
			if request.CPUPeriod != nil {
				period = *request.CPUPeriod
			}
			cpu.Period = &period
			quota := nanoCPUQuota(*request.NanoCPUs, period)
			cpu.Quota = &quota
		}
		if request.CPUShares != nil {
			value := *request.CPUShares
			cpu.Shares = &value
		}
		if request.CPUPeriod != nil {
			value := *request.CPUPeriod
			cpu.Period = &value
		}
		if request.CPUQuota != nil {
			value := *request.CPUQuota
			cpu.Quota = &value
		}
		if request.CPUSetCPUs != nil {
			cpu.Cpus = *request.CPUSetCPUs
		}
		if request.CPUSetMems != nil {
			cpu.Mems = *request.CPUSetMems
		}
		resources.CPU = cpu
		hasResources = true
	}

	if request.Memory != nil || request.MemorySwap != nil || request.MemoryReservation != nil {
		memory := &specs.LinuxMemory{}
		if request.Memory != nil {
			value := *request.Memory
			memory.Limit = &value
		}
		if request.MemorySwap != nil {
			value := *request.MemorySwap
			memory.Swap = &value
		}
		if request.MemoryReservation != nil {
			value := *request.MemoryReservation
			memory.Reservation = &value
		}
		resources.Memory = memory
		hasResources = true
	}

	if request.PidsLimit != nil {
		resources.Pids = &specs.LinuxPids{Limit: *request.PidsLimit}
		hasResources = true
	}
	return resources, hasResources
}

func applyContainerUpdateToSpec(spec *specs.Spec, request api.ContainerUpdateRequest) error {
	if spec.Linux == nil {
		return errors.New("container has no Linux resource specification")
	}
	if spec.Linux.Resources == nil {
		spec.Linux.Resources = &specs.LinuxResources{}
	}
	resources := spec.Linux.Resources

	if request.NanoCPUs != nil || request.CPUShares != nil || request.CPUPeriod != nil || request.CPUQuota != nil ||
		request.CPUSetCPUs != nil || request.CPUSetMems != nil {
		if resources.CPU == nil {
			resources.CPU = &specs.LinuxCPU{}
		}
		if request.CPUShares != nil {
			value := *request.CPUShares
			resources.CPU.Shares = &value
		}
		if request.NanoCPUs != nil && request.CPUQuota == nil {
			period := uint64(100000)
			if resources.CPU.Period != nil {
				period = *resources.CPU.Period
			} else if request.CPUPeriod != nil {
				period = *request.CPUPeriod
				resources.CPU.Period = &period
			}
			quota := nanoCPUQuota(*request.NanoCPUs, period)
			resources.CPU.Quota = &quota
		}
		if request.CPUPeriod != nil {
			value := *request.CPUPeriod
			resources.CPU.Period = &value
		}
		if request.CPUQuota != nil {
			value := *request.CPUQuota
			resources.CPU.Quota = &value
		}
		if request.CPUSetCPUs != nil {
			resources.CPU.Cpus = *request.CPUSetCPUs
		}
		if request.CPUSetMems != nil {
			resources.CPU.Mems = *request.CPUSetMems
		}
	}

	if request.Memory != nil || request.MemorySwap != nil || request.MemoryReservation != nil {
		if resources.Memory == nil {
			resources.Memory = &specs.LinuxMemory{}
		}
		if request.Memory != nil {
			value := *request.Memory
			resources.Memory.Limit = &value
		}
		if request.MemorySwap != nil {
			value := *request.MemorySwap
			resources.Memory.Swap = &value
		}
		if request.MemoryReservation != nil {
			value := *request.MemoryReservation
			resources.Memory.Reservation = &value
		}
	}

	if request.PidsLimit != nil {
		if resources.Pids == nil {
			resources.Pids = &specs.LinuxPids{}
		}
		resources.Pids.Limit = *request.PidsLimit
	}
	return nil
}

func nanoCPUQuota(nanoCPUs int64, period uint64) int64 {
	if nanoCPUs <= 0 || period == 0 {
		return 0
	}
	if nanoCPUs > math.MaxInt64/int64(period) {
		return math.MaxInt64
	}
	return nanoCPUs * int64(period) / 1_000_000_000
}

func toOCIMounts(input []api.Mount) ([]specs.Mount, error) {
	result := make([]specs.Mount, 0, len(input))
	for _, mount := range input {
		if mount.Target == "" || !filepath.IsAbs(mount.Target) {
			return nil, errors.New("mount target must be absolute")
		}
		switch mount.Type {
		case "bind", "tmpfs", "proc", "sysfs", "devpts", "mqueue":
		default:
			return nil, fmt.Errorf("unsupported mount type %q", mount.Type)
		}
		if mount.Type == "bind" && (mount.Source == "" || !filepath.IsAbs(mount.Source)) {
			return nil, errors.New("bind mount source must be absolute")
		}
		options := append([]string(nil), mount.Options...)
		if mount.Type == "bind" {
			hasBind := false
			for _, option := range options {
				if option == "bind" || option == "rbind" {
					hasBind = true
					break
				}
			}
			if !hasBind {
				options = append(options, "rbind")
			}
		}
		if mount.Readonly {
			options = append(options, "ro")
		}
		source := mount.Source
		if source == "" {
			source = mount.Type
		}
		result = append(result, specs.Mount{Source: source, Destination: mount.Target, Type: mount.Type, Options: options})
	}
	return result, nil
}

func (b *Backend) AutoRemove(ctx context.Context, id string) bool {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return false
	}
	labels, err := container.Labels(b.ctx(ctx))
	return err == nil && labels["com.glassdock.auto-remove"] == "true"
}

func (b *Backend) PublishedTCPDestination(guestPort uint16) (string, bool) {
	return b.network.PublishedTCPDestination(guestPort)
}

func (b *Backend) Start(ctx context.Context, request api.ContainerStartRequest) (api.Container, error) {
	ctx = b.ctx(ctx)
	id := request.ID
	record, ok := b.loadRecord(id)
	var container containerd.Container
	if ok {
		container = record.container
	} else {
		var err error
		container, err = b.client.LoadContainer(ctx, id)
		if err != nil {
			return api.Container{}, err
		}
		record, err = b.record(ctx, id, container)
		if err != nil {
			return api.Container{}, err
		}
	}
	info, err := container.Info(ctx)
	if err != nil {
		return api.Container{}, err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	privateNetwork := metadata.NetworkMode == "" || metadata.NetworkMode == "private"
	published := append([]api.PublishedPort(nil), request.PublishedPorts...)
	rollbackNetwork := func() {}
	if privateNetwork {
		if err := b.waitNetworkPreparation(ctx, id); err != nil {
			return api.Container{}, err
		}
		published, err = b.prepareNetwork(id, published)
		if err != nil {
			return api.Container{}, err
		}
		rollbackNetwork = func() { _ = b.network.Delete(id) }
	}
	task, reaped, reaping := record.taskState()
	if reaping != nil {
		select {
		case <-ctx.Done():
			rollbackNetwork()
			return api.Container{}, ctx.Err()
		case <-reaping:
		}
		task, reaped, _ = record.taskState()
	}
	if reaped {
		task = nil
	}
	if task != nil {
		status, statusErr := task.Status(ctx)
		if statusErr != nil && !errdefs.IsNotFound(statusErr) {
			rollbackNetwork()
			return api.Container{}, statusErr
		}
		if errdefs.IsNotFound(statusErr) || status.Status == containerd.Stopped {
			if _, deleteErr := task.Delete(ctx); deleteErr != nil && !errdefs.IsNotFound(deleteErr) {
				rollbackNetwork()
				return api.Container{}, deleteErr
			}
			record.setTask(nil)
			record.setStdinWriter(nil)
			task = nil
		}
	}
	if err := b.clearExitState(ctx, record); err != nil {
		rollbackNetwork()
		return api.Container{}, err
	}
	if task == nil {
		if err := b.acquireTaskCreation(ctx); err != nil {
			rollbackNetwork()
			return api.Container{}, err
		}
		defer b.releaseTaskCreation()
		capture, err := b.createLogCapture(id)
		if err != nil {
			rollbackNetwork()
			return api.Container{}, err
		}
		var stdinReader io.Reader
		var stdinWriter *io.PipeWriter
		if metadata.AttachStdin || metadata.OpenStdin {
			stdinReader, stdinWriter = io.Pipe()
		}
		task, err = container.NewTask(
			ctx,
			cio.NewCreator(cio.WithStreams(stdinReader, capture.stdout, capture.stderr)),
		)
		if err != nil {
			if stdinWriter != nil {
				_ = stdinWriter.Close()
			}
			capture.close()
			b.removeLogs(id)
			rollbackNetwork()
			return api.Container{}, err
		}
		capture.io = task.IO()
		if stdinWriter != nil {
			record.setStdinWriter(stdinWriter)
		}
		b.logCaptures.Store(id, capture)
	}
	if err := task.Start(ctx); err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
		_, _ = task.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		record.setTask(nil)
		b.removeLogs(id)
		rollbackNetwork()
		return api.Container{}, err
	}
	record.setTask(task)
	if err := b.persistRunningState(ctx, container, published); err != nil {
		_ = task.Kill(b.ctx(context.Background()), syscall.SIGKILL)
		_, _ = task.Delete(b.ctx(context.Background()), containerd.WithProcessKill)
		record.setTask(nil)
		rollbackNetwork()
		return api.Container{}, err
	}
	if privateNetwork {
		if err := b.syncNetworkFiles(ctx, id); err != nil {
			_ = task.Kill(b.ctx(context.Background()), syscall.SIGKILL)
			_, _ = task.Delete(b.ctx(context.Background()), containerd.WithProcessKill)
			record.setTask(nil)
			rollbackNetwork()
			return api.Container{}, err
		}
	}
	b.startHealthMonitor(id, container)
	info, _ = container.Info(ctx)
	metadata = decodeRuntimeMetadata(info.Labels)
	if len(published) == 0 {
		published = metadata.PublishedPorts
	}
	return api.Container{
		ID: id, Status: string(containerd.Running), PID: task.Pid(),
		PublishedPorts: published, Metadata: metadata, Health: metadata.Health,
	}, nil
}

func (b *Backend) startHealthMonitor(id string, container containerd.Container) {
	info, err := container.Info(b.ctx(context.Background()))
	if err != nil {
		return
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	config := metadata.Healthcheck
	if config == nil || len(config.Test) == 0 || strings.EqualFold(config.Test[0], "NONE") {
		return
	}
	b.healthMu.Lock()
	if previous := b.healthStops[id]; previous != nil {
		close(previous)
	}
	stop := make(chan struct{})
	b.healthStops[id] = stop
	b.healthMu.Unlock()
	go b.healthLoop(id, container, *config, stop)
}

func (b *Backend) stopHealthMonitor(id string) {
	b.healthMu.Lock()
	if stop := b.healthStops[id]; stop != nil {
		close(stop)
		delete(b.healthStops, id)
	}
	b.healthMu.Unlock()
}

func (b *Backend) healthLoop(
	id string, container containerd.Container, config api.HealthConfig, stop <-chan struct{},
) {
	starting := true
	if config.StartPeriod > 0 {
		timer := time.NewTimer(time.Duration(config.StartPeriod))
		select {
		case <-stop:
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
			starting = false
		}
	}
	for {
		ctx, cancel := context.WithTimeout(b.ctx(context.Background()), healthTimeout(config))
		code, output, err := b.runHealthcheck(ctx, id, config)
		cancel()
		if err != nil && output == "" {
			output = err.Error()
		}
		_ = b.recordHealth(context.Background(), container, code, output, starting)
		interval := healthInterval(config, starting)
		timer := time.NewTimer(interval)
		select {
		case <-stop:
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}
		starting = false
	}
}

func (b *Backend) runHealthcheck(
	ctx context.Context, id string, config api.HealthConfig,
) (int32, string, error) {
	args := append([]string(nil), config.Test...)
	if len(args) == 0 {
		return 0, "", errors.New("healthcheck command is empty")
	}
	switch strings.ToUpper(args[0]) {
	case "CMD":
		args = args[1:]
	case "CMD-SHELL":
		args = []string{"/bin/sh", "-c", strings.Join(args[1:], " ")}
	}
	if len(args) == 0 {
		return 0, "", errors.New("healthcheck command is empty")
	}
	var output bytes.Buffer
	code, err := b.Exec(ctx, api.ContainerExecRequest{
		ID: id, ExecID: "healthcheck-" + strconv.FormatInt(time.Now().UnixNano(), 10),
		Args: args,
	}, func(stream string, data []byte) error {
		if output.Len() < 4096 {
			remaining := 4096 - output.Len()
			if len(data) > remaining {
				data = data[:remaining]
			}
			_, _ = output.Write(data)
		}
		return nil
	})
	return code, output.String(), err
}

func (b *Backend) recordHealth(
	ctx context.Context, container containerd.Container, code int32, output string, starting bool,
) error {
	return b.updateRuntimeMetadata(ctx, container, func(metadata *api.ContainerMetadata) {
		if metadata.Healthcheck == nil {
			return
		}
		if metadata.Health == nil {
			metadata.Health = &api.Health{Status: "starting"}
		}
		now := time.Now()
		metadata.Health.Log = append(metadata.Health.Log, api.HealthcheckResult{
			Start: now, End: time.Now(), ExitCode: int(code), Output: output,
		})
		if len(metadata.Health.Log) > 5 {
			metadata.Health.Log = metadata.Health.Log[len(metadata.Health.Log)-5:]
		}
		if code == 0 {
			metadata.Health.FailingStreak = 0
			metadata.Health.Status = "healthy"
			return
		}
		if starting {
			metadata.Health.Status = "starting"
			return
		}
		metadata.Health.FailingStreak++
		retries := metadata.Healthcheck.Retries
		if retries <= 0 {
			retries = 3
		}
		if metadata.Health.FailingStreak >= retries {
			metadata.Health.Status = "unhealthy"
		} else {
			metadata.Health.Status = "starting"
		}
	})
}

func healthTimeout(config api.HealthConfig) time.Duration {
	if config.Timeout > 0 {
		return time.Duration(config.Timeout)
	}
	return 30 * time.Second
}

func healthInterval(config api.HealthConfig, starting bool) time.Duration {
	nanos := config.Interval
	if starting && config.StartInterval > 0 {
		nanos = config.StartInterval
	}
	if nanos <= 0 {
		nanos = int64(30 * time.Second)
	}
	return time.Duration(nanos)
}

func (b *Backend) WaitHealthy(ctx context.Context, id string) (uint32, error) {
	for {
		container, err := b.client.LoadContainer(b.ctx(ctx), id)
		if err != nil {
			return 0, err
		}
		info, err := container.Info(b.ctx(ctx))
		if err != nil {
			return 0, err
		}
		metadata := decodeRuntimeMetadata(info.Labels)
		if metadata.Healthcheck == nil || len(metadata.Healthcheck.Test) == 0 || strings.EqualFold(metadata.Healthcheck.Test[0], "NONE") {
			return 0, errors.New("no healthcheck configured for the container")
		}
		if metadata.Health != nil && metadata.Health.Status == "healthy" {
			return 0, nil
		}
		if task, taskErr := container.Task(b.ctx(ctx), nil); taskErr != nil {
			if metadata.LastExitCode != nil {
				return *metadata.LastExitCode, nil
			}
		} else if status, statusErr := task.Status(b.ctx(ctx)); statusErr == nil && status.Status == containerd.Stopped {
			return status.ExitStatus, nil
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return 0, ctx.Err()
		case <-timer.C:
		}
	}
}

func (b *Backend) Wait(ctx context.Context, id string) (uint32, time.Time, error) {
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(id)
	var task containerd.Task
	if ok {
		if code, exited := record.persistedExitResult(); exited {
			return code, time.Time{}, nil
		}
		task, _, _ = record.taskState()
	}
	if task == nil {
		container, err := b.client.LoadContainer(ctx, id)
		if err != nil {
			return 0, time.Time{}, err
		}
		record, err = b.record(ctx, id, container)
		if err != nil {
			return 0, time.Time{}, err
		}
		if code, exited := record.persistedExitResult(); exited {
			return code, time.Time{}, nil
		}
		task, err = container.Task(ctx, nil)
		if err != nil {
			info, infoErr := container.Info(ctx)
			if infoErr == nil && decodeRuntimeMetadata(info.Labels).LifecycleState == "running" {
				persistCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				persistErr := b.persistExitState(persistCtx, record, daemonLostExitCode)
				cancel()
				if persistErr == nil {
					return daemonLostExitCode, time.Time{}, nil
				}
			}
			return 0, time.Time{}, err
		}
		record.setTask(task)
	}
	status, err := task.Wait(ctx)
	if err != nil {
		return 0, time.Time{}, err
	}
	exit := <-status
	code, exitedAt, err := exit.Result()
	b.finishLogCapture(id)
	b.stopHealthMonitor(id)
	if err == nil {
		persistCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		persistErr := b.persistExitState(persistCtx, record, code)
		cancel()
		if persistErr == nil {
			go b.reapTask(record, task)
		}
	}
	return code, exitedAt, err
}

func (b *Backend) reapTask(record *containerRecord, task containerd.Task) {
	if !record.beginTaskReap() {
		return
	}
	ctx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
	defer cancel()
	_, err := task.Delete(ctx)
	record.finishTaskReap(err == nil || errdefs.IsNotFound(err))
}

func (b *Backend) Kill(ctx context.Context, id string, signal uint32) error {
	if signal == 0 {
		signal = uint32(syscall.SIGTERM)
	}
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return err
	}
	return task.Kill(b.ctx(ctx), syscall.Signal(signal))
}

func (b *Backend) Pause(ctx context.Context, id string) error {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return err
	}
	if err := task.Pause(b.ctx(ctx)); err != nil {
		return err
	}
	return b.updateRuntimeMetadata(b.ctx(ctx), container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "paused"
	})
}

func (b *Backend) Resume(ctx context.Context, id string) error {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return err
	}
	if err := task.Resume(b.ctx(ctx)); err != nil {
		return err
	}
	return b.updateRuntimeMetadata(b.ctx(ctx), container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "running"
	})
}

func (b *Backend) Resize(ctx context.Context, request api.ContainerResizeRequest) error {
	if request.ID == "" || request.Width == 0 || request.Height == 0 {
		return errors.New("id, width, and height are required")
	}
	container, err := b.client.LoadContainer(b.ctx(ctx), request.ID)
	if err != nil {
		return err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return err
	}
	return task.Resize(b.ctx(ctx), request.Width, request.Height)
}

func (b *Backend) Top(ctx context.Context, request api.ContainerTopRequest) (api.ContainerTopResponse, error) {
	if request.ID == "" {
		return api.ContainerTopResponse{}, errors.New("container ID is required")
	}
	container, err := b.client.LoadContainer(b.ctx(ctx), request.ID)
	if err != nil {
		return api.ContainerTopResponse{}, err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return api.ContainerTopResponse{}, err
	}
	processes, err := task.Pids(b.ctx(ctx))
	if err != nil {
		return api.ContainerTopResponse{}, err
	}
	sort.Slice(processes, func(i, j int) bool { return processes[i].Pid < processes[j].Pid })
	response := api.ContainerTopResponse{
		Titles:    []string{"PID", "CMD"},
		Processes: make([][]string, 0, len(processes)),
	}
	for _, process := range processes {
		response.Processes = append(response.Processes, []string{
			strconv.FormatUint(uint64(process.Pid), 10), processCommand(process.Pid),
		})
	}
	return response, nil
}

func (b *Backend) Stats(ctx context.Context, request api.ContainerStatsRequest) (api.ContainerStatsResponse, error) {
	if request.ID == "" {
		return api.ContainerStatsResponse{}, errors.New("container ID is required")
	}
	container, err := b.client.LoadContainer(b.ctx(ctx), request.ID)
	if err != nil {
		return api.ContainerStatsResponse{}, err
	}
	sample := b.sampleContainerStats(request.ID, container)
	b.statsMu.Lock()
	defer b.statsMu.Unlock()
	if b.lastStats == nil {
		b.lastStats = make(map[string]api.ContainerStatsResponse)
	}
	previous := b.lastStats[request.ID]
	result := sample
	if !previous.Read.IsZero() {
		result.PreRead = previous.Read
		result.PreCPUStats = previous.CPUStats
	}
	b.lastStats[request.ID] = sample
	return result, nil
}

// sampleContainerStats reads one stats point for a container. CPU and memory
// come from the container's own cgroup through containerd task metrics, which
// is the same source Docker's engine reports from; network counters come from
// the container network namespace via /proc.
func (b *Backend) sampleContainerStats(id string, container containerd.Container) api.ContainerStatsResponse {
	current := api.ContainerStatsResponse{
		ID:      id,
		Read:    time.Now(),
		PreRead: time.Now(),
		CPUStats: api.CPUStats{
			CPUUsage:       api.CPUUsage{},
			SystemCPUUsage: readSystemCPUUsage(cpuTicksPerSecond),
			OnlineCPUs:     runtime.NumCPU(),
		},
		MemoryStats: api.MemoryStats{Limit: hostMemoryLimit()},
	}

	task, err := container.Task(b.ctx(context.Background()), nil)
	if err != nil {
		return current
	}

	if processes, err := task.Pids(b.ctx(context.Background())); err == nil && len(processes) > 0 {
		current.PidsStats.Current = uint64(len(processes))
		current.Networks = readNetworkStats(processes)
	}

	metric, err := task.Metrics(b.ctx(context.Background()))
	if err != nil || metric == nil || metric.Data == nil {
		return current
	}
	if typeurl.Is(metric.Data, (*cgroup2stats.Metrics)(nil)) {
		data := &cgroup2stats.Metrics{}
		if err := typeurl.UnmarshalTo(metric.Data, data); err != nil {
			return current
		}
		if data.CPU != nil {
			current.CPUStats.CPUUsage.TotalUsage = data.CPU.UsageUsec * uint64(time.Microsecond)
			current.CPUStats.CPUUsage.InKernelMode = data.CPU.SystemUsec * uint64(time.Microsecond)
			current.CPUStats.CPUUsage.InUserMode = data.CPU.UserUsec * uint64(time.Microsecond)
		}
		if data.Memory != nil {
			current.MemoryStats.Usage = data.Memory.Usage
			current.MemoryStats.Stats = map[string]uint64{
				"anon": data.Memory.Anon,
				"file": data.Memory.File,
				"slab": data.Memory.Slab,
			}
			limit := data.Memory.UsageLimit
			if limit == 0 || limit >= math.MaxUint64 {
				limit = hostMemoryLimit()
			}
			current.MemoryStats.Limit = limit
		}
		if data.Pids != nil && data.Pids.Current > 0 {
			current.PidsStats.Current = data.Pids.Current
		}
	} else if typeurl.Is(metric.Data, (*cgroup1stats.Metrics)(nil)) {
		data := &cgroup1stats.Metrics{}
		if err := typeurl.UnmarshalTo(metric.Data, data); err != nil {
			return current
		}
		if data.CPU != nil && data.CPU.Usage != nil {
			current.CPUStats.CPUUsage.TotalUsage = data.CPU.Usage.Total
			current.CPUStats.CPUUsage.InKernelMode = data.CPU.Usage.Kernel
			current.CPUStats.CPUUsage.InUserMode = data.CPU.Usage.User
		}
		if data.Memory != nil && data.Memory.Usage != nil {
			current.MemoryStats.Usage = data.Memory.Usage.Usage
			current.MemoryStats.Limit = data.Memory.Usage.Limit
		}
	}
	return current
}

const cpuTicksPerSecond = uint64(100)

// hostMemoryLimit reports total guest memory, which is what Docker shows as
// memory limit when a container has no memory restriction.
func hostMemoryLimit() uint64 {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return math.MaxUint64
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			break
		}
		kib, parseErr := strconv.ParseUint(fields[1], 10, 64)
		if parseErr != nil {
			break
		}
		return kib * 1024
	}
	return math.MaxUint64
}

func processCommand(pid uint32) string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.FormatUint(uint64(pid), 10), "cmdline"))
	if err == nil && len(data) > 0 {
		return strings.TrimSpace(strings.ReplaceAll(string(data), "\x00", " "))
	}
	data, err = os.ReadFile(filepath.Join("/proc", strconv.FormatUint(uint64(pid), 10), "comm"))
	if err == nil {
		return strings.TrimSpace(string(data))
	}
	return "-"
}

func readSystemCPUUsage(ticksPerSecond uint64) uint64 {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != "cpu" {
			continue
		}
		var total uint64
		for _, value := range fields[1:] {
			ticks, parseErr := strconv.ParseUint(value, 10, 64)
			if parseErr == nil {
				total += ticks
			}
		}
		return total * uint64(time.Second) / ticksPerSecond
	}
	return 0
}

func readNetworkStats(processes []containerd.ProcessInfo) map[string]api.NetStats {
	if len(processes) == 0 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.FormatUint(uint64(processes[0].Pid), 10), "net/dev"))
	if err != nil {
		return nil
	}
	result := make(map[string]api.NetStats)
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		name := strings.TrimSpace(parts[0])
		if name == "lo" {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) < 16 {
			continue
		}
		values := make([]uint64, 16)
		for index, field := range fields[:16] {
			values[index], _ = strconv.ParseUint(field, 10, 64)
		}
		result[name] = api.NetStats{
			RXBytes: values[0], RXPackets: values[1], RXErrors: values[2], RXDropped: values[3],
			TXBytes: values[8], TXPackets: values[9], TXErrors: values[10], TXDropped: values[11],
		}
	}
	return result
}

func (b *Backend) ExportContainer(ctx context.Context, id string, stream StreamFunc) error {
	root, cleanup, err := b.mountContainerRoot(ctx, id, "glassdock-export-")
	if err != nil {
		return err
	}
	defer cleanup()
	return writeRootfsTar(b.ctx(ctx), root, streamWriter{stream: "stdout", send: stream})
}

func (b *Backend) ArchiveContainer(ctx context.Context, request api.ContainerArchiveRequest, stream StreamFunc) error {
	root, cleanup, err := b.mountContainerRoot(ctx, request.ID, "glassdock-archive-")
	if err != nil {
		return err
	}
	defer cleanup()
	target, relative, err := resolveContainerPath(root, request.Path)
	if err != nil {
		return err
	}
	if err := validateExistingContainerPath(root, target); err != nil {
		return err
	}
	return writeArchivePath(b.ctx(ctx), target, relative, streamWriter{stream: "stdout", send: stream})
}

func (b *Backend) ArchiveInfo(ctx context.Context, request api.ContainerArchiveRequest) (api.ContainerArchivePath, error) {
	root, cleanup, err := b.mountContainerRoot(ctx, request.ID, "glassdock-archive-info-")
	if err != nil {
		return api.ContainerArchivePath{}, err
	}
	defer cleanup()
	target, relative, err := resolveContainerPath(root, request.Path)
	if err != nil {
		return api.ContainerArchivePath{}, err
	}
	if err := validateExistingContainerPath(root, target); err != nil {
		return api.ContainerArchivePath{}, err
	}
	info, err := os.Lstat(target)
	if err != nil {
		return api.ContainerArchivePath{}, err
	}
	linkTarget := ""
	if info.Mode()&os.ModeSymlink != 0 {
		linkTarget, err = os.Readlink(target)
		if err != nil {
			return api.ContainerArchivePath{}, err
		}
	}
	return api.ContainerArchivePath{
		Name: relative, Size: info.Size(), Mode: int64(info.Mode()),
		ModifiedAt: info.ModTime(), LinkTarget: linkTarget,
	}, nil
}

func (b *Backend) PutArchive(ctx context.Context, request api.ContainerArchivePutRequest) error {
	if len(request.Data) == 0 {
		return errors.New("archive data is empty")
	}
	root, cleanup, err := b.mountContainerRoot(ctx, request.ID, "glassdock-archive-put-")
	if err != nil {
		return err
	}
	defer cleanup()
	target, _, err := resolveContainerPath(root, request.Path)
	if err != nil {
		return err
	}
	if err := validateExistingContainerPath(root, target); err != nil {
		return err
	}
	info, err := os.Stat(target)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("archive destination %q is not a directory", request.Path)
	}
	if request.NoOverwriteDirNonDir {
		if err := validateNoOverwriteDirNonDir(target, request.Data); err != nil {
			return err
		}
	}
	_, err = rootfsarchive.Apply(
		b.ctx(ctx), target, bytes.NewReader(request.Data), rootfsarchive.WithNoSameOwner(),
	)
	return err
}

func (b *Backend) Changes(ctx context.Context, id string) ([]api.ContainerChange, error) {
	ctx = b.ctx(ctx)
	container, err := b.client.LoadContainer(ctx, id)
	if err != nil {
		return nil, err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return nil, err
	}
	if info.SnapshotKey == "" || info.Snapshotter == "" {
		return nil, errors.New("container root filesystem is unavailable")
	}
	service := b.client.SnapshotService(info.Snapshotter)
	currentMounts, err := service.Mounts(ctx, info.SnapshotKey)
	if err != nil {
		return nil, err
	}
	currentRoot, err := os.MkdirTemp("", "glassdock-changes-current-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(currentRoot)
	if err := containermount.All(currentMounts, currentRoot); err != nil {
		return nil, err
	}
	defer func() { _ = containermount.UnmountMounts(currentMounts, currentRoot, 0) }()

	snapshotInfo, err := service.Stat(ctx, info.SnapshotKey)
	if err != nil {
		return nil, err
	}
	parentRoot, parentCleanup, err := b.mountSnapshotParent(ctx, service, snapshotInfo.Parent)
	if err != nil {
		return nil, err
	}
	defer parentCleanup()

	diff := rootfsarchive.Diff(ctx, parentRoot, currentRoot)
	defer diff.Close()
	return parseContainerChanges(parentRoot, diff)
}

func (b *Backend) mountContainerRoot(ctx context.Context, id, prefix string) (string, func(), error) {
	ctx = b.ctx(ctx)
	container, err := b.client.LoadContainer(ctx, id)
	if err != nil {
		return "", func() {}, err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return "", func() {}, err
	}
	if info.SnapshotKey == "" || info.Snapshotter == "" {
		return "", func() {}, errors.New("container root filesystem is unavailable")
	}
	mounts, err := b.client.SnapshotService(info.Snapshotter).Mounts(ctx, info.SnapshotKey)
	if err != nil {
		return "", func() {}, err
	}
	root, err := os.MkdirTemp("", prefix)
	if err != nil {
		return "", func() {}, err
	}
	if err := containermount.All(mounts, root); err != nil {
		_ = os.RemoveAll(root)
		return "", func() {}, err
	}
	cleanup := func() {
		_ = containermount.UnmountMounts(mounts, root, 0)
		_ = os.RemoveAll(root)
	}
	return root, cleanup, nil
}

func (b *Backend) mountSnapshotParent(ctx context.Context, service snapshots.Snapshotter, parent string) (string, func(), error) {
	root, err := os.MkdirTemp("", "glassdock-changes-parent-")
	if err != nil {
		return "", func() {}, err
	}
	if parent == "" {
		return root, func() { _ = os.RemoveAll(root) }, nil
	}
	key := fmt.Sprintf("glassdock-changes-view-%d", time.Now().UnixNano())
	mounts, err := service.View(ctx, key, parent)
	if err != nil {
		_ = os.RemoveAll(root)
		return "", func() {}, err
	}
	if err := containermount.All(mounts, root); err != nil {
		_ = service.Remove(ctx, key)
		_ = os.RemoveAll(root)
		return "", func() {}, err
	}
	return root, func() {
		_ = containermount.UnmountMounts(mounts, root, 0)
		_ = service.Remove(ctx, key)
		_ = os.RemoveAll(root)
	}, nil
}

func resolveContainerPath(root, requested string) (string, string, error) {
	if requested == "" || strings.IndexByte(requested, 0) >= 0 || !strings.HasPrefix(requested, "/") {
		return "", "", errors.New("container path must be an absolute path")
	}
	clean := filepath.Clean(requested)
	relative := strings.TrimPrefix(filepath.ToSlash(clean), "/")
	if relative == "" {
		relative = "."
	}
	target := filepath.Join(root, filepath.FromSlash(relative))
	if !pathContains(root, target) {
		return "", "", errors.New("container path escapes the root filesystem")
	}
	return target, relative, nil
}

func validateExistingContainerPath(root, target string) error {
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	probe := target
	for {
		resolved, resolveErr := filepath.EvalSymlinks(probe)
		if resolveErr == nil {
			if !pathContains(resolvedRoot, resolved) {
				return errors.New("container path escapes the root filesystem")
			}
			return nil
		}
		if !os.IsNotExist(resolveErr) || filepath.Dir(probe) == probe {
			return resolveErr
		}
		probe = filepath.Dir(probe)
	}
}

func writeArchivePath(ctx context.Context, target, relative string, writer io.Writer) error {
	tarWriter := tar.NewWriter(writer)
	defer tarWriter.Close()
	return filepath.Walk(target, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		relativePath := relative
		if path != target {
			child, err := filepath.Rel(target, path)
			if err != nil {
				return err
			}
			relativePath = filepath.Join(relative, child)
		}
		linkTarget := ""
		if info.Mode()&os.ModeSymlink != 0 {
			var err error
			linkTarget, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}
		header, err := tar.FileInfoHeader(info, linkTarget)
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(relativePath)
		if err := tarWriter.WriteHeader(header); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		file, err := os.Open(path)
		if err != nil {
			log.Printf("DEBUG-TAR: open error at %s: %v", path, err)
			return err
		}
		defer file.Close()
		_, err = io.Copy(tarWriter, file)
		return err
	})
}

func parseContainerChanges(parentRoot string, diff io.Reader) ([]api.ContainerChange, error) {
	reader := tar.NewReader(diff)
	changes := make([]api.ContainerChange, 0)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		name := filepath.ToSlash(filepath.Clean(header.Name))
		if name == "." || name == "" || strings.HasPrefix(name, "../") {
			continue
		}
		kind := 2
		pathName := "/" + strings.TrimPrefix(name, "./")
		base := filepath.Base(name)
		if strings.HasPrefix(base, ".wh.") {
			if base == ".wh..wh..opq" {
				pathName = "/" + filepath.ToSlash(filepath.Dir(name))
				kind = 2
			} else {
				pathName = "/" + filepath.ToSlash(filepath.Join(filepath.Dir(name), strings.TrimPrefix(base, ".wh.")))
				kind = 1
			}
		} else if _, err := os.Lstat(filepath.Join(parentRoot, filepath.FromSlash(name))); os.IsNotExist(err) {
			kind = 0
		}
		changes = append(changes, api.ContainerChange{Path: pathName, Kind: kind})
	}
	sort.Slice(changes, func(i, j int) bool { return changes[i].Path < changes[j].Path })
	return changes, nil
}

func writeRootfsTar(ctx context.Context, root string, writer io.Writer) error {
	tarWriter := tar.NewWriter(writer)
	defer tarWriter.Close()
	return filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			log.Printf("DEBUG-TAR: walk error at %s: %v", path, walkErr)
			return walkErr
		}
		if path == root {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(relative)
		if info.Mode()&os.ModeSymlink != 0 {
			header.Linkname, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}
		if err := tarWriter.WriteHeader(header); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		file, err := os.Open(path)
		if err != nil {
			log.Printf("DEBUG-TAR: open error at %s: %v", path, err)
			return err
		}
		defer file.Close()
		buffer := make([]byte, 32*1024)
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			count, readErr := file.Read(buffer)
			if count > 0 {
				if _, err := tarWriter.Write(buffer[:count]); err != nil {
					log.Printf("DEBUG-TAR: tar write error at %s: %v", path, err)
					return err
				}
			}
			if readErr == io.EOF {
				return nil
			}
			if readErr != nil {
				return readErr
			}
		}
	})
}

func (b *Backend) Delete(ctx context.Context, request api.ContainerDeleteRequest) error {
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(request.ID)
	if !ok {
		container, err := b.client.LoadContainer(ctx, request.ID)
		if err != nil {
			return err
		}
		info, err := container.Info(ctx)
		if err != nil {
			return err
		}
		record = &containerRecord{
			container: container, snapshotter: info.Snapshotter, snapshotKey: info.SnapshotKey,
		}
	}
	task, reaped, reaping := record.taskState()
	if reaping != nil {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-reaping:
		}
		task, reaped, _ = record.taskState()
	}
	if task != nil && !reaped {
		if !request.Force {
			status, err := task.Status(ctx)
			if err != nil {
				return err
			}
			if err := validateTaskRemoval(false, string(status.Status)); err != nil {
				return err
			}
		}
		if request.Force {
			_ = task.Kill(ctx, syscall.SIGKILL)
		}
		deleteOptions := []containerd.ProcessDeleteOpts{}
		if request.Force {
			deleteOptions = append(deleteOptions, containerd.WithProcessKill)
		}
		if _, err := task.Delete(ctx, deleteOptions...); err != nil && !errdefs.IsNotFound(err) {
			return err
		}
		record.finishTaskReap(true)
	} else if !ok {
		if task, taskErr := record.container.Task(ctx, nil); taskErr == nil {
			if !request.Force {
				status, err := task.Status(ctx)
				if err != nil {
					return err
				}
				if err := validateTaskRemoval(false, string(status.Status)); err != nil {
					return err
				}
			}
			if request.Force {
				_ = task.Kill(ctx, syscall.SIGKILL)
			}
			deleteOptions := []containerd.ProcessDeleteOpts{}
			if request.Force {
				deleteOptions = append(deleteOptions, containerd.WithProcessKill)
			}
			if _, err := task.Delete(ctx, deleteOptions...); err != nil && !errdefs.IsNotFound(err) {
				return err
			}
		}
	}
	if err := record.container.Delete(ctx); err != nil {
		return err
	}
	b.containers.Delete(request.ID)
	if request.Snapshot && record.snapshotKey != "" {
		go b.removeSnapshot(record.snapshotter, record.snapshotKey)
	}
	b.removeLogs(request.ID)
	b.cleanups.enqueue(func() error {
		if err := b.waitNetworkPreparation(context.Background(), request.ID); err != nil {
			return err
		}
		err := b.network.Delete(request.ID)
		b.networks.Delete(request.ID)
		return err
	})
	return nil
}

func validateTaskRemoval(force bool, status string) error {
	if !force && status != string(containerd.Stopped) {
		return errors.New("cannot remove a running container without force")
	}
	return nil
}

func (b *Backend) loadRecord(id string) (*containerRecord, bool) {
	value, ok := b.containers.Load(id)
	if !ok {
		return nil, false
	}
	return value.(*containerRecord), true
}

func newRestoredContainerRecord(container containerd.Container, info containerrecords.Container) *containerRecord {
	metadata := decodeRuntimeMetadata(info.Labels)
	var persistedCode uint32
	if metadata.LastExitCode != nil {
		persistedCode = *metadata.LastExitCode
	}
	return &containerRecord{
		container:     container,
		snapshotter:   info.Snapshotter,
		snapshotKey:   info.SnapshotKey,
		persistedExit: metadata.LifecycleState == "exited" && metadata.LastExitCode != nil,
		persistedCode: persistedCode,
	}
}

func (b *Backend) record(ctx context.Context, id string, container containerd.Container) (*containerRecord, error) {
	if record, ok := b.loadRecord(id); ok {
		return record, nil
	}
	info, err := container.Info(ctx)
	if err != nil {
		return nil, err
	}
	record := newRestoredContainerRecord(container, info)
	actual, _ := b.containers.LoadOrStore(id, record)
	return actual.(*containerRecord), nil
}

func (b *Backend) removeSnapshot(snapshotter, key string) {
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	service := b.client.SnapshotService(snapshotter)
	for attempt := 0; attempt < 5; attempt++ {
		ctx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
		err := service.Remove(ctx, key)
		cancel()
		if err == nil || errdefs.IsNotFound(err) {
			return
		}
		time.Sleep(time.Duration(1<<attempt) * 10 * time.Millisecond)
	}
}

type StreamFunc func(stream string, data []byte) error

type execCleanupFunc func(context.Context) error

func runExecCleanup(cleanup execCleanupFunc, pause func(time.Duration)) {
	for attempt := 0; attempt < execCleanupAttempts; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), execCleanupAttemptTimeout)
		err := cleanup(ctx)
		cancel()
		if err == nil || errdefs.IsNotFound(err) {
			return
		}
		if attempt+1 < execCleanupAttempts {
			pause(time.Duration(1<<attempt) * 10 * time.Millisecond)
		}
	}
}

func scheduleExecCleanup(cleanup execCleanupFunc) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		runExecCleanup(cleanup, time.Sleep)
	}()
	return done
}

type streamWriter struct {
	stream string
	send   StreamFunc
}

func (w streamWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	copyOfP := append([]byte(nil), p...)
	if err := w.send(w.stream, copyOfP); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (b *Backend) Exec(ctx context.Context, request api.ContainerExecRequest, stream StreamFunc) (int32, error) {
	return b.ExecInput(ctx, request, nil, stream)
}

func (b *Backend) ExecInput(
	ctx context.Context, request api.ContainerExecRequest, input <-chan []byte, stream StreamFunc,
) (int32, error) {
	if request.ID == "" || request.ExecID == "" || len(request.Args) == 0 {
		return 0, errors.New("id, execId, and args are required")
	}
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(request.ID)
	var container containerd.Container
	var task containerd.Task
	if ok {
		container = record.container
		task, _, _ = record.taskState()
	} else {
		var err error
		container, err = b.client.LoadContainer(ctx, request.ID)
		if err != nil {
			return 0, err
		}
		record, err = b.record(ctx, request.ID, container)
		if err != nil {
			return 0, err
		}
	}
	if task == nil {
		var err error
		task, err = container.Task(ctx, nil)
		if err != nil {
			return 0, err
		}
		record.setTask(task)
	}
	containerSpec := record.cachedSpec()
	if containerSpec == nil {
		var err error
		containerSpec, err = container.Spec(ctx)
		if err != nil {
			return 0, err
		}
		record.setSpec(containerSpec)
	}
	cwd := request.Cwd
	if cwd == "" {
		cwd = containerSpec.Process.Cwd
	}
	env := append([]string(nil), containerSpec.Process.Env...)
	env = append(env, request.Env...)
	processSpec := &specs.Process{Args: request.Args, Env: env, Cwd: cwd, Terminal: request.Terminal, User: containerSpec.Process.User}
	if request.User != "" {
		info, err := container.Info(ctx)
		if err != nil {
			return 0, err
		}
		specCopy := *containerSpec
		processCopy := *containerSpec.Process
		specCopy.Process = &processCopy
		if err := oci.WithUser(request.User)(ctx, b.client, &info, &specCopy); err != nil {
			return 0, err
		}
		processSpec.User = specCopy.Process.User
	}
	var stdout, stderr io.Writer = streamWriter{"stdout", stream}, streamWriter{"stderr", stream}
	if request.Terminal {
		stderr = bytes.NewBuffer(nil)
	}
	var stdin io.Reader
	var stdinWriter *io.PipeWriter
	if input != nil && request.AttachStdin {
		reader, writer := io.Pipe()
		stdin, stdinWriter = reader, writer
		go func() {
			defer writer.Close()
			for {
				select {
				case <-ctx.Done():
					_ = writer.CloseWithError(ctx.Err())
					return
				case data, ok := <-input:
					if !ok {
						return
					}
					if _, err := writer.Write(data); err != nil {
						return
					}
				}
			}
		}()
	}
	process, err := task.Exec(ctx, request.ExecID, processSpec, cio.NewCreator(cio.WithStreams(stdin, stdout, stderr)))
	if err != nil {
		if stdinWriter != nil {
			_ = stdinWriter.Close()
		}
		return 0, err
	}
	b.execMu.Lock()
	if b.execProcesses == nil {
		b.execProcesses = make(map[string]containerd.Process)
	}
	b.execProcesses[request.ExecID] = process
	b.execMu.Unlock()
	defer func() {
		b.execMu.Lock()
		delete(b.execProcesses, request.ExecID)
		b.execMu.Unlock()
	}()
	wait, err := process.Wait(ctx)
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), execCleanupAttemptTimeout)
		_, _ = process.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		return 0, err
	}
	if err := process.Start(ctx); err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), execCleanupAttemptTimeout)
		_, _ = process.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		return 0, err
	}
	exit := <-wait
	code, _, err := exit.Result()
	if processIO := process.IO(); processIO != nil {
		processIO.Wait()
	}
	scheduleExecCleanup(func(cleanupCtx context.Context) error {
		_, cleanupErr := process.Delete(b.ctx(cleanupCtx))
		return cleanupErr
	})
	if err != nil {
		return 0, err
	}
	return int32(code), nil
}

func (b *Backend) AttachInput(
	ctx context.Context, request api.ContainerLogsRequest, input <-chan []byte, stream StreamFunc,
) (uint32, error) {
	if input != nil {
		go b.copyStdin(ctx, request.ID, input)
	}
	return b.Attach(ctx, request, stream)
}

func (b *Backend) copyStdin(ctx context.Context, id string, input <-chan []byte) {
	record, ok := b.loadRecord(id)
	if !ok {
		container, err := b.client.LoadContainer(b.ctx(ctx), id)
		if err != nil {
			return
		}
		record, err = b.record(b.ctx(ctx), id, container)
		if err != nil {
			return
		}
	}
	writer := record.getStdinWriter()
	if writer == nil {
		return
	}
	defer writer.Close()
	for {
		select {
		case <-ctx.Done():
			return
		case data, ok := <-input:
			if !ok {
				return
			}
			if _, err := writer.Write(data); err != nil {
				return
			}
		}
	}
}

func (b *Backend) ResizeExec(ctx context.Context, request api.ExecResizeRequest) error {
	if request.ID == "" || request.Width == 0 || request.Height == 0 {
		return errors.New("id, width, and height are required")
	}
	b.execMu.Lock()
	process := b.execProcesses[request.ID]
	b.execMu.Unlock()
	if process == nil {
		return fmt.Errorf("exec process %s is not running", request.ID)
	}
	return process.Resize(b.ctx(ctx), request.Width, request.Height)
}
