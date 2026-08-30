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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/glassdock/glassdock/guest/internal/api"
)

const maxLogBytes int64 = 4 << 20

type boundedLogWriter struct {
	path        string
	indexPath   string
	mu          sync.Mutex
	file        *os.File
	index       *os.File
	written     int64
	truncated   bool
	nextID      uint64
	details     string
	subscribers map[uint64]*logSubscriber
}

type logSubscriber struct {
	chunks  chan []byte
	stop    chan struct{}
	options api.ContainerLogsRequest
}

func (w *boundedLogWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.ensureFilesLocked(); err != nil {
		return 0, err
	}
	originalLength := len(p)
	live := append([]byte(nil), p...)
	when := time.Now().UTC()
	remaining := maxLogBytes - w.written
	if remaining <= 0 {
		w.truncated = w.truncated || originalLength > 0
		if err := w.writeRecordLocked(when, live); err != nil {
			return 0, err
		}
		w.publishLocked(when, live)
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
	w.publishLocked(when, live)
	// Report the full input as consumed. Once the limit is reached, logs must not
	// apply backpressure to the container process.
	return originalLength, nil
}

func (w *boundedLogWriter) ensureFilesLocked() error {
	if w.file != nil {
		return nil
	}
	if w.path == "" || w.indexPath == "" {
		return errors.New("log writer has no file paths")
	}
	if err := os.MkdirAll(filepath.Dir(w.path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	index, err := os.OpenFile(w.indexPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		_ = file.Close()
		return err
	}
	var written int64
	if info, statErr := file.Stat(); statErr == nil {
		written = info.Size()
	}
	w.file = file
	w.index = index
	w.written = written
	w.truncated = written >= maxLogBytes
	return nil
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

func (w *boundedLogWriter) publishLocked(when time.Time, data []byte) {
	for id, subscriber := range w.subscribers {
		filtered := formatLogChunk(when, data, subscriber.options, w.details)
		if len(filtered) == 0 {
			continue
		}
		select {
		case subscriber.chunks <- filtered:
		default:
			delete(w.subscribers, id)
			close(subscriber.stop)
		}
	}
}

func (w *boundedLogWriter) subscribe(
	options api.ContainerLogsRequest, subscriber func([]byte) error,
) (func(), error) {
	w.mu.Lock()
	data, err := w.initialDataLocked(options)
	if err != nil {
		w.mu.Unlock()
		return nil, err
	}
	w.nextID++
	id := w.nextID
	if w.subscribers == nil {
		w.subscribers = make(map[uint64]*logSubscriber)
	}
	entry := &logSubscriber{
		chunks: make(chan []byte, 64), stop: make(chan struct{}), options: options,
	}
	w.subscribers[id] = entry
	w.mu.Unlock()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			w.mu.Lock()
			if w.subscribers[id] == entry {
				delete(w.subscribers, id)
				close(entry.stop)
			}
			w.mu.Unlock()
		})
	}
	initialReplayStarted := make(chan struct{})
	finished := make(chan struct{})
	unsubscribe := func() {
		stop()
		<-finished
	}
	go func() {
		defer close(finished)
		deliver := func(data []byte) bool {
			return subscriber(data) != nil
		}
		drain := func() {
			for {
				select {
				case data := <-entry.chunks:
					if deliver(data) {
						return
					}
				default:
					return
				}
			}
		}
		if len(data) > 0 {
			// Start the replay before selecting on stop. An attach can finish
			// its wait and unsubscribe immediately after this function returns;
			// the initial bytes must not be lost in that race.
			close(initialReplayStarted)
			if deliver(data) {
				stop()
				return
			}
		} else {
			close(initialReplayStarted)
		}
		for {
			select {
			case data := <-entry.chunks:
				if deliver(data) {
					stop()
					return
				}
			case <-entry.stop:
				// unsubscribe can race a final live write. Drain queued data so
				// a fast container does not lose its output when its wait completes.
				drain()
				return
			}
		}
	}()
	<-initialReplayStarted
	return unsubscribe, nil
}

func (w *boundedLogWriter) initialDataLocked(options api.ContainerLogsRequest) ([]byte, error) {
	if w.file == nil {
		return []byte{}, nil
	}
	if options.Timestamps || options.Since != 0 || options.Until != 0 {
		if w.index != nil {
			data, err := readFilteredRecords(w.index.Name(), options, w.details)
			if err == nil {
				if options.Tail != nil {
					return tailLog(data, *options.Tail), nil
				}
				return data, nil
			}
			if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
		}
	}
	data, err := os.ReadFile(w.file.Name())
	if err != nil {
		return nil, err
	}
	if options.Tail != nil {
		data = tailLog(data, *options.Tail)
	}
	if options.Details {
		data = prependDetails(data, w.details)
	}
	return data, nil
}

type logCapture struct {
	stdout *boundedLogWriter
	stderr *boundedLogWriter
	io     cio.IO
	once   sync.Once
	done   chan struct{}
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
	open := func(stream string) *boundedLogWriter {
		return &boundedLogWriter{
			path:      b.logPath(id, stream),
			indexPath: b.logIndexPath(id, stream),
		}
	}
	stdout := open("stdout")
	stderr := open("stderr")
	if container, err := b.client.LoadContainer(b.ctx(context.Background()), id); err == nil {
		if labels, err := container.Labels(b.ctx(context.Background())); err == nil {
			prefix := detailsPrefix(labels)
			stdout.details = prefix
			stderr.details = prefix
		}
	}
	return &logCapture{stdout: stdout, stderr: stderr, done: make(chan struct{})}, nil
}

func (capture *logCapture) close() {
	capture.once.Do(func() {
		defer close(capture.done)
		if capture.io != nil {
			capture.io.Wait()
			_ = capture.io.Close()
		}
		if capture.stdout.file != nil {
			_ = capture.stdout.file.Close()
		}
		if capture.stderr.file != nil {
			_ = capture.stderr.file.Close()
		}
		if capture.stdout.index != nil {
			_ = capture.stdout.index.Close()
		}
		if capture.stderr.index != nil {
			_ = capture.stderr.index.Close()
		}
	})
}

func (capture *logCapture) wait(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-capture.done:
		return nil
	}
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
	details := ""
	if request.Details {
		details = b.detailsPrefix(request.ID)
	}
	read := func(stream string) ([]byte, error) {
		if request.Timestamps || request.Since != 0 || request.Until != 0 {
			return b.readFilteredLog(request.ID, stream, request, details)
		}
		data, err := os.ReadFile(b.logPath(request.ID, stream))
		if errors.Is(err, os.ErrNotExist) {
			return []byte{}, nil
		}
		if err != nil {
			return nil, err
		}
		if request.Details {
			data = prependDetails(data, details)
		}
		return data, nil
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
	if request.Tail != nil {
		response.Stdout = tailLog(response.Stdout, *request.Tail)
		response.Stderr = tailLog(response.Stderr, *request.Tail)
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

func (b *Backend) readFilteredLog(id, stream string, request api.ContainerLogsRequest, details ...string) ([]byte, error) {
	data, err := readFilteredRecords(b.logIndexPath(id, stream), request, details...)
	if errors.Is(err, os.ErrNotExist) {
		data, readErr := os.ReadFile(b.logPath(id, stream))
		if errors.Is(readErr, os.ErrNotExist) {
			return []byte{}, nil
		}
		if readErr != nil {
			return nil, readErr
		}
		if request.Details {
			data = prependDetails(data, firstString(details))
		}
		return data, nil
	}
	return data, err
}

func readFilteredRecords(path string, request api.ContainerLogsRequest, details ...string) ([]byte, error) {
	file, err := os.Open(path)
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
			output = appendTimestamped(output, record.Time, record.Data, firstString(details))
		} else {
			if request.Details {
				output = append(output, prependDetails(record.Data, firstString(details))...)
			} else {
				output = append(output, record.Data...)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return output, nil
}

func formatLogChunk(when time.Time, data []byte, request api.ContainerLogsRequest, details ...string) []byte {
	seconds := when.Unix()
	if request.Since != 0 && seconds < request.Since {
		return nil
	}
	if request.Until != 0 && seconds >= request.Until {
		return nil
	}
	if request.Timestamps {
		return appendTimestamped(nil, when, data, firstString(details))
	}
	if request.Details {
		return prependDetails(data, firstString(details))
	}
	return append([]byte(nil), data...)
}

func tailLog(data []byte, count int) []byte {
	if count <= 0 {
		return nil
	}
	hasTrailingNewline := len(data) > 0 && data[len(data)-1] == '\n'
	lines := bytes.Split(data, []byte{'\n'})
	if hasTrailingNewline {
		lines = lines[:len(lines)-1]
	}
	if len(lines) <= count {
		return data
	}
	result := bytes.Join(lines[len(lines)-count:], []byte{'\n'})
	if hasTrailingNewline {
		result = append(result, '\n')
	}
	return result
}

func attachReplayRequest(request api.ContainerLogsRequest) api.ContainerLogsRequest {
	request.Logs = true
	request.Tail = nil
	return request
}

func appendTimestamped(output []byte, timestamp time.Time, data []byte, details ...string) []byte {
	const format = "2006-01-02T15:04:05.000000000Z07:00"
	prefix := firstString(details)
	for len(data) > 0 {
		output = append(output, timestamp.Format(format)...)
		output = append(output, ' ')
		output = append(output, prefix...)
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

func firstString(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func prependDetails(data []byte, prefix string) []byte {
	if prefix == "" || len(data) == 0 {
		return append([]byte(nil), data...)
	}
	var output []byte
	for len(data) > 0 {
		output = append(output, prefix...)
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

func detailsPrefix(labels map[string]string) string {
	keys := make([]string, 0, len(labels))
	for key := range labels {
		if strings.HasPrefix(key, "com.glassdock.") {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var output strings.Builder
	for _, key := range keys {
		output.WriteString(key)
		output.WriteByte('=')
		output.WriteString(labels[key])
		output.WriteByte(' ')
	}
	return output.String()
}

func (b *Backend) detailsPrefix(id string) string {
	container, err := b.client.LoadContainer(b.ctx(context.Background()), id)
	if err != nil {
		return ""
	}
	labels, err := container.Labels(b.ctx(context.Background()))
	if err != nil {
		return ""
	}
	return detailsPrefix(labels)
}

func (b *Backend) Attach(ctx context.Context, request api.ContainerLogsRequest, stream StreamFunc) (uint32, error) {
	b.beginAttach(request.ID)
	attachReady := false
	defer func() {
		if !attachReady {
			b.completeAttach(request.ID)
		}
	}()
	value, ok := b.logCaptures.Load(request.ID)
	for !ok {
		item, err := b.Inspect(ctx, request.ID)
		if err != nil {
			return 0, err
		}
		if item.Status == "exited" || item.Status == "stopped" {
			logsRequest := request
			if !request.Logs {
				// The process may have exited before the attach request reached
				// the guest. In that case there is no live subscriber, so recover
				// the captured bytes instead of applying live-only tail=0.
				logsRequest = attachReplayRequest(request)
			}
			logs, err := b.Logs(logsRequest)
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
	stdoutDelivered := false
	stderrDelivered := false
	unsubscribeAll := func() {
		for _, unsubscribe := range unsubscribers {
			unsubscribe()
		}
		unsubscribers = nil
	}
	defer func() {
		unsubscribeAll()
	}()
	if request.Stdout {
		unsubscribe, err := capture.stdout.subscribe(
			request, func(data []byte) error {
				if err := stream("stdout", data); err != nil {
					return err
				}
				stdoutDelivered = true
				return nil
			},
		)
		if err != nil {
			return 0, err
		}
		unsubscribers = append(unsubscribers, unsubscribe)
	}
	if request.Stderr {
		unsubscribe, err := capture.stderr.subscribe(
			request, func(data []byte) error {
				if err := stream("stderr", data); err != nil {
					return err
				}
				stderrDelivered = true
				return nil
			},
		)
		if err != nil {
			return 0, err
		}
		unsubscribers = append(unsubscribers, unsubscribe)
	}
	b.completeAttach(request.ID)
	attachReady = true
	code, _, err := b.Wait(ctx, request.ID)
	if err != nil {
		return code, err
	}
	if err := capture.wait(ctx); err != nil {
		return code, err
	}
	// Docker starts the process and establishes attach on separate client
	// connections. If a short-lived process exits before the live-only
	// subscriber is registered, tail=0 intentionally suppresses the initial
	// replay and the live frame is otherwise lost. Drain the subscribers first,
	// then replay the captured bytes only for streams that delivered no frame.
	unsubscribeAll()
	if !request.Logs && ((!stdoutDelivered && request.Stdout) || (!stderrDelivered && request.Stderr)) {
		logs, err := b.Logs(attachReplayRequest(request))
		if err != nil {
			return code, err
		}
		if request.Stdout && !stdoutDelivered && len(logs.Stdout) > 0 {
			if err := stream("stdout", logs.Stdout); err != nil {
				return code, err
			}
		}
		if request.Stderr && !stderrDelivered && len(logs.Stderr) > 0 {
			if err := stream("stderr", logs.Stderr); err != nil {
				return code, err
			}
		}
	}
	return code, nil
}

var _ io.Writer = (*boundedLogWriter)(nil)
