package builder

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/moby/buildkit/session"
)

func newServeTestBuilder(t *testing.T) *Builder {
	t.Helper()
	manager, err := session.NewManager()
	if err != nil {
		t.Fatalf("create session manager: %v", err)
	}
	return &Builder{sessionManager: manager}
}

func startServeListener(t *testing.T, b *Builder) string {
	t.Helper()
	address := filepath.Join("/tmp", "glassdock-builder-test.sock")
	listener, err := net.Listen("unix", address)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_ = b.Serve(context.Background(), conn)
			}()
		}
	}()
	return address
}

func TestCanonicalMobyImageNamesUsesDockerTagSemantics(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		input string
		want  string
	}{
		{input: "alpine", want: "docker.io/library/alpine:latest"},
		{input: "example/app", want: "docker.io/example/app:latest"},
		{input: "example/app:dev", want: "docker.io/example/app:dev"},
		{
			input: "example/app,localhost/app:dev",
			want:  "docker.io/example/app:latest,localhost/app:dev",
		},
	} {
		t.Run(test.input, func(t *testing.T) {
			if got := canonicalMobyImageNames(test.input); got != test.want {
				t.Fatalf("canonicalMobyImageNames(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestServeSessionUpgradeRegistersSession(t *testing.T) {
	b := newServeTestBuilder(t)
	address := startServeListener(t, b)

	conn, err := net.Dial("unix", address)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	requestID := "0a1b2c3d-0000-0000-0000-000000000001"
	payload := "POST /session HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n" +
		"X-Docker-Expose-Session-Uuid: " + requestID + "\r\n" +
		"X-Docker-Expose-Session-Sharedkey: glassdock\r\n" +
		"X-Docker-Expose-Session-Grpc-Method: /moby.buildkit.v1.Sessions/FileSend\r\n" +
		"\r\n"
	if _, err := conn.Write([]byte(payload)); err != nil {
		t.Fatalf("write upgrade request: %v", err)
	}

	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodPost})
	if err != nil {
		t.Fatalf("read upgrade response: %v", err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade status = %d, want %d", response.StatusCode, http.StatusSwitchingProtocols)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	caller, err := b.sessionManager.Get(ctx, requestID, false)
	if err != nil {
		t.Fatalf("session was not registered: %v", err)
	}
	if caller == nil {
		t.Fatal("session caller is nil")
	}
}

func TestServeRejectsUnknownEndpointAndProtocol(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		status  int
	}{
		{
			name:    "unknown endpoint",
			payload: "POST /other HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
			status:  http.StatusNotFound,
		},
		{
			name:    "missing upgrade protocol",
			payload: "POST /session HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\n\r\n",
			status:  http.StatusBadRequest,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			b := newServeTestBuilder(t)
			recorder := httptest.NewRecorder()
			_ = recorder

			serverConn, clientConn := net.Pipe()
			defer serverConn.Close()
			defer clientConn.Close()
			done := make(chan error, 1)
			go func() { done <- b.Serve(context.Background(), serverConn) }()
			clientConn.Write([]byte(test.payload))

			reader := bufio.NewReader(clientConn)
			response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodPost})
			if err != nil {
				t.Fatalf("read error response: %v", err)
			}
			if response.StatusCode != test.status {
				t.Fatalf("status = %d, want %d", response.StatusCode, test.status)
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("Serve did not return")
			}
		})
	}
}
