#!/usr/bin/env bash
# setup-server.sh — provision + start a surreal server on 127.0.0.1:$PORT
# Idempotent: no-op if a server is already listening on the port.
set -euo pipefail

PORT="${SURREALDB_PORT:-8000}"
USER="${SURREALDB_USER:-root}"
PASS="${SURREALDB_PASS:-root}"
IMAGE="${SURREALDB_IMAGE:-surrealdb/surrealdb:latest}"
READY_TIMEOUT="${SURREALDB_READY_TIMEOUT:-30}"

# Already running? Done.
if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "[setup-server] surreal already listening on :$PORT — nothing to do"
    exit 0
fi

# Docker path: CI uses it; locally opt-in via SURREALDB_BACKEND=docker for CI parity.
if [ "${CI:-}" = "true" ] || [ "${SURREALDB_BACKEND:-}" = "docker" ]; then
    echo "[setup-server] starting $IMAGE via docker on :$PORT"
    docker pull "$IMAGE"
    docker run -d --rm --name surreal-ci \
        -p "$PORT:8000" \
        "$IMAGE" \
        start --user "$USER" --pass "$PASS" --bind 0.0.0.0:8000 memory
# Local path: native binary if available.
elif command -v surreal &>/dev/null; then
    echo "[setup-server] starting native surreal on :$PORT (pid logged to /tmp/surreal-$PORT.pid)"
    surreal start --user "$USER" --pass "$PASS" --bind "127.0.0.1:$PORT" memory \
        > "/tmp/surreal-$PORT.log" 2>&1 &
    echo $! > "/tmp/surreal-$PORT.pid"
# Local path: no binary. Tell the user how to get one.
elif [ "$(uname -s)" = "Darwin" ]; then
    echo "[setup-server] surreal not found — install with:" >&2
    echo "    brew install surrealdb/tap/surreal" >&2
    exit 1
else
    echo "[setup-server] surreal not found — install with:" >&2
    echo "    curl -sSf https://install.surrealdb.com | sh" >&2
    exit 1
fi

# Wait for the port to accept connections. Bounded — failed startup shouldn't
# hang the workflow indefinitely.
echo "[setup-server] waiting for :$PORT (timeout ${READY_TIMEOUT}s)..."
for _ in $(seq 1 "$READY_TIMEOUT"); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
        echo "[setup-server] ready"
        exit 0
    fi
    sleep 1
done

echo "[setup-server] timed out waiting for :$PORT" >&2
if [ "${CI:-}" = "true" ]; then
    docker logs surreal-ci 2>&1 | tail -50 >&2 || true
fi
exit 1
