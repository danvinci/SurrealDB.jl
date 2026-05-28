# test/conformance

Conformance suite — verifies the Julia SDK against external reference substrates.
Four sub-areas, each targeting a different cross-implementation concern.

## Sub-areas

**`cross-sdk/`** — fixture round-trips between the Julia SDK and the Python and Go SDKs.
Writes a shared fixture set from one SDK, reads it back with another, and asserts byte-identical results.
Catches serialisation drift that the SDK's own test suite cannot see.

**`language-tests/`** — drives `runner.jl` against the upstream `surrealdb/surrealdb` language-test corpus.
Each `.surql` file in the corpus is run against a live server; per-statement results are compared to the comment-TOML metadata embedded in the file.
Requires a sparse-blobless checkout at `external/upstream/` (populated by `scripts/setup-upstream.sh`).
See `harness-design.md` for the permanent-suite design (pinning, RPC coverage matrix, failure triage).

**`wire/`** — seven hand-translated wire tests extracted from `upstream/tests/ws_integration.rs`.
Each file in `wire/` covers one scenario: `crud.jl`, `signin_signup.jl`, `live.jl`, `kill.jl`, `multi_statement.jl`, `session_reauth.jl`, `concurrency.jl`.
Requires a running server but no upstream checkout.

**`fixtures/`** — durable golden files consumed by other tests.
`fixtures/cbor/native.toml` is the Rust-generated CBOR parity fixture (produced by `scripts/regen-cbor-fixtures.sh`; consumed by `test/sdk/cbor/test_cbor_parity.jl`).
`fixtures/cbor/gen/` holds the Rust generator source.

## Running locally

```bash
bash scripts/setup-upstream.sh   # one-time sparse clone of upstream corpus
bash scripts/setup-server.sh     # provision surreal binary
bash scripts/run-conformance.sh  # run all three suites
```

All scripts are idempotent; re-running is safe and cheap.

## CI

The `conformance.yml` workflow splits into four jobs: `cross-sdk`, `language-tests`, `wire`, and `parity-verify`.
Each job delegates provisioning to the same `scripts/` entry points.
