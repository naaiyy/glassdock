package backend

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/glassdock/glassdock/guest/internal/api"
)

const maxLogBytes int64 = 4 << 20

type boundedLogWriter struct {
	mu          sync.Mutex
	file        *os.File
	index       *os.File
	written     int64
	truncated   bool
	nextID      uint64
	subscribers map[uint64]*logSubscriber
}

type logSubscriber struct {
	chunks chan []byte
	stop   chan struct{}
}

func (w *boundedLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	originalLength := len(p)
	live := append([]byte(nil), p...)
	when := time.Now().UTC()
	remaining := maxLogBytes - w.written
	if remaining <= 0 {
		w.truncated = w.truncated || originalLength > 0
		if err := w.writeRecordLocked(when, live); err != nil {
			return 0, err
		}
		w.publishLocked(live)
		return originalLength, nil
	}
	if int64(len(p)) > remaining {
		p = p[:remaining]
		w.truncated = true
	}
	written, err := w.file.Write(p)
	w.written += int64(written)
	if err != nil {
		return written, err
	}
	if err := w.writeRecordLocked(when, live); err != nil {
		return written, err
	}
	w.publishLocked(live)
	// Report the full input as consumed. Once the limit is reached, logs must not
	// apply backpressure to the container process.
	return originalLength, nil
}

func (w *boundedLogWriter) writeRecordLocked(when time.Time, data []byte) error {
	if w.index == nil {
		return nil
	}
	record, err := json.Marshal(logRecord{Time: when, Data: data})
	if err != nil {
		return err
	}
	_, err = w.index.Write(append(record, '\n'))
	return err
}

func (w *boundedLogWriter) publishLocked(data []byte) {
	for id, subscriber := range w.subscribers {
		select {
		case subscriber.chunks <- append([]byte(nil), data...):
		default:
			delete(w.subscribers, id)
			close(subscriber.stop)
		}
	}
}

func (w *boundedLogWriter) subscribe(subscriber func([]byte) error) (func(), error) {
	w.mu.Lock()
	data, err := os.ReadFile(w.file.Name())
	if err != nil {
		w.mu.Unlock()
		return nil, err
	}
	w.nextID++
	id := w.nextID
	if w.subscribers == nil {
		w.subscribers = make(map[uint64]*logSubscriber)
	}
	entry := &logSubscriber{chunks: make(chan []byte, 64), stop: make(chan struct{})}
	if len(data) > 0 {
		entry.chunks <- data
	}
	w.subscribers[id] = entry
	w.mu.Unlock()
	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {
			w.mu.Lock()
			if w.subscribers[id] == entry {
				delete(w.subscribers, id)
				close(entry.stop)
			}
			w.mu.Unlock()
		})
	}
	go func() {
		for {
			select {
			case data := <-entry.chunks:
				if subscriber(data) != nil {
					unsubscribe()
					return
				}
			case <-entry.stop:
				return
			}
		}
	}()
	return unsubscribe, nil
}

type logCapture struct {
	stdout *boundedLogWriter
	stderr *boundedLogWriter
	io     cio.IO
	once   sync.Once
}

func logKey(id string) string {
	digest := sha256.Sum256([]byte(id))
	return hex.EncodeToString(digest[:])
}

func (b *Backend) logPath(id, stream string) string {
	return filepath.Join(b.logsDir, logKey(id)+"."+stream)
}

func (b *Backend) logIndexPath(id, stream string) string {
	return filepath.Join(b.logsDir, logKey(id)+"."+stream+".timestamps")
}

func (b *Backend) createLogCapture(id string) (*logCapture, error) {
	if err := os.MkdirAll(b.logsDir, 0o700); err != nil {
		return nil, err
	}
	open := func(stream string) (*boundedLogWriter, error) {
		file, err := os.OpenFile(b.logPath(id, stream), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
		if err != nil {
			return nil, err
		}
		index, err := os.OpenFile(b.logIndexPath(id, stream), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
		if err != nil {
			_ = file.Close()
			return nil, err
		}
		return &boundedLogWriter{file: file, index: index}, nil
	}
	stdout, err := open("stdout")
	if err != nil {
		return nil, err
	}
	stderr, err := open("stderr")
	if err != nil {
		_ = stdout.file.Close()
		if stdout.index != nil {
			_ = stdout.index.Close()
		}
		_ = os.Remove(b.logPath(id, "stdout"))
		_ = os.Remove(b.logIndexPath(id, "stdout"))
		return nil, err
	}
	return &logCapture{stdout: stdout, stderr: stderr}, nil
}

func (capture *logCapture) close() {
	capture.once.Do(func() {
		if capture.io != nil {
			capture.io.Wait()
			_ = capture.io.Close()
		}
		_ = capture.stdout.file.Close()
		_ = capture.stderr.file.Close()
		if capture.stdout.index != nil {
			_ = capture.stdout.index.Close()
		}
		if capture.stderr.index != nil {
			_ = capture.stderr.index.Close()
		}
	})
}

func (b *Backend) finishLogCapture(id string) {
	value, ok := b.logCaptures.Load(id)
	if !ok {
		return
	}
	value.(*logCapture).close()
}

func (b *Backend) removeLogs(id string) {
	if value, ok := b.logCaptures.LoadAndDelete(id); ok {
		value.(*logCapture).close()
	}
	_ = os.Remove(b.logPath(id, "stdout"))
	_ = os.Remove(b.logPath(id, "stderr"))
	_ = os.Remove(b.logIndexPath(id, "stdout"))
	_ = os.Remove(b.logIndexPath(id, "stderr"))
}

func (b *Backend) Logs(request api.ContainerLogsRequest) (api.ContainerLogsResponse, error) {
	if request.ID == "" {
		return api.ContainerLogsResponse{}, errors.New("id is required")
	}
	if !request.Stdout && !request.Stderr {
		return api.ContainerLogsResponse{}, errors.New("stdout or stderr must be requested")
	}
	response := api.ContainerLogsResponse{}
	read := func(stream string) ([]byte, error) {
		if request.Timestamps || request.Since != 0 || request.Until != 0 {
			return b.readFilteredLog(request.ID, stream, request)
		}
		data, err := os.ReadFile(b.logPath(request.ID, stream))
		if errors.Is(err, os.ErrNotExist) {
			return []byte{}, nil
		}
		return data, err
	}
	var err error
	if request.Stdout {
		response.Stdout, err = read("stdout")
		if err != nil {
			return api.ContainerLogsResponse{}, err
		}
	}
	if request.Stderr {
		response.Stderr, err = read("stderr")
		if err != nil {
			return api.ContainerLogsResponse{}, err
		}
	}
	if value, ok := b.logCaptures.Load(request.ID); ok {
		capture := value.(*logCapture)
		capture.stdout.mu.Lock()
		stdoutTruncated := capture.stdout.truncated
		capture.stdout.mu.Unlock()
		capture.stderr.mu.Lock()
		stderrTruncated := capture.stderr.truncated
		capture.stderr.mu.Unlock()
		response.Truncated = stdoutTruncated || stderrTruncated
	} else {
		for _, data := range [][]byte{response.Stdout, response.Stderr} {
			if int64(len(data)) >= maxLogBytes {
				response.Truncated = true
			}
		}
	}
	return response, nil
}

type logRecord struct {
	Time time.Time `json:"time"`
	Data []byte    `json:"data"`
}

func (b *Backend) readFilteredLog(id, stream string, request api.ContainerLogsRequest) ([]byte, error) {
	file, err := os.Open(b.logIndexPath(id, stream))
	if errors.Is(err, os.ErrNotExist) {
		data, readErr := os.ReadFile(b.logPath(id, stream))
		return data, readErr
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), int(maxLogBytes)+64*1024)
	var output []byte
	for scanner.Scan() {
		var record logRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			return nil, err
		}
		seconds := record.Time.Unix()
		if request.Since != 0 && seconds < request.Since {
			continue
		}
		if request.Until != 0 && seconds >= request.Until {
			continue
		}
		if request.Timestamps {
			output = appendTimestamped(output, record.Time, record.Data)
		} else {
			output = append(output, record.Data...)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return output, nil
}

func appendTimestamped(output []byte, timestamp time.Time, data []byte) []byte {
	const format = "2006-01-02T15:04:05.000000000Z07:00"
	for len(data) > 0 {
		output = append(output, timestamp.Format(format)...)
		output = append(output, ' ')
		newline := bytes.IndexByte(data, '\n')
		if newline < 0 {
			output = append(output, data...)
			break
		}
		output = append(output, data[:newline+1]...)
		data = data[newline+1:]
	}
	return output
}

func (b *Backend) Attach(ctx context.Context, request api.ContainerLogsRequest, stream StreamFunc) (uint32, error) {
	value, ok := b.logCaptures.Load(request.ID)
	for !ok {
		item, err := b.Inspect(ctx, request.ID)
		if err != nil {
			return 0, err
		}
		if item.Status == "exited" || item.Status == "stopped" {
			logs, err := b.Logs(request)
			if err != nil {
				return 0, err
			}
			if request.Stdout && len(logs.Stdout) > 0 {
				if err := stream("stdout", logs.Stdout); err != nil {
					return 0, err
				}
			}
			if request.Stderr && len(logs.Stderr) > 0 {
				if err := stream("stderr", logs.Stderr); err != nil {
					return 0, err
				}
			}
			code, _, err := b.Wait(ctx, request.ID)
			return code, err
		}
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
		value, ok = b.logCaptures.Load(request.ID)
	}
	capture := value.(*logCapture)
	unsubscribers := []func(){}
	defer func() {
		for _, unsubscribe := range unsubscribers {
			unsubscribe()
		}
	}()
	if request.Stdout {
		unsubscribe, err := capture.stdout.subscribe(func(data []byte) error { return stream("stdout", data) })
		if err != nil {
			return 0, err
		}
		unsubscribers = append(unsubscribers, unsubscribe)
	}
	if request.Stderr {
		unsubscribe, err := capture.stderr.subscribe(func(data []byte) error { return stream("stderr", data) })
		if err != nil {
			return 0, err
		}
		unsubscribers = append(unsubscribers, unsubscribe)
	}
	code, _, err := b.Wait(ctx, request.ID)
	return code, err
}

var _ io.Writer = (*boundedLogWriter)(nil)
