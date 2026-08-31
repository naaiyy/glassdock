#!/usr/bin/env bash

set -euo pipefail

DOCKER_HOST=${DOCKER_HOST:-unix://$HOME/.glassdock/container.sock}
IMAGE=${DOCKER_SOCKET_RELAY_IMAGE:-docker.io/library/docker:cli}
RUN_NAME="glassdock-docker-socket-relay-$$"
DOCKER=(docker -H "$DOCKER_HOST")

usage() {
    cat <<'EOF'
Usage: scripts/verify-docker-socket-relay.sh

Runs a container with /var/run/docker.sock mounted and executes Docker CLI ps
through the relayed socket. Set DOCKER_HOST to the active Glass Dock socket
and optionally set DOCKER_SOCKET_RELAY_IMAGE to an arm64 image with Docker CLI.
EOF
}

die() {
    echo "docker socket relay: $*" >&2
    exit 1
}

if [[ ${1:-} == --help ]]; then
    usage
    exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1"
[[ $DOCKER_HOST == unix://* ]] || die "DOCKER_HOST must use unix://"

socket=${DOCKER_HOST#unix://}
[[ -S $socket ]] || die "Docker socket does not exist: $socket"
command -v docker >/dev/null 2>&1 || die "docker is not installed"

cleanup() {
    "${DOCKER[@]}" rm -f "$RUN_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${DOCKER[@]}" version >/dev/null || die "Docker API is not reachable"
echo "docker socket relay: running $IMAGE against $DOCKER_HOST"
"${DOCKER[@]}" run --rm --name "$RUN_NAME" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint /bin/sh "$IMAGE" \
    -c 'docker -H unix:///var/run/docker.sock ps'
echo "docker socket relay: passed"
