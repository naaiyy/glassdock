package forwarder

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

func startUnixSocketTestServer(
	t *testing.T, announce func(*UnixSocketServer, string) error,
) (*UnixSocketServer, string, context.CancelFunc) {
	t.Helper()
	file, err := os.CreateTemp("/tmp", "gd-socket-")
	if err != nil {
		t.Fatal(err)
	}
	path := file.Name()
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	server := NewUnixSocketServer(path, nil)
	server.announce = func(id string) error { return announce(server, id) }
	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-serveDone:
			if err != nil {
				t.Errorf("Serve error = %v", err)
			}
		case <-time.After(time.Second):
			t.Error("Serve did not stop")
		}
	})
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return server, path, cancel
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("unix socket was not created")
	return nil, "", nil
}

func dialUnixSocket(t *testing.T, path string) net.Conn {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("unix", path, 100*time.Millisecond)
		if err == nil {
			return connection
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("could not connect to %s", path)
	return nil
}

func TestUnixSocketRelaySupportsConcurrentConnections(t *testing.T) {
	var path string
	_, path, _ = startUnixSocketTestServer(t, func(server *UnixSocketServer, id string) error {
		connection, release, err := server.Open(id)
		if err != nil {
			return err
		}
		input := make(chan []byte, 16)
		go func() {
			defer release()
			defer connection.Close()
			_ = RelayConnection(context.Background(), connection, input, func(data []byte) error {
				if len(data) == 0 {
					if data == nil {
						return errors.New("relay EOF marker must be non-nil")
					}
					close(input)
					return nil
				}
				input <- append([]byte("reply:"), data...)
				return nil
			})
		}()
		return nil
	})

	const connections = 16
	var group sync.WaitGroup
	for index := 0; index < connections; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			connection := dialUnixSocket(t, path)
			defer connection.Close()
			request := []byte("request-" + string(rune('a'+index)))
			if _, err := connection.Write(request); err != nil {
				t.Errorf("write request: %v", err)
				return
			}
			if unix, ok := connection.(*net.UnixConn); ok {
				if err := unix.CloseWrite(); err != nil {
					t.Errorf("close write: %v", err)
					return
				}
			}
			response, err := io.ReadAll(connection)
			if err != nil {
				t.Errorf("read response: %v", err)
				return
			}
			want := append([]byte("reply:"), request...)
			if string(response) != string(want) {
				t.Errorf("response = %q, want %q", response, want)
			}
		}(index)
	}
	group.Wait()
}

func TestRelayConnectionPreservesHalfClose(t *testing.T) {
	var path string
	_, path, _ = startUnixSocketTestServer(t, func(server *UnixSocketServer, id string) error {
		connection, release, err := server.Open(id)
		if err != nil {
			return err
		}
		input := make(chan []byte, 1)
		go func() {
			defer release()
			defer connection.Close()
			_ = RelayConnection(context.Background(), connection, input, func(data []byte) error {
				if len(data) == 0 {
					if data == nil {
						return errors.New("relay EOF marker must be non-nil")
					}
					close(input)
					return nil
				}
				input <- append([]byte("response:"), data...)
				return nil
			})
		}()
		return nil
	})

	connection := dialUnixSocket(t, path)
	defer connection.Close()
	if _, err := connection.Write([]byte("request")); err != nil {
		t.Fatal(err)
	}
	unix := connection.(*net.UnixConn)
	if err := unix.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	response, err := io.ReadAll(connection)
	if err != nil {
		t.Fatal(err)
	}
	if string(response) != "response:request" {
		t.Fatalf("response = %q, want %q", response, "response:request")
	}
}

func TestRelayConnectionDoesNotStarveTheOtherDirectionUnderBackpressure(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	input := make(chan []byte, 1)
	sendStarted := make(chan struct{})
	releaseSend := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- RelayConnection(context.Background(), server, input, func(data []byte) error {
			if len(data) == 0 {
				return nil
			}
			close(sendStarted)
			<-releaseSend
			return nil
		})
	}()

	writeDone := make(chan error, 1)
	go func() {
		_, err := client.Write([]byte("blocked request"))
		writeDone <- err
	}()
	select {
	case <-sendStarted:
	case <-time.After(time.Second):
		t.Fatal("relay did not apply the blocked sender")
	}
	input <- []byte("response while request is blocked")
	buffer := make([]byte, len("response while request is blocked"))
	if _, err := io.ReadFull(client, buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "response while request is blocked" {
		t.Fatalf("response = %q", buffer)
	}
	close(releaseSend)
	close(input)
	_ = client.Close()
	select {
	case <-writeDone:
	case <-time.After(time.Second):
		t.Fatal("blocked request did not finish")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("relay did not stop")
	}
}
