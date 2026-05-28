# SurrealDB.jl

[![Test](https://github.com/danvinci/SurrealDB.jl/actions/workflows/test.yml/badge.svg)](https://github.com/danvinci/SurrealDB.jl/actions/workflows/test.yml)
[![Benchmark](https://github.com/danvinci/SurrealDB.jl/actions/workflows/bench.yml/badge.svg)](https://github.com/danvinci/SurrealDB.jl/actions/workflows/bench.yml)
[![Conformance](https://github.com/danvinci/SurrealDB.jl/actions/workflows/conformance.yml/badge.svg)](https://github.com/danvinci/SurrealDB.jl/actions/workflows/conformance.yml)
[![Docs](https://github.com/danvinci/SurrealDB.jl/actions/workflows/docs.yml/badge.svg)](https://danvinci.github.io/SurrealDB.jl/dev/)
[![codecov](https://codecov.io/gh/danvinci/SurrealDB.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/danvinci/SurrealDB.jl)

Julia client for [SurrealDB](https://surrealdb.com).
Talks to a remote `surreal` server over WebSocket or HTTP, or runs the database in-process via `libsurreal`.
Same API regardless of backend.
Default wire is CBOR.

**Status: alpha.** Pre-1.0. API may break between minor versions; pin a specific version to avoid breakage.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/danvinci/SurrealDB.jl", rev="v0.2.0-alpha.1")
```

Not yet in the General registry.
The embedded backend needs `libsurreal`; see [Embedded mode](https://danvinci.github.io/SurrealDB.jl/dev/debugging/#Embedded-mode).

## Quickstart

```julia
using SurrealDB

db = SurrealDB.connect("ws://localhost:8000";
                       ns="test", db="test",
                       auth=SurrealDB.RootAuth("root", "root"))

alice = SurrealDB.create(db, "user", Dict("name" => "Alice", "age" => 30))
bob   = SurrealDB.create(db, rid"user:bob", Dict("name" => "Bob", "age" => 25))

users = SurrealDB.select(db, "user")
SurrealDB.update(db, alice["id"], Dict("age" => 31))
SurrealDB.delete(db, rid"user:bob")

results = SurrealDB.query(db, "SELECT * FROM user WHERE age > 18")

SurrealDB.close!(db)
```

Do-block form closes in a `finally`:

```julia
SurrealDB.connect("ws://localhost:8000"; ns="test", db="test") do db
    SurrealDB.query(db, "SELECT * FROM user")
end
```

## Connection modes

| URL scheme | Backend | Notes |
|---|---|---|
| `ws://`, `wss://` | Remote WS | Live queries, sessions, transactions, ping, auto-reconnect |
| `http://`, `https://` | Remote HTTP | Stateless. `live()` raises `UnsupportedFeatureError` |
| `mem://`, `memory://` | Embedded | In-memory, in-process via `libsurreal` |
| `surrealkv://path` | Embedded | File-backed, in-process |

`mem://` / `memory://` and `surrealkv://path` are URL conventions shared with the official [JS](https://github.com/surrealdb/surrealdb.js), [Python](https://github.com/surrealdb/surrealdb.py), and [.NET](https://github.com/surrealdb/surrealdb.net) SDKs.

## Documentation

Full reference at [danvinci.github.io/SurrealDB.jl](https://danvinci.github.io/SurrealDB.jl/dev/):

- [Record IDs](https://danvinci.github.io/SurrealDB.jl/dev/records/): `RecordID(t, i)`, `rid"t:i"` macro, `StringRecordID`
- [Wire format](https://danvinci.github.io/SurrealDB.jl/dev/wire/): CBOR + JSON, typed round-trips, NONE / NULL
- [Authentication](https://danvinci.github.io/SurrealDB.jl/dev/auth/): root / namespace / scoped, refresh tokens, state replay
- [Live queries](https://danvinci.github.io/SurrealDB.jl/dev/live/): subscriptions, multi-subscriber fan-out, reconnect handling, server-initiated KILLED
- [Transactions](https://danvinci.github.io/SurrealDB.jl/dev/transactions/): v2 client RPC, v3 session-scoped `SurrealTransaction`, session variables
- [Reconnect](https://danvinci.github.io/SurrealDB.jl/dev/reconnect/): tuning, lifecycle observability, closed-handle semantics
- [Errors](https://danvinci.github.io/SurrealDB.jl/dev/errors/): typed hierarchy
- [Integrations](https://danvinci.github.io/SurrealDB.jl/dev/integrations/): StructTypes, Tables.jl, MetaGraphsNext
- [API reference](https://danvinci.github.io/SurrealDB.jl/dev/api/connection/): full surface

## Cross-SDK conformance

Go SDK test suite ported as Julia testsets; Python interop verified via fixture round-trips.
JS + Rust planned ([roadmap](#roadmap)).

The comparative reference set includes [Go](https://github.com/surrealdb/surrealdb.go), [Python](https://github.com/surrealdb/surrealdb.py), [JS](https://github.com/surrealdb/surrealdb.js), [Rust](https://github.com/surrealdb/surrealdb/tree/main/crates/sdk), and [.NET](https://github.com/surrealdb/surrealdb.net).

## Requirements

- Julia 1.9+
- Remote: SurrealDB server v2.x or v3.x
- Embedded: `libsurreal` from [`surrealdb/surrealdb.c`](https://github.com/surrealdb/surrealdb.c)

## Testing

```bash
# SDK suite (fast, offline, prereq-self-skipping):
julia --project=test test/runtests.jl

# Conformance suites (cross-SDK + upstream language-tests + wire):
bash scripts/setup-upstream.sh
bash scripts/setup-server.sh
bash scripts/run-conformance.sh

# Surgical iteration on a single file:
julia --project=test test/sdk/cbor/test_cbor_io.jl
```

Unit layer needs no network; integration needs `surreal start --bind 127.0.0.1:8001`; embedded needs `libsurreal`.
Layers self-skip when prerequisites are missing.

## Development

```
scripts/setup-upstream.sh      # clone upstream test corpus (sparse-blobless)
scripts/setup-sdk-refs.sh      # clone peer SDKs (Go/Py/JS/.NET) for reference reading
scripts/setup-server.sh        # provision surreal binary
scripts/regen-cbor-fixtures.sh # regenerate Rust CBOR fixtures (run after corpus changes)
scripts/run-conformance.sh     # orchestrate the conformance suites
```

All idempotent and identical local/CI.

## Roadmap

- `libsurrealdb_c_jll`: pre-built dylibs via Yggdrasil for one-line `Pkg.add`.
- Cross-SDK interop matrix: extend the Python / Go fixture harness to cover JS and Rust × JSON × CBOR × every Surreal type.
- General registry submission once API stabilizes.

## License

MIT. See [LICENSE](LICENSE).
