#!/usr/bin/env bash
# regen-cbor-fixtures.sh — regenerate Rust CBOR parity fixtures; cargo caches the build
set -euo pipefail

cd "$(dirname "$0")/../test/conformance/fixtures/cbor/gen"
cargo run > ../native.toml
echo "[regen-cbor-fixtures] native.toml updated"
