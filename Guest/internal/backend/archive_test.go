package backend

import (
	"archive/tar"
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestValidateNoOverwriteDirNonDirRejectsDirectoryToFile(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "existing"), 0o755); err != nil {
		t.Fatal(err)
	}

	archive := tarBytes(t, &tar.Header{Name: "existing", Mode: 0o644, Size: 1}, []byte("x"))
	if err := validateNoOverwriteDirNonDir(root, archive); err == nil {
		t.Fatal("expected directory-to-file replacement to be rejected")
	}
}

func TestValidateNoOverwriteDirNonDirRejectsFileToDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "existing"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	archive := tarBytes(t, &tar.Header{Name: "existing/", Typeflag: tar.TypeDir, Mode: 0o755}, nil)
	if err := validateNoOverwriteDirNonDir(root, archive); err == nil {
		t.Fatal("expected file-to-directory replacement to be rejected")
	}
}

func TestValidateNoOverwriteDirNonDirRejectsNonDirectoryAncestor(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "existing"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	archive := tarBytes(t, &tar.Header{Name: "existing/child", Mode: 0o644, Size: 1}, []byte("x"))
	if err := validateNoOverwriteDirNonDir(root, archive); err == nil {
		t.Fatal("expected non-directory ancestor to be rejected")
	}
}

func TestValidateNoOverwriteDirNonDirAllowsMatchingTypes(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "directory"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "file"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	var data bytes.Buffer
	writer := tar.NewWriter(&data)
	if err := writer.WriteHeader(&tar.Header{Name: "directory/", Typeflag: tar.TypeDir, Mode: 0o755}); err != nil {
		t.Fatal(err)
	}
	if err := writer.WriteHeader(&tar.Header{Name: "file", Mode: 0o644, Size: 3}); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("new")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	if err := validateNoOverwriteDirNonDir(root, data.Bytes()); err != nil {
		t.Fatalf("matching file types should be allowed: %v", err)
	}
}

func TestWriteArchivePathUsesBasenameForContainerPath(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tmp", "fixture")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("archive"), 0o644); err != nil {
		t.Fatal(err)
	}

	var data bytes.Buffer
	if err := writeArchivePath(context.Background(), path, "tmp/fixture", &data); err != nil {
		t.Fatal(err)
	}
	reader := tar.NewReader(&data)
	header, err := reader.Next()
	if err != nil {
		t.Fatal(err)
	}
	if header.Name != "fixture" {
		t.Fatalf("archive root name = %q, want %q", header.Name, "fixture")
	}
}

func tarBytes(t *testing.T, header *tar.Header, body []byte) []byte {
	t.Helper()
	var data bytes.Buffer
	writer := tar.NewWriter(&data)
	header.Size = int64(len(body))
	if header.Typeflag == tar.TypeDir {
		header.Size = 0
	}
	if err := writer.WriteHeader(header); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}
