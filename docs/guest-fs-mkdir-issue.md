# Resolved: ENOENT from `mkdir()` into lower-layer directories

**Status:** fixed in the current development guest.

## Symptom

Some guest overlayfs mounts need an image directory inode to be copied into
the writable upper layer before a process creates a child. Without that
copy-up, the official nginx image aborts:

```
[emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (2: No such file or directory)
```

`ls /var/cache/nginx` can show the directory even though the first nested
create returns `ENOENT`.

## Characteristics

- The failure affects empty image directories that need runtime children.
- A directory copy-up before the first child create makes both shell and
  native application creates succeed.
- The kernel is unchanged. The repair is in the guest backend's container
  creation path.

## Fix

`Guest/internal/backend/image_directories.go` reads the final directory set
from the image layers. During container creation it selects Docker-configured
`VOLUME` paths and their ancestors, then forces empty lower-layer directories
in that set into the writable upper layer with a temporary marker file that is
removed immediately. The image contents remain unchanged. Other empty image
directories stay in the lower layers, so ordinary idle containers do not pay
for copy-up entries that their workload does not use.

## Coverage

`scripts/verify-dockerfile-build.sh` now checks all of the following against a
fresh isolated daemon and a real Docker client:

- `/var/cache/nginx` exists after container creation.
- A shell can create `/var/cache/nginx/client_temp`.
- An unmodified `nginx:alpine` container stays running.

The port-publishing harness uses the normal nginx entrypoint. It no longer
pre-creates nginx directories.
