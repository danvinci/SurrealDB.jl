#!/usr/bin/env bash
# setup-upstream.sh — idempotent sparse-blobless clone of surrealdb/surrealdb → external/upstream/
set -euo pipefail

TAG="${UPSTREAM_TAG:-v3.0.4}"
DEST="external/upstream"

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
    git clone --depth 1 --filter=blob:none --sparse --branch "$TAG" \
        https://github.com/surrealdb/surrealdb "$DEST"
    git -C "$DEST" sparse-checkout set language-tests
fi
