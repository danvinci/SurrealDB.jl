#!/usr/bin/env bash
# setup-server.sh — provision a surreal binary; no-op if already present
set -euo pipefail

if command -v surreal &>/dev/null; then
    echo "[setup-server] surreal found at $(command -v surreal) — nothing to do"
    exit 0
fi

OS="$(uname -s)"

if [ "${CI:-}" = "true" ]; then
    echo "[setup-server] CI environment — pulling surrealdb/surrealdb:latest via docker"
    docker pull surrealdb/surrealdb:latest
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/surreal" <<'WRAPPER'
#!/usr/bin/env bash
exec docker run --rm -it \
    -p 8000:8000 \
    surrealdb/surrealdb:latest \
    "$@"
WRAPPER
    chmod +x "$HOME/.local/bin/surreal"
    echo "[setup-server] wrapper written to $HOME/.local/bin/surreal"
    echo "[setup-server] ensure \$HOME/.local/bin is on PATH"
    exit 0
fi

if [ "$OS" = "Darwin" ]; then
    echo "[setup-server] surreal not found — install with:"
    echo "    brew install surrealdb/tap/surreal"
    exit 1
else
    echo "[setup-server] surreal not found — install with:"
    echo "    curl -sSf https://install.surrealdb.com | sh"
    exit 1
fi
