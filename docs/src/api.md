# API Reference

Auto-generated from docstrings. Every exported symbol is listed below.

## Connection

```@docs
SurrealDB.connect
SurrealDB.close!
SurrealDB.status
SurrealDB.events
SurrealDB.SurrealClient
SurrealDB.AbstractConnection
SurrealDB.RemoteConnection
SurrealDB.RemoteWSConnection
SurrealDB.RemoteHTTPConnection
SurrealDB.EmbeddedConnection
```

## Connection lifecycle and observability

```@docs
SurrealDB.ConnectionStatus
SurrealDB.STATUS_DISCONNECTED
SurrealDB.STATUS_CONNECTING
SurrealDB.STATUS_CONNECTED
SurrealDB.STATUS_RECONNECTING
SurrealDB.LifecycleEvent
SurrealDB.AbstractSurrealLogger
SurrealDB.NullLogger
SurrealDB.FnLogger
```

## Authentication

```@docs
SurrealDB.signin!
SurrealDB.signup!
SurrealDB.authenticate!
SurrealDB.invalidate!
SurrealDB.refresh!
SurrealDB.tokens
SurrealDB.Tokens
SurrealDB.RootAuth
SurrealDB.NamespaceAuth
SurrealDB.ScopedAuth
SurrealDB.JwtAuth
```

## Database scope

```@docs
SurrealDB.use!
SurrealDB.info
SurrealDB.version
SurrealDB.health
```

## Query and CRUD

```@docs
SurrealDB.query
SurrealDB.query_verbose
SurrealDB.QueryStatement
SurrealDB.isok
SurrealDB.iserr
SurrealDB.query_table
SurrealDB.query_one
SurrealDB.create
SurrealDB.select
SurrealDB.update
SurrealDB.delete
SurrealDB.insert
SurrealDB.upsert
SurrealDB.merge
SurrealDB.relate
SurrealDB.insert_relation
SurrealDB.patch
SurrealDB.patch_add
SurrealDB.patch_remove
SurrealDB.patch_replace
SurrealDB.run
SurrealDB.ping
SurrealDB.let!
SurrealDB.unset!
```

## Live queries

```@docs
SurrealDB.live
SurrealDB.kill!
SurrealDB.LiveSubscription
SurrealDB.LiveNotification
```

## Transactions and sessions

```@docs
SurrealDB.begin!
SurrealDB.commit!
SurrealDB.cancel!
SurrealDB.attach!
SurrealDB.detach!
SurrealDB.sessions
SurrealDB.SurrealSession
```

## Import / Export

```@docs
SurrealDB.export_db
SurrealDB.import_db
```

## Embedded mode

```@docs
SurrealDB.libsurreal_load!
```

## Tables.jl and graph extensions

```@docs
SurrealDB.to_table
SurrealDB.to_metagraph
SurrealDB.QueryResultTable
```

## Core types

```@docs
SurrealDB.RecordID
SurrealDB.StringRecordID
SurrealDB.@rid_str
SurrealDB.SurrealThing
SurrealDB.Table
SurrealDB.SurrealValue
SurrealDB.Relationship
```

### Record-id forms

Three ways to address a specific record:

- `RecordID(table, id)` — programmatic; id may be any serializable Julia value (String, Int, Vector, Dict). Encoded as CBOR `Tag(8, [table, key])`; round-trips with full type fidelity.
- `rid"table:id"` — string-macro shorthand for the literal case. Parses at compile time; rejects multi-colon strings and empty parts.
- [`StringRecordID`](@ref) — opaque wrapper for the rare case where the id syntax needs the server's parser (escaped colons, ranges, nested objects). One-way send only; decode always materializes typed `RecordID`.

Passing a plain `String` containing `:` to a record-op method raises `ArgumentError` — no silent reinterpretation as a table name.

## Wire-format types

```@docs
SurrealDB.SurrealDecimal
SurrealDB.SurrealDateTime
SurrealDB.SurrealDuration
SurrealDB.SurrealFile
SurrealDB.SurrealRange
SurrealDB.BoundIncluded
SurrealDB.BoundExcluded
SurrealDB.GeometryPoint
SurrealDB.GeometryLine
SurrealDB.GeometryPolygon
SurrealDB.GeometryMultiPoint
SurrealDB.GeometryMultiLine
SurrealDB.GeometryMultiPolygon
SurrealDB.GeometryCollection
```

### NONE vs NULL

SurrealDB distinguishes two no-value sentinels on the server:

- `NONE` — field is unset / does not exist
- `NULL` — field is explicitly set to null

Julia is the one language across the official SurrealDB SDKs with a structural fit for both: the SDK maps `NONE → missing` and `NULL → nothing`. Peer SDKs (Python, Go, JS, .NET, Rust) all collapse both to a single sentinel; only Julia preserves the distinction.

On read, expect either:

```julia
result = SurrealDB.query(client, "RETURN \$maybe_unset")
isnothing(result[1]) || ismissing(result[1])   # NONE or NULL
```

On write, both Julia sentinels round-trip semantically:

```julia
SurrealDB.create(client, "tbl", Dict("x" => missing))   # → server stores NONE
SurrealDB.create(client, "tbl", Dict("x" => nothing))   # → server stores NULL
```

## Errors

```@docs
SurrealDB.SurrealError
SurrealDB.ServerError
SurrealDB.RPCError
SurrealDB.QueryError
SurrealDB.ValidationError
SurrealDB.ConfigurationError
SurrealDB.ThrownError
SurrealDB.SerializationError
SurrealDB.NotAllowedError
SurrealDB.NotFoundError
SurrealDB.AlreadyExistsError
SurrealDB.InternalError
SurrealDB.ConnectionError
SurrealDB.ConnectionUnavailableError
SurrealDB.UnsupportedEngineError
SurrealDB.UnsupportedFeatureError
SurrealDB.UnsupportedVersionError
SurrealDB.UnexpectedResponseError
SurrealDB.EmbeddedFFIError
```
