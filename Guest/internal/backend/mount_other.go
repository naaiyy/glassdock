//go:build !linux

package backend

import "errors"

// mountBind has no implementation outside Linux: the guest agent only runs
// inside the Linux VM. Test builds never reach this path.
func mountBind(source, destination string, readonly bool) error {
	return errors.New("bind mounts are only available on Linux")
}

// unmountPath has no implementation outside Linux.
func unmountPath(destination string) error {
	return errors.New("unmount is only available on Linux")
}
