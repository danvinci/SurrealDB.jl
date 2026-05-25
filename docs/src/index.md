# SurrealDB.jl

Julia client for [SurrealDB](https://surrealdb.com).
Talks to a remote `surreal` server over WebSocket or HTTP, or runs the database in-process via `libsurreal`.
Same API regardless of backend.
Default wire is CBOR.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/danvinci/surrealdb", rev="v0.2.0-alpha.1")
```

Status: alpha (pre-1.0).

## Guide

- [Record IDs](records.md) — `RecordID(t, i)`, `rid"t:i"` macro, `StringRecordID`
- [Wire format](wire.md) — CBOR + JSON, typed round-trips, NONE / NULL
- [Authentication](auth.md) — root / namespace / scoped, refresh tokens, state replay
- [Live queries](live.md) — subscriptions, reconnect handling, server-initiated KILLED
- [Transactions](transactions.md) — v2 RPC, v3 SurrealQL, session variables
- [Reconnect](reconnect.md) — tuning, lifecycle observability
- [Errors](errors.md) — typed hierarchy
- [Integrations](integrations.md) — StructTypes, Tables.jl, MetaGraphsNext
- [Debugging](debugging.md) — `@debug` channel, FFI errors

[API Reference](api.md) covers every exported symbol with its docstring.
[GitHub repo](https://github.com/danvinci/surrealdb) hosts source, README, and issues.
