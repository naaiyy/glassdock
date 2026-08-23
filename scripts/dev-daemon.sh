#!/usr/bin/env bash
# Boots an isolated development daemon that never touches ~/.glassdock or the
# production engine state. Sockets, Docker context, and engine state all live
# under .build/glassdock-dev.
#
# Usage:
#   make dev-daemon            # run in the foreground
#   make dev-daemon ARGS="--cpus 8"
#
# Connect a client with:
#   docker -H unix://.build/glassdock-dev/home/.glassdock/container.sock ps
#
# Overrides: GLASSDOCK_DEV_DIR (default .build/glassdock-dev),
# GLASSDOCK_DEV_CPUS (default 4), GLASSDOCK_DEV_MEMORY_MIB (default 2048).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/.build/debug/glassdock"
[ -x "$BINARY" ] || { echo "error: build first with 'make build'" >&2; exit 1; }

DEV_DIR="${GLASSDOCK_DEV_DIR:-$ROOT/.build/glassdock-dev}"
mkdir -p "$DEV_DIR/home" "$DEV_DIR/state"

export GLASSDOCK_HOST_HOME_DIRECTORY="$DEV_DIR/home"
export GLASSDOCK_ENGINE_STATE_DIRECTORY="$DEV_DIR/state"

echo "dev daemon socket : $DEV_DIR/home/.glassdock/container.sock"
echo "dev engine state  : $DEV_DIR/state"
exec "$BINARY" --no-docker-context \
    --cpus "${GLASSDOCK_DEV_CPUS:-4}" \
    --memory-mib "${GLASSDOCK_DEV_MEMORY_MIB:-2048}" "$@"
