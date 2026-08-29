package backend

import (
	"archive/tar"
	"context"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	containerimages "github.com/containerd/containerd/v2/core/images"
	containercompression "github.com/containerd/containerd/v2/pkg/archive/compression"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"
)

// imageDirectory records a directory that should exist in the merged image
// root. Some guest overlayfs mounts lose empty directory entries while
// unpacking lower layers, so the entry is materialized in the writable upper
// layer before the container process starts.
type imageDirectory struct {
	path    string
	mode    int64
	modTime time.Time
	empty   bool
}

type imagePathState struct {
	directory bool
	mode      int64
	modTime   time.Time
}

func (b *Backend) materializeImageDirectories(ctx context.Context, id string, image containerd.Image) error {
	directories, err := b.imageDirectories(ctx, image)
	if err != nil {
		return err
	}
	if len(directories) == 0 {
		return nil
	}

	root, cleanup, err := b.mountContainerRoot(ctx, id, "glassdock-image-dirs-")
	if err != nil {
		return err
	}
	defer cleanup()

	toRepair := make([]imageDirectory, 0)
	for _, directory := range directories {
		target, safe, err := imageDirectoryTarget(root, directory.path)
		if err != nil {
			return fmt.Errorf("resolve image directory %q: %w", directory.path, err)
		}
		if !safe {
			continue
		}
		info, err := os.Lstat(target)
		if err == nil {
			if !info.IsDir() {
				return fmt.Errorf("image path %q is not a directory", directory.path)
			}
			if directory.empty {
				toRepair = append(toRepair, directory)
			}
			continue
		}
		if !os.IsNotExist(err) {
			return fmt.Errorf("inspect image directory %q: %w", directory.path, err)
		}
		toRepair = append(toRepair, directory)
	}
	if len(toRepair) == 0 {
		return nil
	}

	for _, directory := range toRepair {
		target := filepath.Join(root, filepath.FromSlash(directory.path))
		mode := os.FileMode(directory.mode)
		if mode == 0 {
			mode = 0o755
		}
		if err := os.MkdirAll(target, mode.Perm()); err != nil {
			return fmt.Errorf("create image directory %q: %w", directory.path, err)
		}
		if err := os.Chmod(target, mode.Perm()); err != nil {
			return fmt.Errorf("set image directory mode %q: %w", directory.path, err)
		}
		if err := forceImageDirectoryCopyUp(target); err != nil {
			return fmt.Errorf("copy up image directory %q: %w", directory.path, err)
		}
	}
	return nil
}

func imageDirectoryTarget(root, relative string) (string, bool, error) {
	relativePath := filepath.FromSlash(relative)
	if filepath.IsAbs(relativePath) {
		return "", false, fmt.Errorf("image directory path %q is absolute", relative)
	}
	target := filepath.Join(root, relativePath)
	current := root
	for _, component := range strings.Split(relativePath, string(filepath.Separator)) {
		if component == "" || component == "." {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			return target, true, nil
		}
		if err != nil {
			return "", false, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			// The image already controls this path through a symlink. Do not
			// follow it while repairing a different layer entry.
			return target, false, nil
		}
		if !info.IsDir() {
			return target, true, nil
		}
	}
	return target, true, nil
}

// forceImageDirectoryCopyUp makes the new directory an upper-layer entry.
// Overlayfs may report a newly created child directory through a lower-layer
// parent but still reject the first nested mkdir with ENOENT. A temporary file
// forces the directory inode into the writable upper layer; removing the file
// leaves the image contents unchanged.
func forceImageDirectoryCopyUp(directory string) error {
	temporary, err := os.CreateTemp(directory, ".glassdock-copyup-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	closeErr := temporary.Close()
	removeErr := os.Remove(temporaryPath)
	if closeErr != nil {
		return closeErr
	}
	return removeErr
}

func (b *Backend) imageDirectories(ctx context.Context, image containerd.Image) ([]imageDirectory, error) {
	target := image.Target()
	if containerimages.IsIndexType(target.MediaType) {
		var err error
		target, err = selectPlatformManifest(ctx, image.ContentStore(), target)
		if err != nil {
			return nil, err
		}
	}
	cacheKey := target.Digest.String()
	if cached, ok := b.imageDirectoryCache.Load(cacheKey); ok {
		return cached.([]imageDirectory), nil
	}

	manifest, err := containerimages.Manifest(ctx, image.ContentStore(), target, nil)
	if err != nil {
		return nil, fmt.Errorf("read image manifest %s: %w", target.Digest, err)
	}
	directories, err := collectImageDirectories(ctx, image.ContentStore(), manifest.Layers)
	if err != nil {
		return nil, fmt.Errorf("read image layer directories: %w", err)
	}
	b.imageDirectoryCache.LoadOrStore(cacheKey, directories)
	return directories, nil
}

func collectImageDirectories(
	ctx context.Context, provider content.Provider, layers []imagespec.Descriptor,
) ([]imageDirectory, error) {
	state := make(map[string]imagePathState)
	for _, layer := range layers {
		readerAt, err := provider.ReaderAt(ctx, layer)
		if err != nil {
			return nil, err
		}
		stream, err := containercompression.DecompressStream(content.NewReader(readerAt))
		if err != nil {
			_ = readerAt.Close()
			return nil, err
		}
		readErr := applyImageLayerDirectories(stream, state)
		streamErr := stream.Close()
		readerErr := readerAt.Close()
		if readErr != nil {
			return nil, readErr
		}
		if streamErr != nil {
			return nil, streamErr
		}
		if readerErr != nil {
			return nil, readerErr
		}
	}

	directories := make([]imageDirectory, 0, len(state))
	for directoryPath, entry := range state {
		if !entry.directory {
			continue
		}
		mode := entry.mode
		if mode == 0 {
			mode = 0o755
		}
		empty := true
		for candidate := range state {
			if strings.HasPrefix(candidate, directoryPath+"/") {
				empty = false
				break
			}
		}
		directories = append(directories, imageDirectory{
			path: directoryPath, mode: mode, modTime: entry.modTime, empty: empty,
		})
	}
	sort.Slice(directories, func(i, j int) bool {
		return directories[i].path < directories[j].path
	})
	return directories, nil
}

func applyImageLayerDirectories(reader io.Reader, state map[string]imagePathState) error {
	tarReader := tar.NewReader(reader)
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := applyImageLayerHeader(state, header); err != nil {
			return err
		}
	}
}

func applyImageLayerHeader(state map[string]imagePathState, header *tar.Header) error {
	relative, err := archiveMemberPath(header.Name)
	if err != nil {
		return err
	}
	if relative == "." {
		return nil
	}
	directoryPath := path.Dir(relative)
	if directoryPath == "." {
		directoryPath = ""
	}
	base := path.Base(relative)
	if strings.HasPrefix(base, ".wh.") {
		if base == ".wh..wh..opq" {
			deleteImageDirectoryChildren(state, directoryPath)
			return nil
		}
		deleteImagePath(state, path.Join(directoryPath, strings.TrimPrefix(base, ".wh.")))
		return nil
	}

	isDirectory := header.Typeflag == tar.TypeDir || strings.HasSuffix(header.Name, "/")
	if isDirectory {
		if existing, ok := state[relative]; ok && !existing.directory {
			deleteImagePath(state, relative)
		}
		state[relative] = imagePathState{
			directory: true, mode: header.Mode, modTime: header.ModTime,
		}
		ensureImageDirectoryParents(state, relative)
		return nil
	}

	deleteImagePath(state, relative)
	state[relative] = imagePathState{}
	ensureImageDirectoryParents(state, directoryPath)
	return nil
}

func ensureImageDirectoryParents(state map[string]imagePathState, child string) {
	parents := make([]string, 0, 4)
	for parent := child; parent != "." && parent != ""; parent = path.Dir(parent) {
		parents = append(parents, parent)
	}
	for index := len(parents) - 1; index >= 0; index-- {
		parent := parents[index]
		if existing, ok := state[parent]; ok && existing.directory {
			continue
		}
		if existing, ok := state[parent]; ok && !existing.directory {
			deleteImagePath(state, parent)
		}
		state[parent] = imagePathState{directory: true, mode: 0o755}
	}
}

func deleteImagePath(state map[string]imagePathState, target string) {
	for candidate := range state {
		if candidate == target || strings.HasPrefix(candidate, target+"/") {
			delete(state, candidate)
		}
	}
}

func deleteImageDirectoryChildren(state map[string]imagePathState, directory string) {
	if directory == "" {
		for candidate := range state {
			delete(state, candidate)
		}
		return
	}
	for candidate := range state {
		if strings.HasPrefix(candidate, directory+"/") {
			delete(state, candidate)
		}
	}
}
