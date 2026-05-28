#!/usr/bin/env bash
# setup-sdk-refs.sh — idempotent clone of peer SDKs → external/sdk-refs/<key>/
# Pins read from external/pinned.toml. Bump pins there, not here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$REPO_ROOT/external/pinned.toml"
BASE="$REPO_ROOT/external/sdk-refs"

if [ ! -f "$PINS" ]; then
    echo "[setup-sdk-refs] missing $PINS" >&2
    exit 1
fi

# Extract a quoted string value from a TOML section. Usage: toml_get section key.
toml_get() {
    awk -v section="[$1]" -v key="$2" '
        $0 == section { in_section = 1; next }
        /^\[/         { in_section = 0 }
        in_section && $1 == key {
            sub(/^[^=]*= *"?/, "")
            sub(/"$/, "")
            print
            exit
        }
    ' "$PINS"
}

mkdir -p "$BASE"

for key in go js net py rust; do
    url=$(toml_get "sdk-refs.$key" url)
    commit=$(toml_get "sdk-refs.$key" commit)
    dest="$BASE/$key"

    if [ -z "$url" ] || [ -z "$commit" ]; then
        echo "[setup-sdk-refs] $key — missing url/commit in $PINS" >&2
        exit 1
    fi

    if [ -d "$dest/.git" ]; then
        cur=$(git -C "$dest" rev-parse HEAD)
        if [ "$cur" = "$commit" ]; then
            echo "[setup-sdk-refs] $key already at $commit — nothing to do"
            continue
        fi
        echo "[setup-sdk-refs] $key — fetch + reset to $commit"
        git -C "$dest" fetch --depth 1 origin "$commit"
        git -C "$dest" reset --hard "$commit"
    else
        echo "[setup-sdk-refs] $key — fresh clone @ $commit"
        git clone --filter=blob:none "$url" "$dest"
        git -C "$dest" checkout "$commit"
    fi
done

echo "[setup-sdk-refs] done"
