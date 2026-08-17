package backend

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// validateNoOverwriteDirNonDir checks the Docker archive option before the
// archive is applied. The containerd archive package does not expose this
// Docker-specific policy, so the check must happen before any filesystem
// mutation.
func validateNoOverwriteDirNonDir(root string, data []byte) error {
	reader := tar.NewReader(bytes.NewReader(data))
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read archive header: %w", err)
		}

		relative, err := archiveMemberPath(header.Name)
		if err != nil {
			return err
		}
		if relative == "." {
			continue
		}
		path := filepath.Join(root, filepath.FromSlash(relative))
		if err := rejectNonDirectoryAncestor(root, path); err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect archive destination %q: %w", relative, err)
		}

		archiveIsDirectory := header.Typeflag == tar.TypeDir || strings.HasSuffix(header.Name, "/")
		filesystemIsDirectory := info.IsDir()
		if archiveIsDirectory == filesystemIsDirectory {
			continue
		}
		return fmt.Errorf(
			"archive entry %q changes a %s into a %s",
			relative, filesystemType(filesystemIsDirectory), filesystemType(archiveIsDirectory),
		)
	}
}

func archiveMemberPath(name string) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	if name == "" {
		return ".", nil
	}
	cleaned := filepath.ToSlash(filepath.Clean(name))
	if cleaned == "." {
		return ".", nil
	}
	if strings.HasPrefix(cleaned, "/") || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fmt.Errorf("archive entry %q escapes the destination", name)
	}
	return cleaned, nil
}

func rejectNonDirectoryAncestor(root, path string) error {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return fmt.Errorf("resolve archive destination: %w", err)
	}
	parts := strings.Split(relative, string(filepath.Separator))
	ancestor := root
	for _, part := range parts[:len(parts)-1] {
		ancestor = filepath.Join(ancestor, part)
		info, err := os.Lstat(ancestor)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect archive ancestor %q: %w", part, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("archive entry %q is below a non-directory", filepath.ToSlash(relative))
		}
	}
	return nil
}

func filesystemType(directory bool) string {
	if directory {
		return "directory"
	}
	return "non-directory"
}
