//go:build linux

package backend

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// mountBind bind-mounts source onto destination inside the archive view,
// optionally read-only.
func mountBind(source, destination string, readonly bool) error {
	flags := uintptr(unix.MS_BIND)
	if readonly {
		flags |= unix.MS_RDONLY | unix.MS_REMOUNT
	}
	if err := unix.Mount(source, destination, "", flags, ""); err != nil {
		return err
	}
	if readonly {
		// A read-only bind requires a remount; the initial bind ignores MS_RDONLY.
		if err := unix.Mount(source, destination, "", unix.MS_BIND|unix.MS_RDONLY|unix.MS_REMOUNT, ""); err != nil {
			return fmt.Errorf("remount read-only: %w", err)
		}
	}
	return nil
}

// unmountPath detaches a bind mount prepared for the archive view.
func unmountPath(destination string) error {
	return unix.Unmount(destination, unix.MNT_DETACH)
}
