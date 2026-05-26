# Sessions and transactions

## Transactions

For SurrealDB v2 servers, the client-level RPC helpers work:

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

For **v3+ remote servers**, transactions are session-scoped.
[`begin!(session)`](@ref) returns a [`SurrealTransaction`](@ref) wrapper holding the server-side txn UUID and a `closed::Bool` guard, so a stale handle can't be re-committed:

```julia
session = SurrealDB.attach!(db)
try
    txn = SurrealDB.begin!(session)
    try
        SurrealDB.query(session.client, "CREATE user CONTENT { name: 'Bob' }")
        SurrealDB.commit!(txn)
    catch
        SurrealDB.cancel!(txn)
        rethrow()
    end
finally
    SurrealDB.close!(session)
end
```

Statements inside the transaction body run through `session.client` for now; first-class `session.query(...)` / `txn.query(...)` forwarding is on the roadmap.
For larger transactional bodies, write SurrealQL directly:

```julia
SurrealDB.query(db, """
    BEGIN TRANSACTION;
    CREATE user CONTENT { name: 'Bob' };
    COMMIT TRANSACTION;
""")
```

## Session variables

`let!` / `unset!` work the same on both server versions:

```julia
SurrealDB.let!(db, "min_age", 18)
SurrealDB.query(db, "SELECT * FROM user WHERE age >= \$min_age")
SurrealDB.unset!(db, "min_age")
```

Session variables persist through reconnects: the SDK replays each `let!` on the new socket as part of state restoration.

## Multi-statement queries

[`query()`](@ref) returns the unwrapped happy path and throws on the first server-side error.
For multi-statement transactions, batch ingestion, or per-statement profiling, [`query_verbose()`](@ref) returns one [`QueryStatement`](@ref) per server-reported statement and never throws on `:err`:

```julia
stmts = SurrealDB.query_verbose(db, """
    BEGIN TRANSACTION;
    UPDATE inventory:sku123 SET qty = qty - 5;
    CREATE order CONTENT { item: 'sku123', qty: 5 };
    COMMIT TRANSACTION;
""")

filter(SurrealDB.iserr, stmts)
filter(SurrealDB.isok, stmts)
```

Each `QueryStatement` carries `.status` (`:ok` / `:err`), server-reported `.time`, the parsed `.result`, and a typed `.error::ServerError` on failure.
Transport-level errors still propagate as exceptions.

## Sessions (v3+)

[`attach!`](@ref) / [`detach!`](@ref) bind a server-side session to the client.
See the API reference for the full surface.
