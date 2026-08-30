package backend

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

func TestAttachBarrierWaitsForPreparedAttach(t *testing.T) {
	t.Parallel()
	backend := &Backend{}
	backend.PrepareAttach("demo")

	started := make(chan struct{})
	go func() {
		if err := backend.waitForAttach(context.Background(), "demo"); err != nil {
			t.Errorf("waitForAttach() error = %v", err)
			return
		}
		close(started)
	}()

	select {
	case <-started:
		t.Fatal("start barrier completed before attach became ready")
	case <-time.After(20 * time.Millisecond):
	}

	backend.completeAttach("demo")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("start barrier did not complete after attach became ready")
	}
}

func TestBoundedLogWriterConsumesWithoutExceedingLimit(t *testing.T) {
	t.Parallel()
	file, err := os.CreateTemp(t.TempDir(), "log")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	input := bytes.Repeat([]byte("x"), int(maxLogBytes)+17)
	written, err := writer.Write(input)
	if err != nil {
		t.Fatal(err)
	}
	if written != len(input) {
		t.Fatalf("reported %d bytes consumed, want %d", written, len(input))
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != maxLogBytes || !writer.truncated {
		t.Fatalf("size=%d truncated=%v", info.Size(), writer.truncated)
	}
}

func TestBoundedLogWriterCreatesFilesOnFirstWrite(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "stdout")
	indexPath := filepath.Join(directory, "stdout.timestamps")
	writer := &boundedLogWriter{path: path, indexPath: indexPath}

	if _, err := writer.Write(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("log file exists before output: %v", err)
	}
	if _, err := os.Stat(indexPath); !os.IsNotExist(err) {
		t.Fatalf("timestamp file exists before output: %v", err)
	}

	if _, err := writer.Write([]byte("output\n")); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "output\n" {
		t.Fatalf("log data=%q err=%v", data, err)
	}
	if _, err := os.Stat(indexPath); err != nil {
		t.Fatalf("timestamp file was not created: %v", err)
	}
	_ = writer.file.Close()
	_ = writer.index.Close()
}

func TestLiveAttachReplayRecoversOutputWrittenBeforeSubscribe(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	if _, err := writer.Write([]byte("fast-output")); err != nil {
		t.Fatal(err)
	}
	tail := 0
	liveRequest := api.ContainerLogsRequest{Stdout: true, Tail: &tail}
	live, err := writer.initialDataLocked(liveRequest)
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 0 {
		t.Fatalf("live-only attach replayed %q", live)
	}
	replay, err := writer.initialDataLocked(attachReplayRequest(liveRequest))
	if err != nil {
		t.Fatal(err)
	}
	if string(replay) != "fast-output" {
		t.Fatalf("fallback replay=%q", replay)
	}
}

func TestLogsReturnsSelectedStreams(t *testing.T) {
	t.Parallel()
	backend := &Backend{logsDir: t.TempDir()}
	id := "container/with/unsafe/path"
	if err := os.WriteFile(backend.logPath(id, "stdout"), []byte("out"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backend.logPath(id, "stderr"), []byte("err"), 0o600); err != nil {
		t.Fatal(err)
	}
	response, err := backend.Logs(api.ContainerLogsRequest{ID: id, Stdout: true})
	if err != nil {
		t.Fatal(err)
	}
	if string(response.Stdout) != "out" || response.Stderr != nil {
		t.Fatalf("unexpected response: %#v", response)
	}
}

func TestLogsRequiresASelectedStream(t *testing.T) {
	t.Parallel()
	backend := &Backend{logsDir: t.TempDir()}
	if _, err := backend.Logs(api.ContainerLogsRequest{ID: "demo"}); err == nil {
		t.Fatal("expected stream selection error")
	}
}

func TestBoundedLogSubscriberReceivesExistingAndLiveBytes(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	if _, err := writer.Write([]byte("before")); err != nil {
		t.Fatal(err)
	}
	var received []byte
	var receivedMu sync.Mutex
	complete := make(chan struct{})
	unsubscribe, err := writer.subscribe(api.ContainerLogsRequest{Stdout: true}, func(data []byte) error {
		receivedMu.Lock()
		received = append(received, data...)
		if string(received) == "before-after" {
			select {
			case <-complete:
			default:
				close(complete)
			}
		}
		receivedMu.Unlock()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("-after")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-complete:
	case <-time.After(time.Second):
		t.Fatal("subscriber did not receive live output")
	}
	unsubscribe()
	if _, err := writer.Write([]byte("-ignored")); err != nil {
		t.Fatal(err)
	}
	receivedMu.Lock()
	defer receivedMu.Unlock()
	if string(received) != "before-after" {
		t.Fatalf("received %q", received)
	}
}

func TestBoundedLogSubscriberDeliversReplayBeforeImmediateUnsubscribe(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	if _, err := writer.Write([]byte("replay")); err != nil {
		t.Fatal(err)
	}
	received := make(chan string, 1)
	unsubscribe, err := writer.subscribe(api.ContainerLogsRequest{Stdout: true}, func(data []byte) error {
		received <- string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	unsubscribe()
	select {
	case got := <-received:
		if got != "replay" {
			t.Fatalf("received %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("subscriber lost replay data when unsubscribed immediately")
	}
}

func TestSlowLogSubscriberDoesNotBlockContainerOutput(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	release := make(chan struct{})
	_, err = writer.subscribe(api.ContainerLogsRequest{Stdout: true}, func([]byte) error {
		<-release
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 100 {
			_, _ = writer.Write([]byte("output"))
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("slow attach subscriber blocked log capture")
	}
	close(release)
}

func TestLiveLogStreamContinuesAfterRetentionLimit(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file, written: maxLogBytes}
	received := make(chan string, 1)
	_, err = writer.subscribe(api.ContainerLogsRequest{Stdout: true}, func(data []byte) error {
		received <- string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("live")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if got != "live" {
			t.Fatalf("got %q, want live", got)
		}
	case <-time.After(time.Second):
		t.Fatal("live output stopped at the retention limit")
	}
}

func TestLiveLogSubscriberAppliesTimestampOptions(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	file, err := os.Create(filepath.Join(directory, "stdout"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	index, err := os.Create(filepath.Join(directory, "stdout.timestamps"))
	if err != nil {
		t.Fatal(err)
	}
	defer index.Close()
	writer := &boundedLogWriter{file: file, index: index}
	received := make(chan string, 1)
	_, err = writer.subscribe(api.ContainerLogsRequest{Stdout: true, Timestamps: true}, func(data []byte) error {
		received <- string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("live\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !strings.HasSuffix(got, " live\n") || !strings.Contains(got, "T") {
			t.Fatalf("timestamped live output = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("subscriber did not receive timestamped live output")
	}
}

func TestFormatLogChunkHonorsTimeWindow(t *testing.T) {
	t.Parallel()
	when := time.Unix(20, 0).UTC()
	request := api.ContainerLogsRequest{Since: 20, Until: 21}
	if got := formatLogChunk(when, []byte("included\n"), request); string(got) != "included\n" {
		t.Fatalf("included chunk = %q", got)
	}
	if got := formatLogChunk(time.Unix(19, 0), []byte("old\n"), request); got != nil {
		t.Fatalf("old chunk = %q, want nil", got)
	}
	if got := formatLogChunk(time.Unix(21, 0), []byte("new\n"), request); got != nil {
		t.Fatalf("until chunk = %q, want nil", got)
	}
}

func TestTailLogKeepsTheFinalLines(t *testing.T) {
	t.Parallel()
	if got := string(tailLog([]byte("one\ntwo\nthree\n"), 2)); got != "two\nthree\n" {
		t.Fatalf("tail = %q", got)
	}
	if got := string(tailLog([]byte("one\ntwo\n"), 0)); got != "" {
		t.Fatalf("zero tail = %q", got)
	}
	if got := string(tailLog([]byte("one\ntwo"), 1)); got != "two" {
		t.Fatalf("tail without newline = %q", got)
	}
}

func TestAppendTimestampedPrefixesEachLogLine(t *testing.T) {
	t.Parallel()
	when := time.Date(2026, 8, 17, 12, 34, 56, 123456789, time.UTC)
	got := string(appendTimestamped(nil, when, []byte("one\ntwo\n")))
	want := "2026-08-17T12:34:56.123456789Z one\n2026-08-17T12:34:56.123456789Z two\n"
	if got != want {
		t.Fatalf("timestamped output = %q, want %q", got, want)
	}
}

func TestReadFilteredLogUsesTimestampSidecar(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	backend := &Backend{logsDir: directory}
	indexPath := filepath.Join(directory, logKey("container")+".stdout.timestamps")
	index, err := os.Create(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	write := func(record logRecord) {
		t.Helper()
		writer := &boundedLogWriter{index: index}
		if err := writer.writeRecordLocked(record.Time, record.Data); err != nil {
			t.Fatal(err)
		}
	}
	write(logRecord{Time: time.Unix(10, 0).UTC(), Data: []byte("old\n")})
	write(logRecord{Time: time.Unix(20, 0).UTC(), Data: []byte("new\n")})
	if err := index.Close(); err != nil {
		t.Fatal(err)
	}

	data, err := backend.readFilteredLog("container", "stdout", api.ContainerLogsRequest{
		Timestamps: true,
		Since:      15,
		Until:      25,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "new\n") || strings.Contains(string(data), "old\n") {
		t.Fatalf("filtered log = %q", data)
	}
}
