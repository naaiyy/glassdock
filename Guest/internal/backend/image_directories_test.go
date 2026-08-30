package backend

import (
	"archive/tar"
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestPrepareImageDirectoriesDefersVolumeRepair(t *testing.T) {
	var backend Backend
	prepared, err := backend.prepareImageDirectories(
		context.Background(), "container", nil, map[string]struct{}{"/var/cache/nginx": {}},
	)
	if err != nil {
		t.Fatalf("prepare image directories: %v", err)
	}
	if prepared {
		t.Fatal("volume image directories were prepared during create")
	}
}

func TestImageDirectoriesWithChildrenUsesFinalPaths(t *testing.T) {
	state := map[string]imagePathState{
		"var":                    {directory: true},
		"var/cache":              {directory: true},
		"var/cache/nginx":        {directory: true},
		"var/cache/nginx/client": {directory: true},
		"tmp":                    {directory: true},
		"tmp/file":               {},
	}

	withChildren := imageDirectoriesWithChildren(state)
	for _, directory := range []string{"var", "var/cache", "var/cache/nginx", "tmp"} {
		if _, ok := withChildren[directory]; !ok {
			t.Fatalf("directory %q was not marked as containing a descendant", directory)
		}
	}
	if _, ok := withChildren["var/cache/nginx/client"]; ok {
		t.Fatal("leaf directory was incorrectly marked as containing a descendant")
	}
}

func TestAddImageVolumeDirectoriesAddsMissingParents(t *testing.T) {
	directories := []imageDirectory{
		{path: "etc", mode: 0o755, empty: true},
		{path: "var", mode: 0o755},
	}
	got := addImageVolumeDirectories(directories, map[string]struct{}{
		"/var/lib/postgresql/data": {},
		"/":                        {},
		"relative":                 {},
	})

	if len(got) != 5 {
		t.Fatalf("directory count = %d, want 5: %#v", len(got), got)
	}
	byPath := make(map[string]imageDirectory, len(got))
	for _, directory := range got {
		byPath[directory.path] = directory
	}
	for _, directory := range []string{"var", "var/lib", "var/lib/postgresql", "var/lib/postgresql/data"} {
		entry, ok := byPath[directory]
		if !ok {
			t.Fatalf("missing volume directory %q in %#v", directory, got)
		}
		if entry.mode != 0o755 || (directory != "var" && !entry.empty) {
			t.Fatalf("volume directory %q = %#v", directory, entry)
		}
	}
}

func TestImageVolumeDirectoriesSelectsOnlyVolumeAncestors(t *testing.T) {
	directories := []imageDirectory{
		{path: "etc", mode: 0o755, empty: true},
		{path: "var", mode: 0o755},
		{path: "var/cache", mode: 0o755, empty: true},
		{path: "var/cache/nginx", mode: 0o755, empty: true},
		{path: "opt", mode: 0o755, empty: true},
	}

	got := imageVolumeDirectories(directories, map[string]struct{}{"/var/cache/nginx": {}})
	if len(got) != 3 {
		t.Fatalf("directory count = %d, want 3: %#v", len(got), got)
	}
	for _, directory := range got {
		if directory.path == "etc" || directory.path == "opt" {
			t.Fatalf("unrelated directory was selected: %#v", got)
		}
	}
}

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
