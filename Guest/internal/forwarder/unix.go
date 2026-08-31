package forwarder

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const DockerSocketPath = api.DockerSocketRelayPath

const (
	defaultMaximumUnixSessions = 4096
	defaultUnixSessionTimeout  = 5 * time.Second
	maximumUnixRelayChunkSize  = 256 * 1024
)

type SocketAnnouncer func(id string) error

type UnixSocketServer struct {
	path            string
	announce        SocketAnnouncer
	maximumSessions int
	sessionTimeout  time.Duration
	nextID          atomic.Uint64

	mu      sync.Mutex
	pending map[string]*pendingUnixSession
	active  int
}

type pendingUnixSession struct {
	connection net.Conn
	timer      *time.Timer
}

func NewUnixSocketServer(path string, announce SocketAnnouncer) *UnixSocketServer {
	return &UnixSocketServer{
		path:            path,
		announce:        announce,
		maximumSessions: defaultMaximumUnixSessions,
		sessionTimeout:  defaultUnixSessionTimeout,
		pending:         make(map[string]*pendingUnixSession),
	}
}

func (s *UnixSocketServer) Serve(ctx context.Context) error {
	if s.path == "" {
		return errors.New("unix socket path is required")
	}
	if s.announce == nil {
		return errors.New("unix socket announcer is required")
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("create unix socket directory: %w", err)
	}
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale unix socket: %w", err)
	}
	listener, err := net.Listen("unix", s.path)
	if err != nil {
		return fmt.Errorf("listen on unix socket: %w", err)
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(s.path)
	}()
	if err := os.Chmod(s.path, 0o666); err != nil {
		return fmt.Errorf("set unix socket permissions: %w", err)
	}

	go func() {
		<-ctx.Done()
		_ = listener.Close()
		s.closePending()
	}()

	var announceWorkers sync.WaitGroup
	defer announceWorkers.Wait()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if !s.reserveSession() {
			_ = connection.Close()
			continue
		}
		announceWorkers.Add(1)
		go func() {
			defer announceWorkers.Done()
			s.announceConnection(ctx, connection)
		}()
	}
}

func (s *UnixSocketServer) reserveSession() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.maximumSessions > 0 && s.active >= s.maximumSessions {
		return false
	}
	s.active++
	return true
}

func (s *UnixSocketServer) announceConnection(ctx context.Context, connection net.Conn) {
	id := fmt.Sprintf("socket-%d", s.nextID.Add(1))
	if ctx.Err() != nil {
		_ = connection.Close()
		s.releaseSession()
		return
	}
	s.mu.Lock()
	if ctx.Err() != nil {
		s.mu.Unlock()
		_ = connection.Close()
		s.releaseSession()
		return
	}
	session := &pendingUnixSession{connection: connection}
	s.pending[id] = session
	session.timer = time.AfterFunc(s.sessionTimeout, func() { s.Close(id) })
	s.mu.Unlock()
	if err := s.announce(id); err != nil {
		_ = s.Close(id)
	}
}

func (s *UnixSocketServer) releaseSession() {
	s.mu.Lock()
	s.active--
	s.mu.Unlock()
}

// Open claims a guest socket after the daemon has received its socket.open
// event. The returned release function must be called after RelayConnection
// finishes so the concurrent-session limit covers both pending and active
// relays.
func (s *UnixSocketServer) Open(id string) (net.Conn, func(), error) {
	s.mu.Lock()
	session := s.pending[id]
	if session != nil {
		delete(s.pending, id)
	}
	s.mu.Unlock()
	if session == nil {
		return nil, nil, fmt.Errorf("socket session %q was not found", id)
	}
	if !session.timer.Stop() {
		// The timer may have removed and closed the session concurrently. A
		// successful map claim still owns the connection, so do not close it
		// here; the timer only closes sessions it can remove itself.
	}
	var once sync.Once
	release := func() {
		once.Do(func() {
			s.mu.Lock()
			s.active--
			s.mu.Unlock()
		})
	}
	return session.connection, release, nil
}

func (s *UnixSocketServer) Close(id string) error {
	s.mu.Lock()
	session := s.pending[id]
	if session != nil {
		delete(s.pending, id)
		s.active--
	}
	s.mu.Unlock()
	if session == nil {
		return nil
	}
	if !session.timer.Stop() {
		// The callback is already running or has run. Closing the connection is
		// still safe and makes the timeout deterministic for the peer.
	}
	return session.connection.Close()
}

func (s *UnixSocketServer) closePending() {
	s.mu.Lock()
	sessions := make([]*pendingUnixSession, 0, len(s.pending))
	for id, session := range s.pending {
		delete(s.pending, id)
		s.active--
		sessions = append(sessions, session)
	}
	s.mu.Unlock()
	for _, session := range sessions {
		_ = session.timer.Stop()
		_ = session.connection.Close()
	}
}

// RelayConnection copies bytes in both directions. An empty data slice sent
// by send marks guest-to-host EOF; an empty or closed input channel half-closes
// the guest socket's write side. The read and write loops remain independent,
// so a blocked direction cannot starve the other direction.
func RelayConnection(
	ctx context.Context,
	connection net.Conn,
	input <-chan []byte,
	send func([]byte) error,
) error {
	if connection == nil {
		return errors.New("relay connection is nil")
	}
	if send == nil {
		return errors.New("relay sender is nil")
	}
	if input == nil {
		return errors.New("relay input is nil")
	}

	relayCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-relayCtx.Done()
		_ = connection.Close()
	}()

	done := make(chan error, 2)
	go func() { done <- relayToHost(relayCtx, connection, send) }()
	go func() { done <- relayToGuest(relayCtx, connection, input) }()

	var first error
	for range 2 {
		err := <-done
		if err != nil && first == nil {
			first = err
			cancel()
			_ = connection.Close()
		}
	}
	_ = connection.Close()
	if first != nil && ctx.Err() != nil {
		return ctx.Err()
	}
	return first
}

func relayToHost(ctx context.Context, connection net.Conn, send func([]byte) error) error {
	buffer := make([]byte, maximumUnixRelayChunkSize)
	for {
		count, err := connection.Read(buffer)
		if count > 0 {
			data := append([]byte(nil), buffer[:count]...)
			if sendErr := send(data); sendErr != nil {
				return sendErr
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			// A non-nil empty slice encodes as base64 "". The host uses that
			// explicit stream frame to half-close its Unix socket output.
			return send([]byte{})
		}
		return err
	}
}

func relayToGuest(ctx context.Context, connection net.Conn, input <-chan []byte) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case data, ok := <-input:
			if !ok || len(data) == 0 {
				return closeWrite(connection)
			}
			if err := writeAll(connection, data); err != nil {
				return err
			}
		}
	}
}

func closeWrite(connection net.Conn) error {
	if closer, ok := connection.(interface{ CloseWrite() error }); ok {
		return closer.CloseWrite()
	}
	return connection.Close()
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		count, err := writer.Write(data)
		if err != nil {
			return err
		}
		if count <= 0 {
			return io.ErrShortWrite
		}
		data = data[count:]
	}
	return nil
}
