package backend

import (
	"archive/tar"
	"bytes"
	"io"
	"testing"
)

func TestParseBuildDockerfileRejectsMultipleStages(t *testing.T) {
	_, err := parseBuildDockerfile([]byte("FROM alpine\nFROM busybox\n"))
	if err == nil {
		t.Fatal("expected multi-stage Dockerfile to remain unsupported")
	}
}

func TestFilterBuildContextAppliesCopyDestination(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{
		"Dockerfile": "FROM alpine\nCOPY app.txt /opt/app.txt\n",
		"app.txt":    "hello from the context\n",
		"ignored":    "must not be copied\n",
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nCOPY app.txt /opt/app.txt\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}

	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["opt/app.txt"]); got != "hello from the context\n" {
		t.Fatalf("copied content = %q, entries = %#v", got, entries)
	}
	if _, ok := entries["ignored"]; ok {
		t.Fatal("unreferenced context file was copied")
	}
}

func TestFilterBuildContextAppliesAddDestination(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{"app.txt": "added content\n"})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nADD app.txt /srv/app.txt\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["srv/app.txt"]); got != "added content\n" {
		t.Fatalf("added content = %q", got)
	}
}

func buildTestTar(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := tar.NewWriter(&buffer)
	for name, contents := range files {
		data := []byte(contents)
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		if _, err := writer.Write(data); err != nil {
			t.Fatalf("write tar data: %v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	return buffer.Bytes()
}

func readTestTar(t *testing.T, data []byte) map[string][]byte {
	t.Helper()
	reader := tar.NewReader(bytes.NewReader(data))
	entries := map[string][]byte{}
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return entries
		}
		if err != nil {
			t.Fatalf("read tar header: %v", err)
		}
		contents, err := io.ReadAll(reader)
		if err != nil {
			t.Fatalf("read tar entry: %v", err)
		}
		entries[header.Name] = contents
	}
}
