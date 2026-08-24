package builder

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"

	"github.com/containerd/containerd/v2/defaults"
	"github.com/moby/buildkit/util/grpcerrors"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
)

// Serve upgrades an inbound hijacked Docker API connection. The request head
// has already arrived on the connection: it is parsed here, the 101 response is
// written back, and the remaining bytes are handed to either the BuildKit
// session manager (POST /session) or the Control gRPC server (POST /grpc).
func (b *Builder) Serve(ctx context.Context, conn net.Conn) error {
	reader := bufio.NewReader(conn)
	request, err := http.ReadRequest(reader)
	if err != nil {
		writeRawResponse(conn, "400 Bad Request")
		return fmt.Errorf("parse builder request: %w", err)
	}
	proto := request.Header.Get("Upgrade")
	if proto != "h2c" {
		writeRawResponse(conn, "400 Bad Request")
		return fmt.Errorf("unsupported builder upgrade protocol %q", proto)
	}
	switch request.URL.Path {
	case "/session", "/grpc":
	default:
		writeRawResponse(conn, "404 Not Found")
		return fmt.Errorf("unsupported builder endpoint %q", request.URL.Path)
	}

	// Mirror Moby's hijack handlers: emit a bare 101 and switch the connection.
	response := &http.Response{
		StatusCode: http.StatusSwitchingProtocols,
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     http.Header{},
	}
	response.Header.Set("Connection", "Upgrade")
	response.Header.Set("Upgrade", proto)
	if err := response.Write(conn); err != nil {
		return err
	}

	upgraded := &bufferedConn{Conn: conn, reader: reader}
	switch request.URL.Path {
	case "/session":
		headers := map[string][]string(request.Header)
		return b.sessionManager.HandleConn(ctx, upgraded, headers)
	case "/grpc":
		server, err := b.controlServer()
		if err != nil {
			return err
		}
		go func() {
			<-ctx.Done()
			conn.Close()
		}()
		(&http2.Server{}).ServeConn(upgraded, &http2.ServeConnOpts{Handler: server})
		return nil
	default:
		return fmt.Errorf("unsupported builder endpoint %q", request.URL.Path)
	}
}

func (b *Builder) controlServer() (*grpc.Server, error) {
	options := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(grpcerrors.UnaryServerInterceptor),
		grpc.ChainStreamInterceptor(grpcerrors.StreamServerInterceptor),
		grpc.MaxRecvMsgSize(defaults.DefaultMaxRecvMsgSize),
		grpc.MaxSendMsgSize(defaults.DefaultMaxSendMsgSize),
	}
	server := grpc.NewServer(options...)
	controller := b.Controller()
	if controller == nil {
		return nil, fmt.Errorf("buildkit controller is not running")
	}
	// Controller.Register serves the Control API, the in-process frontend
	// gateway bridge (moby.buildkit.v1.frontend.LLBBridge) used by the
	// dockerfile frontend, trace export, and content serving.
	controller.Register(server)
	grpc_health_v1.RegisterHealthServer(server, health.NewServer())
	return server, nil
}

// bufferedConn replays bytes that http.ReadRequest buffered past the request
// head before falling through to the live socket.
type bufferedConn struct {
	net.Conn
	reader io.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

func writeRawResponse(conn net.Conn, status string) {
	fmt.Fprintf(conn, "HTTP/1.1 %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", status)
}
