# Sessions and transactions

## Transactions

For SurrealDB v2 servers, the RPC-level helpers work:

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

For **v3+ remote servers**, the `begin!` / `commit!` / `cancel!` RPC methods expect a session-scoped transaction UUID.
Prefer raw SurrealQL:

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
