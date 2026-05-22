# SurrealDB.jl

[![Test](https://github.com/danvinci/surrealdb/actions/workflows/test.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/test.yml)
[![Benchmark](https://github.com/danvinci/surrealdb/actions/workflows/bench.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/bench.yml)
[![Interop](https://github.com/danvinci/surrealdb/actions/workflows/interop.yml/badge.svg)](https://github.com/danvinci/surrealdb/actions/workflows/interop.yml)
[![Docs](https://github.com/danvinci/surrealdb/actions/workflows/docs.yml/badge.svg)](https://danvinci.github.io/surrealdb/)
[![codecov](https://codecov.io/gh/danvinci/surrealdb/branch/main/graph/badge.svg)](https://codecov.io/gh/danvinci/surrealdb)

Julia client for [SurrealDB](https://surrealdb.com).
Talks to a remote `surreal` server over WebSocket or HTTP, or runs the database in-process via `libsurreal`.
Same API regardless of backend.
Default wire is CBOR.

**Status: alpha.** Pre-1.0.
API may break between minor versions (`0.x` → `0.(x+1)`).
Pin a specific version to avoid breakage between bumps.

## Install

Not yet in the General registry.
Install via the repo URL, pinned to a tagged release:

```julia
using Pkg
Pkg.add(url="https://github.com/danvinci/surrealdb", rev="v0.2.0-alpha.1")
```

The embedded backend needs `libsurreal`.
See [Embedded mode](#embedded-mode) below.

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
| `mem://`, `memory://` | Embedded | In-memory, in-process via `libsurreal` |
| `surrealkv://path` | Embedded | File-backed, in-process |

The `mem://` / `memory://` and `surrealkv://path` schemes are URL conventions shared with the official [JS](https://github.com/surrealdb/surrealdb.js), [Python](https://github.com/surrealdb/surrealdb.py), and [.NET](https://github.com/surrealdb/surrealdb.net) SDKs.
They tell `connect()` to load `libsurreal` and run in-process instead of opening a socket.
`mem://` and `memory://` are aliases for the same in-memory backend.

### Wire format

CBOR is the default.
Typed values round-trip without loss: `Decimal`, nanosecond `DateTime` and `Duration`, all seven GeoJSON geometry shapes, `RecordID`, `Table`, `FileRef`, `Range`.
JSON is available for debug or legacy peers:

```julia
SurrealDB.connect("ws://localhost:8000"; wire=:json)
```

On JSON, typed values lower to canonical strings (`Decimal` → numeric string, `DateTime` → ISO 8601, `Geometry` → GeoJSON object, etc.).

### Embedded mode

Requires the `libsurreal` shared library.
Build it once from [`surrealdb/surrealdb.c`](https://github.com/surrealdb/surrealdb.c):

```bash
julia --project=. deps/build_libsurreal.jl
```

Needs a Rust toolchain (`cargo`) and ~15 min of build time.
The resulting `libsurrealdb_c.{so,dylib,dll}` lands at the repo root.

```julia
SurrealDB.libsurreal_load!("/path/to/libsurrealdb_c.dylib")  # or set $SURREALDB_LIB
db = SurrealDB.connect("mem://")
```

A JLL package (`libsurrealdb_c_jll`) for one-line install via the registry is planned.
See [Roadmap](#roadmap).

## Auth

```julia
SurrealDB.signin!(db, SurrealDB.RootAuth("root", "root"))

SurrealDB.signin!(db, SurrealDB.NamespaceAuth("ns", "user", "pass"))

SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "account",
                                           Dict("email" => "a@b.c", "pass" => "x")))

SurrealDB.authenticate!(db, jwt_token)

SurrealDB.invalidate!(db)
```

If the WebSocket drops mid-session, the SDK re-issues `use ns/db`, `authenticate(token)`, every `let!` variable, and every live subscription on reconnect before flipping `status` back to `STATUS_CONNECTED`.

### Refresh tokens

For scoped access methods that issue refresh tokens (`DEFINE ACCESS ... WITH REFRESH`), `signin!`/`signup!` store both the access JWT and the refresh token.
A timer exchanges the refresh token for a new pair `refresh_lead_time` seconds before the access JWT expires.

```julia
db = SurrealDB.connect("ws://localhost:8000";
                       refresh_lead_time=30.0,
                       auth=SurrealDB.ScopedAuth("ns", "db", "account",
                                                  Dict("email"=>"a@b.c", "pass"=>"x")))

SurrealDB.tokens(db)     # Tokens(access="eyJ…", refresh="abc…")
SurrealDB.refresh!(db)   # manual rotation; returns the new access JWT
```

`refresh!` throws `NotAllowedError` when no refresh token is available.
The proactive timer skips while a reconnect is in flight; the reconnect path re-schedules.

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

`RecordID`, `Date`, `DateTime`, `UUID`, `SurrealDecimal`, `SurrealDuration`, `SurrealFile`, `SurrealRange`, and the seven `Geometry*` shapes round-trip automatically.
Nested `Dict`/`Vector` recurse into nested structs.

## Tables.jl

Query results conform to `Tables.jl`, so they plug into DataFrames, CSV.jl, Arrow.jl, or anything that consumes the Tables interface:

```julia
using DataFrames
result = SurrealDB.query_table(db, "SELECT name, age FROM user")
df = DataFrame(result)
```

`query_one(db, sql)` asserts a single statement and returns one table.
`query_table(db, sql)` returns one `QueryResultTable` per `;`-separated statement on remote.
The embedded backend flattens them into a single result.

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

Each notification is a `LiveNotification` with typed fields (`action`, `query_id`, `record`, `result`, `session`).
It also subtypes `AbstractDict`, so `n["action"]` still works.
After a reconnect the SDK re-issues `LIVE SELECT` and overwrites `sub.query_id` with the new server-assigned UUID, so caller-held handles keep working.

**Server-initiated KILLED.** When the server kills a subscription (DDL change, resource limit, admin action), the subscriber observes a final notification with `action == "KILLED"` and the channel closes; the `@async for` loop exits cleanly.
Client-initiated `kill!` does not produce this notification.

## Verbose multi-statement queries

`query()` returns the unwrapped happy path and throws on the first server-side error.
For multi-statement transactions, batch ingestion, or per-statement performance profiling, `query_verbose()` returns one `QueryStatement` per server-reported statement and never throws on `:err`:

```julia
stmts = SurrealDB.query_verbose(db, """
    BEGIN TRANSACTION;
    UPDATE inventory:sku123 SET qty = qty - 5;
    CREATE order CONTENT { item: 'sku123', qty: 5 };
    COMMIT TRANSACTION;
""")

filter(SurrealDB.iserr, stmts)   # statements that failed
filter(SurrealDB.isok, stmts)    # statements that succeeded
```

Each `QueryStatement` carries `.status` (`:ok` / `:err`), server-reported `.time`, the parsed `.result`, and a typed `.error::ServerError` on failure.
Transport-level errors still propagate as exceptions.

## Running functions

```julia
SurrealDB.run(db, "fn::greet", ["world"])
```

`run()` invokes user-defined functions (`fn::*`).
Built-in SurrealQL functions like `type::is::array` are SQL-only and must go through `query()`.

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

For **v3+ remote servers**, the `begin!`/`commit!`/`cancel!` RPC methods expect a session-scoped transaction UUID; prefer raw SurrealQL:

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

Available via a Pkg extension.
Loads automatically when `MetaGraphsNext` and `Graphs` are present in your environment alongside `SurrealDB`:

```julia
using SurrealDB, MetaGraphsNext, Graphs
g = SurrealDB.to_metagraph(db,
        "SELECT id, name FROM user",
        "SELECT id, in, out FROM follows")
```

Vertex labels are `RecordID` strings; vertex and edge data are field dicts.
The SDK does not auto-coerce results into a graph.

## Errors

```
SurrealError
├── ServerError              (server-reported, kind-tagged)
│   ├── ValidationError          .parameter_name, .is_parse_error
│   ├── ConfigurationError       .is_live_query_not_supported
│   ├── ThrownError
│   ├── QueryError               .is_timed_out, .is_cancelled
│   ├── SerializationError       .is_deserialization
│   ├── NotAllowedError          .is_token_expired, .is_invalid_auth, .method_name
│   ├── NotFoundError            .table_name, .record_id, .namespace_name
│   ├── AlreadyExistsError       .table_name, .record_id
│   └── InternalError
├── RPCError                     (legacy / unknown JSON-RPC code)
├── ConnectionError              (transport-level: drop, timeout)
├── ConnectionUnavailableError
├── UnsupportedEngineError       .scheme
├── UnsupportedFeatureError      .feature, .transport
├── UnsupportedVersionError      .server_version, .minimum, .maximum
├── UnexpectedResponseError
└── EmbeddedFFIError             .op, .message
```

Catch a specific subtype for branch logic, or catch `ServerError` to handle any server-side failure uniformly:

```julia
try
    SurrealDB.create(db, "user:alice", Dict(...))
catch e::SurrealDB.AlreadyExistsError
    @info "already exists" table=e.table_name record=e.record_id
catch e::SurrealDB.ServerError
    @warn "server failure" e
end
```

The wire-format `kind` field maps to the Julia subtype.
Older servers that emit only a JSON-RPC `code` go through a code-to-kind table.

## Reconnect

WebSocket connections auto-reconnect on drop.
Tune via `connect` kwargs:

```julia
db = SurrealDB.connect("ws://localhost:8000";
    reconnect = true,                # false disables retries
    reconnect_max_attempts = 10,
    reconnect_base_delay = 0.5,      # seconds; exponential backoff
    reconnect_max_delay = 30.0,
    reconnect_jitter = 0.1,          # fraction of delay added randomly (0..1)
    ping_interval = 30.0,            # seconds; 0 disables keepalive
    rpc_timeout = 30.0,              # seconds; Inf disables per-RPC timeout
    refresh_lead_time = 30.0,        # seconds before JWT expiry to refresh
    wire = :cbor,                    # or :json
    check_version = true,            # skip server-version probe at connect
    logger = SurrealDB.NullLogger(),
)
```

### Lifecycle observability

```julia
ch = SurrealDB.events(db)
@async for ev::SurrealDB.LifecycleEvent in ch
    @info "lifecycle" status=ev.status attempt=ev.attempt cause=ev.cause
end
```

Each `LifecycleEvent` carries the status being transitioned into, the reconnect attempt count (0 on first connect), the triggering exception if any, and a `time()` timestamp.

For inline structured logging, pass an `FnLogger` at connect:

```julia
db = SurrealDB.connect(url; logger=SurrealDB.FnLogger(ev ->
    @info "surrealdb" status=ev.status attempt=ev.attempt cause=ev.cause))
```

`STATUS_CONNECTED` fires after state replay (`use!`, `authenticate!`, `let!` variables, live re-subscription) finishes, not before.
Observers never see a half-restored session.

## Debugging

RPC traces emit on Julia's `@debug` channel.
Enable with `JULIA_DEBUG=SurrealDB`:

```
┌ Debug: SurrealDB ws RPC → rid=2 method=use params=Any["test", "test"]
┌ Debug: SurrealDB ws RPC ← rid=2 has_error=false
```

## Requirements

- Julia 1.9 or newer
- Remote: SurrealDB server v2.x or v3.x
- Embedded: `libsurreal` from [`surrealdb/surrealdb.c`](https://github.com/surrealdb/surrealdb.c) (see [Embedded mode](#embedded-mode) for build instructions)

## Testing

```bash
julia --project=test test/runtests.jl
```

The suite has three layers:

- **Unit** (no network): types, error parser, FFI marshalling, reconnect state machine, CBOR codec parity vs `ciborium`, integration tests against an in-process mock WebSocket server, MetaGraphsNext extension.
- **Integration** (needs `surreal start --bind 127.0.0.1:8001`): connection lifecycle, auth, query, methods, sessions, live queries.
- **Embedded** (needs `libsurreal`): full FFI roundtrip.

Layers self-skip when their prerequisite is missing.

Cross-tested against the official [Go](https://github.com/surrealdb/surrealdb.go) and [Python](https://github.com/surrealdb/surrealdb.py) SDKs today: 12 testsets ported from `surrealdb.go/db_test.go`, plus an interop harness round-tripping fixtures (Python ↔ Julia, Julia → Go).
The comparative reference set also includes [JS](https://github.com/surrealdb/surrealdb.js), [Rust](https://github.com/surrealdb/surrealdb/tree/main/crates/sdk), and [.NET](https://github.com/surrealdb/surrealdb.net); JS + Rust cross-tests are planned (see [Roadmap](#roadmap)).

## Roadmap

- `libsurrealdb_c_jll`: ship pre-built dylibs via Yggdrasil for one-line `Pkg.add` install and CI speedup.
- Live-server CBOR shakedown across TLS / test-remote workflows.
- Cross-SDK interop matrix: extend the Python / Go fixture harness to cover JS and Rust × JSON × CBOR × every Surreal type.
- General registry submission once API stabilizes.

## License

MIT. See [LICENSE](LICENSE).
