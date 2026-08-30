package backend

import (
	"archive/tar"
	"bytes"
	"testing"
)

func TestIsRootfsTarballScansDockerArchiveMetadata(t *testing.T) {
	rootfs := tarBytes(t, &tar.Header{Name: "etc/hostname"}, []byte("rootfs"))
	if !isRootfsTarball(rootfs) {
		t.Fatal("plain rootfs archive was classified as an image archive")
	}

	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	writeImportTarEntry(t, writer, "layer/layer.tar", "layer")
	writeImportTarEntry(t, writer, "manifest.json", "[]")
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if isRootfsTarball(archive.Bytes()) {
		t.Fatal("Docker save archive with a layer before manifest was classified as rootfs")
	}
}

func writeImportTarEntry(t *testing.T, writer *tar.Writer, name, contents string) {
	t.Helper()
	header := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(contents))}
	if err := writer.WriteHeader(header); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte(contents)); err != nil {
		t.Fatal(err)
	}
}
