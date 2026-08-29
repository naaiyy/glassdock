package backend

import (
	"archive/tar"
	"os"
	"path/filepath"
	"testing"
)

func TestImageDirectoryStateAppliesLayerWhiteouts(t *testing.T) {
	state := make(map[string]imagePathState)
	firstLayer := []*tar.Header{
		{Name: "var/cache/nginx/", Typeflag: tar.TypeDir, Mode: 0o755},
		{Name: "var/cache/nginx/client_temp/", Typeflag: tar.TypeDir, Mode: 0o700},
		{Name: "var/cache/nginx/proxy_temp/", Typeflag: tar.TypeDir, Mode: 0o700},
		{Name: "var/cache/nginx/client_temp/marker", Mode: 0o644},
	}
	for _, header := range firstLayer {
		if err := applyImageLayerHeader(state, header); err != nil {
			t.Fatalf("apply first-layer header %q: %v", header.Name, err)
		}
	}
	secondLayer := []*tar.Header{
		{Name: "var/cache/nginx/.wh.client_temp", Mode: 0o000},
		{Name: "var/cache/nginx/.wh..wh..opq", Mode: 0o000},
	}
	for _, header := range secondLayer {
		if err := applyImageLayerHeader(state, header); err != nil {
			t.Fatalf("apply second-layer header %q: %v", header.Name, err)
		}
	}

	if _, ok := state["var/cache/nginx"]; !ok || !state["var/cache/nginx"].directory {
		t.Fatal("opaque whiteout removed the directory itself")
	}
	if _, ok := state["var/cache/nginx/client_temp"]; ok {
		t.Fatal("regular whiteout did not remove the directory subtree")
	}
	if _, ok := state["var/cache/nginx/proxy_temp"]; ok {
		t.Fatal("opaque whiteout did not remove lower-layer children")
	}
}

func TestImageDirectoryStateAddsImplicitParentsAndReplacesFiles(t *testing.T) {
	state := make(map[string]imagePathState)
	entries := []*tar.Header{
		{Name: "opt", Mode: 0o644},
		{Name: "opt/app/data.txt", Mode: 0o644},
	}
	for _, header := range entries {
		if err := applyImageLayerHeader(state, header); err != nil {
			t.Fatalf("apply header %q: %v", header.Name, err)
		}
	}
	for _, directory := range []string{"opt", "opt/app"} {
		entry, ok := state[directory]
		if !ok || !entry.directory {
			t.Fatalf("state[%q] = %#v, want directory", directory, entry)
		}
	}
	if entry := state["opt"]; !entry.directory || entry.mode != 0o755 {
		t.Fatalf("implicit replacement of opt = %#v", entry)
	}
	if entry := state["opt/app/data.txt"]; entry.directory {
		t.Fatal("file was recorded as a directory")
	}
}

func TestForceImageDirectoryCopyUpLeavesDirectoryEmpty(t *testing.T) {
	directory := t.TempDir()
	child := filepath.Join(directory, "image-dir")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatalf("create directory: %v", err)
	}
	if err := forceImageDirectoryCopyUp(child); err != nil {
		t.Fatalf("force directory copy-up: %v", err)
	}
	entries, err := os.ReadDir(child)
	if err != nil {
		t.Fatalf("read directory: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("directory entries = %#v, want empty", entries)
	}
}

func TestImageDirectoryTargetSkipsSymlinkAncestors(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "redirect")); err != nil {
		t.Fatalf("create symlink: %v", err)
	}
	target, safe, err := imageDirectoryTarget(root, "redirect/child")
	if err != nil {
		t.Fatalf("resolve image directory target: %v", err)
	}
	if safe {
		t.Fatalf("image directory target %q unexpectedly followed a symlink", target)
	}
	if _, err := os.Stat(filepath.Join(outside, "child")); !os.IsNotExist(err) {
		t.Fatalf("outside path was modified: %v", err)
	}
}
