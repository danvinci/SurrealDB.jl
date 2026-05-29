#!/usr/bin/env bash
# test-ci.sh — run the suite inside containers, mirroring a CI matrix leg 1:1:
# same Julia image, same pinned SurrealDB image, same command, same topology.
# The Julia container shares the surreal container's network namespace
# (--network container:), so it reaches surreal at localhost:8000 exactly as CI
# does (Julia on the runner host, surreal in docker with a published port).
#
#   MODE      remote (default) — start surreal, run server-gated suite
#             unit             — no server, unit-only run (server tests self-skip)
#   JULIA     official julia image tag                  (default 1.10)
#   SURREAL   surrealdb/surrealdb image tag             (default v3.1.2)
#   WIRE      cbor | json                               (default cbor)
#
# Pins MUST match .github/workflows/test.yml — that workflow is canonical.
set -euo pipefail

MODE="${1:-remote}"
JULIA="${JULIA:-1.10}"
SURREAL="${SURREAL:-v3.1.2}"
WIRE="${WIRE:-cbor}"
HOST_PORT="${HOST_PORT:-8000}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SURREAL_NAME="surreal-ci-$$"
DEPOT_VOL="surrealdb-jl-depot-${JULIA}"   # persistent depot per julia version → fast reruns

cleanup() { docker rm -f "$SURREAL_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

NET_ARGS=()
URL=""
if [ "$MODE" = "remote" ]; then
    echo "[test-ci] surrealdb/surrealdb:$SURREAL on :$HOST_PORT (wire=$WIRE)"
    docker run -d --rm --name "$SURREAL_NAME" -p "$HOST_PORT:8000" \
        "surrealdb/surrealdb:$SURREAL" \
        start --user root --pass root --bind 0.0.0.0:8000 memory >/dev/null
    echo "[test-ci] waiting for surreal..."
    for _ in $(seq 1 30); do
        curl -s -X POST "http://localhost:$HOST_PORT/rpc" \
            -H 'Content-Type: application/json' \
            -d '{"id":1,"method":"version","params":[]}' >/dev/null 2>&1 && break
        sleep 1
    done
    # Share surreal's network namespace → Julia reaches it at localhost:8000.
    NET_ARGS=(--network "container:$SURREAL_NAME")
    URL="ws://localhost:8000"
fi

echo "[test-ci] julia:$JULIA  mode=$MODE"
docker run --rm "${NET_ARGS[@]}" \
    -v "$REPO:/work" -w /work \
    -v "$DEPOT_VOL:/depot" -e JULIA_DEPOT_PATH=/depot \
    -e SURREALDB_URL="$URL" -e SURREALDB_WIRE="$WIRE" \
    "julia:$JULIA" \
    julia --project=test -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("test/runtests.jl")'
