package builder

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
	bkclient "github.com/moby/buildkit/client"

	"golang.org/x/sync/errgroup"

	ctd "github.com/containerd/containerd/v2/client"
	"github.com/moby/buildkit/control"
	"github.com/moby/buildkit/exporter"
	bkfrontend "github.com/moby/buildkit/frontend"
	"github.com/moby/buildkit/frontend/dockerfile/builder"
	bkgw "github.com/moby/buildkit/frontend/gateway"
	"github.com/moby/buildkit/frontend/gateway/forwarder"
	"github.com/moby/buildkit/session"
	"github.com/moby/buildkit/solver"
	"github.com/moby/buildkit/solver/bboltcachestorage"
	"github.com/moby/buildkit/util/db/boltutil"
	"github.com/moby/buildkit/util/network/netproviders"
	"github.com/moby/buildkit/util/resolver"
	bkworker "github.com/moby/buildkit/worker"
	"github.com/moby/buildkit/worker/base"
	bkcontainerd "github.com/moby/buildkit/worker/containerd"
)

// Builder embeds a BuildKit controller backed by the guest containerd
// instance. It exposes the same Control API and session handling that Moby
// bridges its /grpc and /session endpoints onto.
type Builder struct {
	controller       *control.Controller
	sessionManager   *session.Manager
	workerController *bkworker.Controller
	root             string
}

type Options struct {
	Root              string
	ContainerdAddress string
	Namespace         string
	Snapshotter       string
}

func New(ctx context.Context, options Options) (*Builder, error) {
	if options.Root == "" {
		return nil, fmt.Errorf("builder root directory is required")
	}
	if options.ContainerdAddress == "" {
		options.ContainerdAddress = "/run/containerd/containerd.sock"
	}
	if options.Namespace == "" {
		options.Namespace = "buildkit"
	}
	if options.Snapshotter == "" {
		options.Snapshotter = "overlayfs"
	}
	if err := os.MkdirAll(options.Root, 0o711); err != nil {
		return nil, err
	}

	sessionManager, err := session.NewManager()
	if err != nil {
		return nil, fmt.Errorf("create buildkit session manager: %w", err)
	}

	workerOptions := bkcontainerd.WorkerOptions{
		Root:            filepath.Join(options.Root, "worker"),
		Address:         options.ContainerdAddress,
		SnapshotterName: options.Snapshotter,
		// The runtime image store lives in this namespace; exporting built
		// images here makes them immediately visible to the Docker API
		// surface without a cross-namespace copy.
		Namespace: options.Namespace,
		Labels: map[string]string{
			"org.mobyproject.buildkit.worker.snapshotter": options.Snapshotter,
		},
		NetworkOpt: netproviders.Opt{Mode: "host"},
	}
	workerOpt, err := bkcontainerd.NewWorkerOpt(workerOptions, ctd.WithTimeout(60*time.Second))
	if err != nil {
		return nil, fmt.Errorf("create buildkit containerd worker: %w", err)
	}
	workerOpt.RegistryHosts = resolver.NewRegistryConfig(nil)

	buildkitWorker, err := base.NewWorker(context.Background(), workerOpt)
	if err != nil {
		return nil, fmt.Errorf("start buildkit worker: %w", err)
	}
	workerController := &bkworker.Controller{}
	if err := workerController.Add(&mobyWorkerAlias{Worker: buildkitWorker}); err != nil {
		return nil, fmt.Errorf("register buildkit worker: %w", err)
	}

	gatewayFrontend, err := bkgw.NewGatewayFrontend(workerController.Infos(), nil)
	if err != nil {
		return nil, fmt.Errorf("create buildkit gateway frontend: %w", err)
	}
	frontends := map[string]bkfrontend.Frontend{
		"dockerfile.v0": forwarder.NewGatewayForwarder(workerController.Infos(), builder.Build),
		"gateway.v0":    gatewayFrontend,
	}

	cacheStorage, err := bboltcachestorage.NewStore(filepath.Join(options.Root, "cache.db"))
	if err != nil {
		return nil, fmt.Errorf("open buildkit cache store: %w", err)
	}

	historyDB, err := boltutil.Open(filepath.Join(options.Root, "history.db"), 0o600, nil)
	if err != nil {
		return nil, fmt.Errorf("open buildkit history database: %w", err)
	}

	controller, err := control.NewController(control.Opt{
		SessionManager:   sessionManager,
		WorkerController: workerController,
		Frontends:        frontends,
		CacheManager:     solver.NewCacheManager(ctx, "local", cacheStorage, bkworker.NewCacheResultStorage(workerController)),
		CacheStore:       cacheStorage,
		HistoryDB:        historyDB,
		LeaseManager:     buildkitWorker.LeaseManager(),
		ContentStore:     buildkitWorker.ContentStore(),
		GarbageCollect:   buildkitWorker.GarbageCollect,
	})
	if err != nil {
		return nil, fmt.Errorf("create buildkit controller: %w", err)
	}

	return &Builder{
		controller:       controller,
		sessionManager:   sessionManager,
		workerController: workerController,
		root:             options.Root,
	}, nil
}

func (b *Builder) Controller() *control.Controller {
	return b.controller
}

func (b *Builder) SessionManager() *session.Manager {
	return b.sessionManager
}

func (b *Builder) Close() error {
	return b.controller.Close()
}

// mobyWorkerAlias accepts the Docker-specific "moby" exporter name that the
// buildx docker driver requests and resolves it to BuildKit's container image
// exporter, which tags results into the runtime image store.
type mobyWorkerAlias struct {
	*base.Worker
}

func (w *mobyWorkerAlias) Exporter(name string, sm *session.Manager) (exporter.Exporter, error) {
	if name == "moby" {
		name = "image"
	}
	return w.Worker.Exporter(name, sm)
}

// DiskUsage reports BuildKit cache records for /system/df.
func (b *Builder) DiskUsage(ctx context.Context) ([]api.BuildCacheRecord, error) {
	workers, err := b.workerController.List()
	if err != nil {
		return nil, fmt.Errorf("list buildkit workers for disk usage: %w", err)
	}
	records := make([]api.BuildCacheRecord, 0)
	for _, buildkitWorker := range workers {
		usage, err := buildkitWorker.DiskUsage(ctx, bkclient.DiskUsageInfo{})
		if err != nil {
			return nil, err
		}
		for _, record := range usage {
			records = append(records, api.BuildCacheRecord{
				ID:          record.ID,
				Type:        string(record.RecordType),
				Description: record.Description,
				InUse:       record.InUse,
				Shared:      record.Shared,
				Size:        record.Size,
				CreatedAt:   record.CreatedAt,
				LastUsedAt: func() time.Time {
					if record.LastUsedAt != nil {
						return *record.LastUsedAt
					}
					return time.Time{}
				}(),
				UsageCount: int(record.UsageCount),
			})
		}
	}
	return records, nil
}

// Prune removes unused BuildKit cache records and reports reclaimed space.
func (b *Builder) Prune(ctx context.Context, all bool) (api.BuilderPruneResponse, error) {
	response := api.BuilderPruneResponse{CachesDeleted: []api.BuilderPruneRecord{}}
	ch := make(chan bkclient.UsageInfo, 32)
	workers, err := b.workerController.List()
	if err != nil {
		return response, fmt.Errorf("list buildkit workers for prune: %w", err)
	}
	group, groupCtx := errgroup.WithContext(ctx)
	for _, buildkitWorker := range workers {
		buildkitWorker := buildkitWorker
		group.Go(func() error {
			return buildkitWorker.Prune(groupCtx, ch, bkclient.PruneInfo{All: all})
		})
	}
	collectDone := make(chan struct{})
	go func() {
		defer close(collectDone)
		for usage := range ch {
			response.CachesDeleted = append(response.CachesDeleted, api.BuilderPruneRecord{
				ID:             usage.ID,
				SpaceReclaimed: usage.Size,
			})
			response.SpaceReclaimed += usage.Size
		}
	}()
	if err := group.Wait(); err != nil {
		return response, err
	}
	close(ch)
	<-collectDone
	return response, nil
}
