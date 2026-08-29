# Known issue: ENOENT from `mkdir()` into lower-layer directories

**Status:** open on current dev guest builds; not present in production 1.3.1.

## Symptom

Processes that call `mkdir()` directly at startup fail with `ENOENT` even
though the parent directory exists. The official nginx image aborts:

```
[emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (2: No such file or directory)
```

`ls /var/cache/nginx` inside the same container shows the directory, and
busybox `mkdir` of the same path succeeds when run first.

## Characteristics

- Whoever performs the *first* create decides the outcome: shell-first
  succeeds; nginx-first fails, and subsequent shell `mkdir`s for that path
  keep failing too.
- `touch`/`mkdir` under other lower-layer directories works in fresh
  containers.
- The kernel is identical between production and dev (`glassdock-vmlinux`
  digests match); the difference is rootfs userspace (guest agent and
  containerd dependency set in `Guest/go.mod`).

## Suspected area

Guest overlayfs copy-up during directory creation — possibly influenced by
the newer containerd/dependency versions in the current build.

## Reproduction

```sh
cd Guest && make image   # current main
# boot a dev daemon with the fresh rootfs, then:
docker -H <dev-socket> run --rm nginx:alpine sh -c "nginx -t"
# → mkdir() "/var/cache/nginx/client_temp" failed (2: No such file or directory)

docker -H <dev-socket> run --rm --entrypoint sh nginx:alpine \
    -c "mkdir -p /var/cache/nginx/client_temp && exec nginx -t"
# → succeeds; production 1.3.1 succeeds without the workaround
```

## Workaround

Pre-create the leaf directories from a shell entrypoint before the real
binary runs. `scripts/verify-port-publishing.sh` does this for nginx.
