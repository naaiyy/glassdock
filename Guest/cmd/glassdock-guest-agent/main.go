package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/mdlayher/vsock"
	"github.com/glassdock/glassdock/guest/internal/backend"
	builder "github.com/glassdock/glassdock/guest/internal/builder"
	"github.com/glassdock/glassdock/guest/internal/forwarder"
	"github.com/glassdock/glassdock/guest/internal/server"
)

var version = "dev"

func main() {
	containerdAddress := flag.String("containerd", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "glassdock", "containerd namespace")
	snapshotter := flag.String("snapshotter", "overlayfs", "containerd snapshotter")
	runtimeName := flag.String("runtime", "io.containerd.runc.v2", "containerd runtime type")
	runtimeBinary := flag.String("runtime-binary", "/usr/bin/runc", "OCI runtime binary used by the runc v2 shim")
	unixAddress := flag.String("unix", "", "listen on a Unix socket instead of vsock (tests and diagnostics)")
	port := flag.Uint("vsock-port", 1025, "guest vsock port")
	forwardUnixAddress := flag.String("forward-unix", "", "listen for TCP relay connections on a Unix socket")
	forwardPort := flag.Uint("forward-vsock-port", 1026, "guest TCP relay vsock port")
	hostBindSource := flag.String("host-bind-source", "", "host source exported by virtiofs")
	guestBindRoot := flag.String("guest-bind-root", "", "fixed guest mount point for the host source")
	excludedHostBindSource := flag.String("excluded-host-bind-source", "", "host engine state excluded from bind mounts")
	builderRoot := flag.String("builder-root", "/var/lib/containerd/io.glassdock.build", "buildkit state directory")
	builderUnixAddress := flag.String("builder-unix", "", "listen for builder (BuildKit) connections on a Unix socket instead of vsock")
	builderPort := flag.Uint("builder-vsock-port", 1027, "builder (BuildKit) vsock port; 0 disables the listener")
	flag.Parse()

	b, err := backend.New(*containerdAddress, *namespace, *snapshotter, *runtimeName, *runtimeBinary)
	if err != nil {
		log.Fatal(err)
	}
	defer b.Close()
	if *hostBindSource == "" || *guestBindRoot == "" || *excludedHostBindSource == "" {
		log.Fatal("host bind source, guest bind root, and excluded host bind source are required")
	}
	b.ConfigureBindMount(*hostBindSource, *guestBindRoot, *excludedHostBindSource)
	if err := b.InitializeNetwork(); err != nil {
		log.Fatal(err)
	}

	var builderListener net.Listener
	var buildkit *builder.Builder
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if *builderPort != 0 || *builderUnixAddress != "" {
		var err error
		buildkit, err = builder.New(ctx, builder.Options{
			Root:              *builderRoot,
			ContainerdAddress: *containerdAddress,
			Namespace:         *namespace,
			Snapshotter:       *snapshotter,
		})
		if err != nil {
			log.Fatal(err)
		}
		defer buildkit.Close()
		b.SetBuildCacheUsage(buildkit.DiskUsage)
		b.SetBuildCachePrune(buildkit.Prune)
		if *builderUnixAddress != "" {
			_ = os.Remove(*builderUnixAddress)
			builderListener, err = net.Listen("unix", *builderUnixAddress)
		} else {
			builderListener, err = vsock.Listen(uint32(*builderPort), nil)
		}
		if err != nil {
			log.Fatal(err)
		}
		defer builderListener.Close()
	}

	var listener net.Listener
	var forwardListener net.Listener
	if *unixAddress != "" {
		_ = os.Remove(*unixAddress)
		listener, err = net.Listen("unix", *unixAddress)
	} else {
		listener, err = vsock.Listen(uint32(*port), nil)
	}
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	if *forwardUnixAddress != "" {
		_ = os.Remove(*forwardUnixAddress)
		forwardListener, err = net.Listen("unix", *forwardUnixAddress)
	} else {
		forwardListener, err = vsock.Listen(uint32(*forwardPort), nil)
	}
	if err != nil {
		log.Fatal(err)
	}
	defer forwardListener.Close()
	log.Printf(
		"glassdock guest agent %s listening on %s; TCP relay on %s",
		version,
		listener.Addr(),
		forwardListener.Addr(),
	)
	guestServer := server.New(b, version)
	tcpServer := forwarder.NewTCPServer(b.PublishedTCPDestination)
	errors := make(chan error, 3)
	go func() { errors <- guestServer.Serve(ctx, listener) }()
	go func() { errors <- tcpServer.Serve(ctx, forwardListener) }()
	if builderListener != nil {
		go func() {
			for {
				conn, err := builderListener.Accept()
				if err != nil {
					if ctx.Err() == nil {
						errors <- err
					}
					return
				}
				go func() {
					defer conn.Close()
					serveCtx, cancel := context.WithCancel(ctx)
					defer cancel()
					if err := buildkit.Serve(serveCtx, conn); err != nil {
						log.Printf("builder connection failed: %v", err)
					}
				}()
			}
		}()
	}
	if err := <-errors; err != nil {
		stop()
		_ = listener.Close()
		_ = forwardListener.Close()
		log.Fatal(err)
	}
}
