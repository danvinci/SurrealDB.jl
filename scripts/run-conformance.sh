#!/usr/bin/env bash
# Orchestrates the three conformance suites: cross-sdk, language-tests, wire.
# Idempotent: safe to re-run; setup scripts are no-ops when already in the correct state.
# Used identically by local devs and CI — no ENV["CI"] branches.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- cross-sdk ---
echo "==> cross-sdk"
bash "$REPO_ROOT/scripts/setup-server.sh"
julia --project="$REPO_ROOT/test" "$REPO_ROOT/test/conformance/cross-sdk/test_interop.jl"

# --- language-tests ---
echo "==> language-tests"
if [ ! -d "$REPO_ROOT/external/upstream/language-tests" ]; then
    bash "$REPO_ROOT/scripts/setup-upstream.sh"
fi
julia --project="$REPO_ROOT/test" "$REPO_ROOT/test/conformance/language-tests/runner.jl"

# --- wire ---
# Run all seven wire probes in a single Julia session so they share the server
# connection state. Per-file `julia` invocations would each restart the runtime
# and cannot guarantee the server remains clean between them.
echo "==> wire"
julia --project="$REPO_ROOT/test" -e "
    wire_dir = joinpath(\"$REPO_ROOT\", \"test\", \"conformance\", \"wire\")
    for f in sort(readdir(wire_dir, join=true))
        endswith(f, \".jl\") && include(f)
    end
"
