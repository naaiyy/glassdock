#!/usr/bin/env bash
# Live verification of port publishing (backlog item R4).
#
# Boots an isolated Glass Dock daemon, publishes PostgreSQL and nginx through
# `docker run -p` from a real Docker client, and verifies the published ports
# survive container restarts and a daemon restart. Works against both the
# direct-TCP forwarder path (NIO listener -> vsock -> guest forwarder) and the
# gvproxy fallback (--no-direct-tcp-forwarding).
#
# Usage:
#   scripts/verify-port-publishing.sh [--no-direct-tcp-forwarding] [--keep]
#
# Never touches ~/.glassdock/container.sock; everything lives under a fresh
# temporary directory. Requires: docker client, psql, curl, jq.
set -euo pipefail

DIRECT_TCP=1
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-direct-tcp-forwarding) DIRECT_TCP=0; shift ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLASSDOCK="$REPO_ROOT/.build/debug/glassdock"
[ -x "$GLASSDOCK" ] || { echo "error: build first with 'make build'" >&2; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/glassdock-r4.XXXXXX")"
HOME_DIR="$TMPD/home"
STATE_DIR="$TMPD/state"
LOG="$TMPD/daemon.log"
SOCK="$HOME_DIR/.glassdock/container.sock"
PG_PORT=55432
NGINX_PORT=55080
PG_PASSWORD="r4-secret"

DOCKER=(docker -H "unix://$SOCK")
# Public pulls only; bypass any host credential-helper config that may not be
# on PATH inside this script's environment.
export DOCKER_CONFIG="$TMPD/docker-config"
mkdir -p "$DOCKER_CONFIG"
DAEMON_PID=""

cleanup() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    # Always preserve the daemon log for post-mortem; remove scratch state only
    # on success.
    cp "$LOG" "${TMPD}/../glassdock-r4-last-daemon.log" 2>/dev/null || true
    if [ "$KEEP" != 1 ]; then
        "${DOCKER[@]}" rm -f r4pg r4nginx >/dev/null 2>&1 || true
        rm -rf "$TMPD"
    else
        echo "kept scratch dir: $TMPD"
    fi
}
trap cleanup EXIT

step()  { printf '\n=== %s ===\n' "$*"; }
fail()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

wait_for_log() {
    local pattern="$1" timeout="${2:-180}"
    for _ in $(seq 1 "$timeout"); do
        if grep -q "$pattern" "$LOG" 2>/dev/null; then return 0; fi
        if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            tail -20 "$LOG" >&2
            fail "daemon exited while waiting for: $pattern"
        fi
        # The engine boots lazily; a client request triggers VM startup.
        "${DOCKER[@]}" version >/dev/null 2>&1 || true
        sleep 1
    done
    tail -20 "$LOG" >&2
    fail "timed out waiting for: $pattern"
}

retry_until() {
    # retry_until <description> <timeout-seconds> <command...>
    local description="$1" timeout="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then fail "$description"; fi
        sleep 2
    done
}

DAEMON_FLAGS=(--no-docker-context --cpus 4 --memory-mib 2048)
if [ "$DIRECT_TCP" != 1 ]; then
    DAEMON_FLAGS+=(--no-direct-tcp-forwarding)
fi

start_daemon() {
    step "starting isolated daemon ($TMPD)"
    echo "flags: ${DAEMON_FLAGS[*]}"
    (
        export GLASSDOCK_HOST_HOME_DIRECTORY="$HOME_DIR"
        export GLASSDOCK_ENGINE_STATE_DIRECTORY="$STATE_DIR"
        export LOG_LEVEL=info
        exec "$GLASSDOCK" "${DAEMON_FLAGS[@]}" >>"$LOG" 2>&1
    ) &
    DAEMON_PID=$!
    wait_for_log "persistent engine is ready" 240
    echo "daemon ready (pid $DAEMON_PID)"
}

transport_report() {
    # The gvproxy API socket only lists endpoints gvproxy itself forwards.
    # Direct-TCP publications never appear there.
    local gvproxy_api="$STATE_DIR/runtime/network/a.sock"
    step "active gvproxy forwarders"
    if curl -s --max-time 5 --unix-socket "$gvproxy_api" http://localhost/services/forwarder/all | jq .; then
        :
    else
        echo "(gvproxy API unavailable at $gvproxy_api)"
    fi
}

with_timeout() {
    # with_timeout <seconds> <command...> (macOS has no coreutils timeout)
    local seconds="$1"; shift
    "$@" &
    local pid=$!
    (
        sleep "$seconds"
        kill -9 "$pid" 2>/dev/null
    ) &
    local watchdog=$!
    set +e
    wait "$pid"
    local status=$?
    set -e
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

psql_query() {
    PGPASSWORD="$PG_PASSWORD" with_timeout 30 \
        psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -tAc "$1" -w
}

verify_postgres() {
    retry_until "postgres did not accept queries on 127.0.0.1:$PG_PORT" 120 \
        psql_query "SELECT 1"
    psql_query "CREATE TABLE IF NOT EXISTS r4probe(id int PRIMARY KEY, payload bytea)" || {
        psql_query "SELECT 1"; fail "postgres CREATE TABLE failed"; }
    psql_query "INSERT INTO r4probe VALUES (1, md5(random()::text)::bytea) ON CONFLICT (id) DO NOTHING"
    local value
    value="$(psql_query "SELECT id FROM r4probe WHERE id = 1")"
    [ "$value" = "1" ] || fail "unexpected postgres query result: '$value'"
    echo "postgres query OK on 127.0.0.1:$PG_PORT"
}

verify_postgres_integrity() {
    # Round-trip an 8 MiB random blob through the published port and compare
    # digests computed inside the database.
    local digest
    digest="$(psql_query "SELECT md5(string_agg(md5(g::text), '' ORDER BY g)) FROM generate_series(1, 262144) g")"
    [ ${#digest} = 32 ] || fail "failed to compute reference digest"
    psql_query "DROP TABLE IF EXISTS r4blob"
    psql_query "CREATE TABLE r4blob(digest text, payload bytea)"
    psql_query "INSERT INTO r4blob SELECT '$digest', string_agg(md5(g::text), '' ORDER BY g)::bytea FROM generate_series(1, 262144) g"
    local roundtrip
    roundtrip="$(psql_query "SELECT md5(payload) FROM r4blob")"
    [ "$roundtrip" = "$digest" ] || fail "payload corrupted through published port: $roundtrip != $digest"
    echo "postgres 8 MiB round-trip integrity OK"
}

verify_nginx() {
    retry_until "nginx did not answer on 127.0.0.1:$NGINX_PORT" 120 \
        with_timeout 10 curl -fsS --max-time 5 "http://127.0.0.1:$NGINX_PORT/"
    with_timeout 10 curl -fsS --max-time 5 "http://127.0.0.1:$NGINX_PORT/" \
        | grep -q "Welcome to nginx" || fail "nginx served unexpected content"
    echo "nginx HTTP OK on 127.0.0.1:$NGINX_PORT"
}

start_daemon

step "launching containers via docker run -p"
# Glass Dock does not yet materialize image VOLUME paths, so postgres's
# /var/lib/postgresql/data must be created before its entrypoint runs.
"${DOCKER[@]}" run -d --name r4pg \
    --entrypoint sh \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -p "127.0.0.1:$PG_PORT:5432" postgres:17-alpine \
    -c "mkdir -p /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data && chown -R postgres:postgres /var/lib/postgresql && exec /usr/local/bin/docker-entrypoint.sh postgres"
"${DOCKER[@]}" run -d --name r4nginx \
    -p "127.0.0.1:$NGINX_PORT:80" nginx:alpine

dump_state() {
    echo "--- docker ps -a ---"
    "${DOCKER[@]}" ps -a --format '{{.Names}} {{.State}} {{.Status}}' 2>&1 || true
    for name in r4pg r4nginx; do
        echo "--- logs: $name ---"
        "${DOCKER[@]}" logs --tail 30 "$name" 2>&1 | tail -10 || true
    done
}

verify_postgres || { dump_state; exit 1; }
verify_postgres_integrity || { dump_state; exit 1; }
verify_nginx || { dump_state; exit 1; }
transport_report

step "restarting containers"
"${DOCKER[@]}" restart r4pg r4nginx
sleep 2
verify_postgres || { dump_state; exit 1; }
verify_nginx || { dump_state; exit 1; }

step "restarting daemon (SIGTERM + relaunch, same state)"
kill "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""
: >"$LOG"
start_daemon

step "verifying restored containers after daemon restart"
"${DOCKER[@]}" ps --format '{{.Names}} {{.Status}}'
"${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx r4pg || fail "r4pg missing after daemon restart"
"${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx r4nginx || fail "r4nginx missing after daemon restart"
verify_postgres || { dump_state; exit 1; }
verify_nginx || { dump_state; exit 1; }
transport_report

printf '\nALL PORT-PUBLISHING PROBES PASSED (%s)\n' \
    "$([ "$DIRECT_TCP" = 1 ] && echo direct-tcp+gvproxy || echo gvproxy-only)"
