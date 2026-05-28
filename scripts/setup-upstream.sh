#!/usr/bin/env bash
# setup-upstream.sh — idempotent sparse-blobless clone of surrealdb/surrealdb → external/upstream/
# Pin (tag) read from external/pinned.toml. Bump there, not here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$REPO_ROOT/external/pinned.toml"
DEST="$REPO_ROOT/external/upstream"

if [ ! -f "$PINS" ]; then
    echo "[setup-upstream] missing $PINS" >&2
    exit 1
fi

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

URL=$(toml_get upstream url)
TAG="${UPSTREAM_TAG:-$(toml_get upstream tag)}"

if [ -z "$URL" ] || [ -z "$TAG" ]; then
    echo "[setup-upstream] missing url/tag in $PINS" >&2
    exit 1
fi

if [ -d "$DEST/.git" ]; then
    cur=$(git -C "$DEST" describe --tags --exact-match 2>/dev/null || echo "")
    if [ "$cur" = "$TAG" ]; then
        echo "[setup-upstream] $DEST already at $TAG — nothing to do"
        exit 0
    fi
    echo "[setup-upstream] updating $DEST: $cur -> $TAG"
    git -C "$DEST" fetch --depth 1 origin "tag $TAG"
    git -C "$DEST" checkout -f "$TAG"
    git -C "$DEST" sparse-checkout reapply
else
    echo "[setup-upstream] fresh clone $TAG"
    git clone --depth 1 --filter=blob:none --sparse --branch "$TAG" "$URL" "$DEST"
    git -C "$DEST" sparse-checkout set language-tests
fi
