#!/usr/bin/env bash
# Live verification of classic Dockerfile builds through the Docker API.
#
# The harness uses a real Docker client against an isolated Glass Dock daemon.
# It covers ordered RUN/COPY execution, build arguments, SHELL, multi-stage
# COPY, local archive ADD, .dockerignore, image configuration, and healthchecks.
# It also starts an unmodified nginx image to cover image-layer directory
# materialization. BuildKit's /session path is verified separately by the
# compatibility harness.
set -euo pipefail

KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLASSDOCK="$REPO_ROOT/.build/debug/glassdock"
[ -x "$GLASSDOCK" ] || { echo "error: build first with 'make build'" >&2; exit 1; }

for command in docker jq tar; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "error: required command is missing: $command" >&2
        exit 1
    }
done

# Keep the Unix socket below macOS's path-length limit even when TMPDIR is deep.
TMPD="$(mktemp -d /tmp/glassdock-dockerfile-build.XXXXXX)"
HOME_DIR="$TMPD/home"
STATE_DIR="$TMPD/state"
CONTEXT_DIR="$TMPD/contexts"
LOG="$TMPD/daemon.log"
SOCK="$HOME_DIR/.glassdock/container.sock"
BASE_IMAGE="docker.io/library/alpine@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37"
DOCKER=(docker -H "unix://$SOCK")
export DOCKER_CONFIG="$TMPD/docker-config"
mkdir -p "$DOCKER_CONFIG" "$CONTEXT_DIR"

DAEMON_PID=""
PASSED=0

cleanup() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ "$KEEP" = 1 ] || [ "$PASSED" != 1 ]; then
        echo "kept scratch dir: $TMPD" >&2
    else
        rm -rf "$TMPD"
    fi
}
trap cleanup EXIT

step() { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

wait_for_daemon() {
    for _ in $(seq 1 240); do
        if "${DOCKER[@]}" version >/dev/null 2>&1; then
            return 0
        fi
        if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            tail -30 "$LOG" >&2 || true
            fail "daemon exited during startup"
        fi
        sleep 1
    done
    tail -30 "$LOG" >&2 || true
    fail "timed out waiting for isolated daemon"
}

start_probe() {
    local name="$1" image="$2"
    "${DOCKER[@]}" run -d --name "$name" --entrypoint sh "$image" -c 'sleep 120' >/dev/null
}

stop_probe() {
    local name="$1"
    "${DOCKER[@]}" rm -f "$name" >/dev/null 2>&1 || true
}

assert_file_content() {
    local container="$1" path="$2" expected="$3" actual
    actual="$("${DOCKER[@]}" exec "$container" sh -c "cat '$path'")"
    [ "$actual" = "$expected" ] || fail "$container:$path = '$actual', want '$expected'"
}

step "starting isolated daemon"
(
    export GLASSDOCK_HOST_HOME_DIRECTORY="$HOME_DIR"
    export GLASSDOCK_ENGINE_STATE_DIRECTORY="$STATE_DIR"
    export LOG_LEVEL=info
    cd "$REPO_ROOT"
    exec "$GLASSDOCK" --no-docker-context --cpus 4 --memory-mib 2048 >>"$LOG" 2>&1
) &
DAEMON_PID=$!
wait_for_daemon

step "ordered RUN, ENV, WORKDIR, COPY, labels, and CMD"
ORDERED="$CONTEXT_DIR/ordered"
mkdir -p "$ORDERED"
cat >"$ORDERED/Dockerfile" <<EOF
FROM $BASE_IMAGE
ENV BUILD_MARKER=env-value
ENV BUILD_PATH=\$PATH:/glassdock
WORKDIR /workspace
COPY before.txt before.txt
RUN test "\$BUILD_MARKER" = env-value && case "\$BUILD_PATH" in *:/glassdock) ;; *) exit 1 ;; esac && test "\$(cat before.txt)" = before && printf 'run-output\\n' > run.txt
COPY after.txt after.txt
RUN test "\$(cat after.txt)" = after && pwd > pwd.txt
LABEL build.test=ordered
CMD ["sh", "-c", "cat /workspace/run.txt"]
EOF
printf 'before\n' >"$ORDERED/before.txt"
printf 'after\n' >"$ORDERED/after.txt"
"${DOCKER[@]}" build -t glassdock/live-build:ordered "$ORDERED"
"${DOCKER[@]}" image inspect glassdock/live-build:ordered | jq -e \
    '.[0].Config.Env | index("BUILD_MARKER=env-value") != null' >/dev/null
"${DOCKER[@]}" image inspect glassdock/live-build:ordered | jq -e \
    '.[0].Config.WorkingDir == "/workspace" and .[0].Config.Labels["build.test"] == "ordered"' >/dev/null
start_probe ordered-run glassdock/live-build:ordered
assert_file_content ordered-run /workspace/before.txt before
assert_file_content ordered-run /workspace/after.txt after
assert_file_content ordered-run /workspace/run.txt run-output
assert_file_content ordered-run /workspace/pwd.txt /workspace
stop_probe ordered-run

step "multi-stage COPY and JSON-form RUN"
MULTI="$CONTEXT_DIR/multistage"
mkdir -p "$MULTI"
cat >"$MULTI/Dockerfile" <<EOF
FROM $BASE_IMAGE AS builder
WORKDIR /out
RUN printf 'multi-stage\\n' > artifact.txt
FROM $BASE_IMAGE
COPY --from=builder /out/artifact.txt /app/artifact.txt
RUN ["test", "-f", "/app/artifact.txt"]
EOF
"${DOCKER[@]}" build -t glassdock/live-build:multistage "$MULTI"
start_probe multistage-run glassdock/live-build:multistage
assert_file_content multistage-run /app/artifact.txt multi-stage
stop_probe multistage-run

step "build arguments, SHELL, archive ADD, and .dockerignore"
ARGS="$CONTEXT_DIR/args"
mkdir -p "$ARGS/archive"
cat >"$ARGS/Dockerfile" <<EOF
ARG GREETING=default
FROM $BASE_IMAGE
ARG GREETING
SHELL ["/bin/ash", "-c"]
RUN test "\$GREETING" = supplied && printf 'arg-and-shell\\n' > /arg-shell.txt
ADD bundle.tar /opt/bundle/
COPY . /context/
EOF
printf 'this file must not be in the image\n' >"$ARGS/ignored.txt"
printf 'this file must be in the image\n' >"$ARGS/kept.txt"
cat >"$ARGS/.dockerignore" <<'EOF'
ignored.txt
archive/
EOF
printf 'archive-data\n' >"$ARGS/archive/inside.txt"
tar -cf "$ARGS/bundle.tar" -C "$ARGS/archive" inside.txt
"${DOCKER[@]}" build --build-arg GREETING=supplied -t glassdock/live-build:args "$ARGS"
start_probe args-run glassdock/live-build:args
assert_file_content args-run /arg-shell.txt arg-and-shell
assert_file_content args-run /opt/bundle/inside.txt archive-data
assert_file_content args-run /context/kept.txt 'this file must be in the image'
if "${DOCKER[@]}" exec args-run test -e /context/ignored.txt; then
    fail ".dockerignore did not exclude ignored.txt"
fi
stop_probe args-run

step "healthcheck and final image configuration"
CONFIG="$CONTEXT_DIR/config"
mkdir -p "$CONFIG"
cat >"$CONFIG/Dockerfile" <<EOF
FROM $BASE_IMAGE
WORKDIR /health
RUN printf 'ready\\n' > ready.txt
HEALTHCHECK --interval=1s --timeout=1s --retries=1 CMD ["test", "-f", "/health/ready.txt"]
ENTRYPOINT ["sh", "-c"]
CMD ["cat /health/ready.txt"]
EOF
"${DOCKER[@]}" build -t glassdock/live-build:config "$CONFIG"
"${DOCKER[@]}" image inspect glassdock/live-build:config | jq -e \
    '.[0].Config.WorkingDir == "/health" and
     .[0].Config.Entrypoint == ["sh", "-c"] and
     .[0].Config.Cmd == ["cat /health/ready.txt"] and
    .[0].Config.Healthcheck.Test == ["CMD", "test", "-f", "/health/ready.txt"]' >/dev/null

step "native image-layer directories"
"${DOCKER[@]}" pull nginx:alpine >/dev/null
start_probe native-nginx-root nginx:alpine
"${DOCKER[@]}" exec native-nginx-root ls -ld /var/cache /var/cache/nginx
if ! "${DOCKER[@]}" exec native-nginx-root test -d /var/cache/nginx; then
    fail "image-layer directory /var/cache/nginx is missing"
fi
stop_probe native-nginx-root
start_probe native-nginx-mkdir nginx:alpine
"${DOCKER[@]}" exec native-nginx-mkdir mkdir /var/cache/nginx/client_temp
stop_probe native-nginx-mkdir
"${DOCKER[@]}" run -d --name native-nginx nginx:alpine >/dev/null
for _ in $(seq 1 30); do
    if [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' native-nginx 2>/dev/null)" = "true" ]; then
        break
    fi
    sleep 1
done
if [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' native-nginx 2>/dev/null)" != "true" ]; then
    "${DOCKER[@]}" logs native-nginx >&2 || true
    fail "unmodified nginx image did not stay running"
fi
stop_probe native-nginx

PASSED=1
printf '\nALL DOCKERFILE BUILD PROBES PASSED\n'
