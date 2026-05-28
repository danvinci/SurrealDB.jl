#!/usr/bin/env bash
# setup-sdk-refs.sh — idempotent clone of peer SDKs → external/sdk-refs/ (floats on main)
set -euo pipefail

BASE="external/sdk-refs"
mkdir -p "$BASE"

declare -A REPOS=(
    ["surrealdb.go"]="https://github.com/surrealdb/surrealdb.go"
    ["surrealdb.py"]="https://github.com/surrealdb/surrealdb.py"
    ["surrealdb.js"]="https://github.com/surrealdb/surrealdb.js"
    ["surrealdb.net"]="https://github.com/surrealdb/surrealdb.net"
    ["surrealdb.rust"]="https://github.com/surrealdb/surrealdb.rust"
)

for name in "${!REPOS[@]}"; do
    url="${REPOS[$name]}"
    dest="$BASE/$name"
    if [ -d "$dest/.git" ]; then
        echo "[setup-sdk-refs] $name — fetch + reset to origin/main"
        git -C "$dest" fetch --depth 1 origin main
        git -C "$dest" reset --hard origin/main
    else
        echo "[setup-sdk-refs] $name — fresh clone"
        git clone --depth 1 "$url" "$dest"
    fi
done

echo "[setup-sdk-refs] done"
