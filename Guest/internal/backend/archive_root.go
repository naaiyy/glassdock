package backend

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/opencontainers/runtime-spec/specs-go"
)

// errContainerPathMustBeAbsolute rejects archive paths that are not
// container-absolute, matching the snapshot-root path resolution contract.
var errContainerPathMustBeAbsolute = errors.New("container path must be an absolute path")

// mountContainerRootWithMounts mounts the container's snapshot root and then
// binds the container's spec mounts (named volumes, host binds) into the view
// so archive reads and writes observe exactly what the container observes.
//
// The plain snapshot-root view cannot serve archive operations that target
// mount points: bind mounts only exist inside the container's mount
// namespace, so extraction into the snapshot root would silently write into
// the container's writable layer instead of the mounted volume.
func (b *Backend) mountContainerRootWithMounts(ctx context.Context, id, prefix string) (string, func(), error) {
	ctx = b.ctx(ctx)
	root, cleanup, err := b.mountContainerRoot(ctx, id, prefix)
	if err != nil {
		return "", nil, err
	}

	binds, err := b.containerBindMounts(ctx, id)
	if err != nil {
		cleanup()
		return "", nil, err
	}

	// Create mountpoints shallowest-first so nested destinations exist, then
	// bind the guest-side sources into the snapshot view.
	sort.Slice(binds, func(i, j int) bool {
		return len(binds[i].Destination) < len(binds[j].Destination)
	})
	for _, bind := range binds {
		destination := filepath.Join(root, filepath.FromSlash(filepath.Clean(bind.Destination)))
		if !pathContains(root, destination) {
			continue
		}
		// Ensure the parent directories exist, then handle the leaf: a
		// directory source needs a destination directory; a file source (for
		// example /etc/hosts) binds over the leaf without creating it.
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("prepare archive mountpoint parent %q: %w", bind.Destination, err)
		}
		if sourceIsDirectory(bind.Source) {
			if _, err := os.Lstat(destination); os.IsNotExist(err) {
				if err := os.MkdirAll(destination, 0o755); err != nil {
					cleanup()
					return "", nil, fmt.Errorf("prepare archive mountpoint %q: %w", bind.Destination, err)
				}
			}
		}
		if err := mountBind(bind.Source, destination, false); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("bind %q into archive view at %q: %w", bind.Source, bind.Destination, err)
		}
		if mountIsReadonly(bind) {
			if err := mountBind(bind.Source, destination, true); err != nil {
				cleanup()
				return "", nil, fmt.Errorf("bind %q into archive view at %q read-only: %w", bind.Source, bind.Destination, err)
			}
		}
	}

	combinedCleanup := func() {
		for _, bind := range binds {
			destination := filepath.Join(root, filepath.FromSlash(filepath.Clean(bind.Destination)))
			if !pathContains(root, destination) {
				continue
			}
			_ = unmountPath(destination)
		}
		cleanup()
	}
	return root, combinedCleanup, nil
}

// containerBindMounts returns the container spec's bind mounts: named volumes
// and host binds, both realized as binds with a guest-side absolute source.
func (b *Backend) containerBindMounts(ctx context.Context, id string) ([]specs.Mount, error) {
	container, err := b.client.LoadContainer(ctx, id)
	if err != nil {
		return nil, err
	}
	spec, err := container.Spec(ctx)
	if err != nil {
		return nil, err
	}
	var binds []specs.Mount
	for _, mount := range spec.Mounts {
		if !isBindLikeMount(mount) || strings.TrimSpace(mount.Source) == "" {
			continue
		}
		if mount.Destination == "" || mount.Destination == "/" {
			continue
		}
		binds = append(binds, mount)
	}
	return binds, nil
}

func isBindLikeMount(mount specs.Mount) bool {
	return mount.Type == "bind" || mount.Type == "volume" || mount.Type == "rbind"
}

func sourceIsDirectory(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return true
	}
	return info.IsDir()
}

func mountIsReadonly(mount specs.Mount) bool {
	for _, option := range mount.Options {
		if option == "ro" {
			return true
		}
	}
	return false
}
