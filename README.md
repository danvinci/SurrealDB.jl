# SurrealDB.jl

[![Test](https://github.com/danvinci/surrealdb/actions/workflows/test.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/test.yml)
[![Benchmark](https://github.com/danvinci/surrealdb/actions/workflows/bench.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/bench.yml)
[![Interop](https://github.com/danvinci/surrealdb/actions/workflows/interop.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/interop.yml)
[![Docs](https://github.com/danvinci/surrealdb/actions/workflows/docs.yml/badge.svg)](https://danvinci.github.io/surrealdb/)
[![codecov](https://codecov.io/gh/danvinci/surrealdb/branch/main/graph/badge.svg)](https://codecov.io/gh/danvinci/surrealdb)

Julia client for [SurrealDB](https://surrealdb.com). Talks to a remote
`surreal` server over WebSocket or HTTP, or runs the database in-process
via `libsurreal`. Same API regardless of backend. Runs against SurrealDB
v2 and v3.

**Status: alpha.** Pre-1.0. API may break between minor versions
(`0.x` → `0.(x+1)`). Pin a specific version to avoid breakage between
bumps.

## Install

Not yet in the General registry. Install via the repo URL, pinned to a
tagged release:

```julia
using Pkg
Pkg.add(url="https://github.com/danvinci/surrealdb", rev="v0.2.0-alpha.1")
```

For the embedded backend you also need `libsurreal`. See
[Embedded mode](#embedded-mode) below.

## Quickstart

```julia
using SurrealDB

db = SurrealDB.connect("ws://localhost:8000";
                       ns="test", db="test",
                       auth=SurrealDB.RootAuth("root", "root"))

alice = SurrealDB.create(db, "user", Dict("name" => "Alice", "age" => 30))
users = SurrealDB.select(db, "user")
SurrealDB.update(db, alice["id"], Dict("age" => 31))
SurrealDB.delete(db, alice["id"])

results = SurrealDB.query(db, "SELECT * FROM user WHERE age > 18")

SurrealDB.close!(db)
```

### Do-block form

```julia
SurrealDB.connect("ws://localhost:8000"; ns="test", db="test") do db
    SurrealDB.query(db, "SELECT * FROM stream")
end
```

The client is closed in a `finally`.

## Connection modes

| URL scheme | Backend | Notes |
|---|---|---|
| `ws://`, `wss://` | Remote WS | Live queries, sessions, transactions, ping, auto-reconnect |
| `http://`, `https://` | Remote HTTP | Stateless. `live()` raises `UnsupportedFeatureError` |
| `mem://` | Embedded | In-memory, in-process via `libsurreal` |
| `surrealkv://path` | Embedded | File-backed, in-process |

The `mem://` and `surrealkv://path` schemes are SDK conventions (not part
of SurrealDB's wire protocol). They tell `connect()` to load `libsurreal`
instead of opening a socket.

### Embedded mode

Requires the `libsurreal` shared library. Build it once from
[`surrealdb/surrealdb.c`](https://github.com/surrealdb/surrealdb.c):

```bash
julia --project=. deps/build_libsurreal.jl
```

Needs a Rust toolchain (`cargo`) and ~15 min of build time. The resulting
`libsurrealdb_c.{so,dylib,dll}` lands at the repo root.

```julia
SurrealDB.libsurreal_load!("/path/to/libsurrealdb_c.dylib")  # or set $SURREALDB_LIB
db = SurrealDB.connect("mem://")
```

A JLL package (`libsurrealdb_c_jll`) for one-line install via the registry
is planned. See [Roadmap](#roadmap).

## Auth

```julia
SurrealDB.signin!(db, SurrealDB.RootAuth("root", "root"))

SurrealDB.signin!(db, SurrealDB.NamespaceAuth("ns", "user", "pass"))

SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "account",
                                           Dict("email" => "a@b.c", "pass" => "x")))

SurrealDB.authenticate!(db, jwt_token)

SurrealDB.invalidate!(db)
```

If the WebSocket drops mid-session, the SDK re-issues `use ns/db` and
`authenticate(token)` on reconnect before flipping `status` back to
`STATUS_CONNECTED`.

## Typed responses (StructTypes.jl)

```julia
using StructTypes
struct User
    id::SurrealDB.RecordID
    name::String
    age::Int
end
StructTypes.StructType(::Type{User}) = StructTypes.Struct()

users = SurrealDB.select(db, User, "user")
alice = SurrealDB.create(db, User, "user",
                         Dict("name" => "Alice", "age" => 30))
```

`RecordID`, `Date`, `DateTime`, and `UUID` round-trip automatically. Nested
`Dict`/`Vector` recurse into nested structs.

## Tables.jl

Query results conform to `Tables.jl`, so they plug into DataFrames, CSV.jl,
Arrow.jl, or anything that consumes the Tables interface:

```julia
using DataFrames
result = SurrealDB.query_table(db, "SELECT name, age FROM user")
df = DataFrame(result)
```

`query_one(db, sql)` asserts a single statement and returns one table.
`query_table(db, sql)` returns one `QueryResultTable` per `;`-separated
statement on remote. The embedded backend flattens them into a single
result.

## Live queries

```julia
sub = SurrealDB.live(db, "user")
task = @async for n::SurrealDB.LiveNotification in sub
    @info "live event" action=n.action record=n.record data=n.result
end

# Stop the subscription:
SurrealDB.kill!(sub)   # closes the channel; the @async for-loop exits
wait(task)
```

Each notification is a `LiveNotification` with typed fields
(`action`, `query_id`, `record`, `result`, `session`). It also subtypes
`AbstractDict`, so `n["action"]` still works. After a reconnect the SDK
re-issues `LIVE SELECT` and overwrites `sub.query_id` with the new
server-assigned UUID, so caller-held handles keep working.

## Running functions

```julia
SurrealDB.run(db, "fn::greet", ["world"])
```

`run()` invokes user-defined functions (`fn::*`). Builtin SurrealQL
functions like `type::is::array` are SQL-only and must go through
`query()`.

## Sessions and transactions

For v2 servers, the RPC-level helpers work:

```julia
SurrealDB.begin!(db)
try
    SurrealDB.create(db, "user", Dict("name" => "Bob"))
    SurrealDB.commit!(db)
catch
    SurrealDB.cancel!(db)
    rethrow()
end
```

For **v3+ remote servers**, the `begin!`/`commit!`/`cancel!` RPC methods
expect a session-scoped transaction UUID; prefer raw SurrealQL:

```julia
SurrealDB.query(db, """
    BEGIN TRANSACTION;
    CREATE user CONTENT { name: 'Bob' };
    COMMIT TRANSACTION;
""")
```

Session variables (`let!`/`unset!`) work the same way on both:

```julia
SurrealDB.let!(db, "min_age", 18)
SurrealDB.query(db, "SELECT * FROM user WHERE age >= \$min_age")
SurrealDB.unset!(db, "min_age")
```

## Graph traversal (MetaGraphsNext)

Available via a Pkg extension. Loads automatically when `MetaGraphsNext`
and `Graphs` are present in your environment alongside `SurrealDB`:

```julia
using SurrealDB, MetaGraphsNext, Graphs
g = SurrealDB.to_metagraph(db,
        "SELECT id, name FROM user",
        "SELECT id, in, out FROM follows")
```

Vertex labels are `RecordID` strings; vertex and edge data are field
dicts. The SDK does not auto-coerce results into a graph.

## Errors

```
SurrealError
├── ServerError          (server-reported, kind-tagged)
│   ├── ValidationError      .parameter_name, .is_parse_error
│   ├── ConfigurationError   .is_live_query_not_supported
│   ├── ThrownError
│   ├── QueryError           .is_timed_out, .is_cancelled
│   ├── SerializationError   .is_deserialization
│   ├── NotAllowedError      .is_token_expired, .is_invalid_auth, .method_name
│   ├── NotFoundError        .table_name, .record_id, .namespace_name
│   ├── AlreadyExistsError   .table_name, .record_id
│   └── InternalError
├── RPCError                  (legacy / unknown JSON-RPC code)
├── ConnectionError           (transport-level: drop, timeout)
├── ConnectionUnavailableError
├── UnsupportedEngineError    .scheme
├── UnsupportedFeatureError   .feature, .transport
├── UnexpectedResponseError
└── EmbeddedFFIError          .op, .message
```

Catch a specific subtype for branch logic, or catch `ServerError` to
handle any server-side failure uniformly:

```julia
try
    SurrealDB.create(db, "user:alice", Dict(...))
catch e::SurrealDB.AlreadyExistsError
    @info "already exists" table=e.table_name record=e.record_id
catch e::SurrealDB.ServerError
    @warn "server failure" e
end
```

The wire-format `kind` field maps to the Julia subtype. Older servers
that emit only a JSON-RPC `code` go through a code-to-kind table.

## Reconnect

WebSocket connections auto-reconnect on drop. Tune via `connect` kwargs:

```julia
db = SurrealDB.connect("ws://localhost:8000";
    reconnect = true,            # false disables retries
    reconnect_max_attempts = 10,
    reconnect_base_delay = 0.5,  # seconds; exponential backoff
    reconnect_max_delay = 30.0,
    reconnect_jitter = 0.1,      # fraction of delay added randomly (0..1)
    ping_interval = 30.0,        # seconds; 0 disables keepalive
    rpc_timeout = 30.0,          # seconds; Inf disables per-RPC timeout
)
```

Subscribe to lifecycle:

```julia
ch = SurrealDB.events(db)
@async for ev::SurrealDB.ConnectionStatus in ch
    @info "lifecycle" event=ev
    # ev ∈ (STATUS_CONNECTING, STATUS_CONNECTED, STATUS_RECONNECTING, STATUS_DISCONNECTED)
end
```

`STATUS_CONNECTED` fires after state replay (`use!`, `authenticate!`, live
re-subscription) finishes, not before. Observers never see a half-restored
session.

## Debugging

RPC traces emit on Julia's `@debug` channel. Enable with
`JULIA_DEBUG=SurrealDB`:

```
┌ Debug: SurrealDB ws RPC → rid=2 method=use params=Any["test", "test"]
┌ Debug: SurrealDB ws RPC ← rid=2 has_error=false
```

## Requirements

- Julia 1.9 or newer
- Remote: SurrealDB server v2.x or v3.x
- Embedded: `libsurreal` from [`surrealdb/surrealdb.c`](https://github.com/surrealdb/surrealdb.c)
  (see [Embedded mode](#embedded-mode) for build instructions)

## Testing

```bash
julia --project=. test/runtests.jl
```

The suite has three layers:

- **Unit** (no network): types, error parser, FFI marshalling,
  reconnect state machine, integration tests against an in-process
  mock WebSocket server, MetaGraphsNext extension.
- **Integration** (needs `surreal start --bind 127.0.0.1:8001`):
  connection lifecycle, auth, query, methods, sessions, live queries.
- **Embedded** (needs `libsurreal`): full FFI roundtrip.

Layers self-skip when their prerequisite is missing.

Also cross-tested against the official
[Go](https://github.com/surrealdb/surrealdb.go) and
[Python](https://github.com/surrealdb/surrealdb.py) SDKs: 12 testsets
ported from `surrealdb.go/db_test.go`, plus an interop harness
round-tripping fixtures (Python ↔ Julia, Julia → Go).

## Roadmap

- `libsurrealdb_c_jll`: ship pre-built dylibs via Yggdrasil for
  one-line `Pkg.add` install and CI speedup.
- CBOR transport: smaller payloads, native Duration/Decimal round-trip.
- General registry submission once API stabilizes.

## License

MIT. See [LICENSE](LICENSE).
