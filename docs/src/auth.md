# Authentication

Four signin variants cover the SurrealDB auth surface:

```julia
SurrealDB.signin!(db, SurrealDB.RootAuth("root", "root"))

SurrealDB.signin!(db, SurrealDB.NamespaceAuth("ns", "user", "pass"))

SurrealDB.signin!(db, SurrealDB.ScopedAuth("ns", "db", "account",
    Dict("email" => "a@b.c", "pass" => "x")))

SurrealDB.authenticate!(db, jwt_token)
SurrealDB.invalidate!(db)
```

## State replay on reconnect

If the WebSocket drops mid-session, the SDK replays the session state on reconnect before flipping status back to `STATUS_CONNECTED`:

1. `use ns/db`
2. `authenticate(token)`
3. Every `let!` session variable
4. Every live subscription (re-issues `LIVE SELECT`, overwrites `sub.query_id`)

Observers never see a half-restored session.

## Refresh tokens

Scoped access methods that issue refresh tokens (`DEFINE ACCESS ... WITH REFRESH`) cause `signin!`/`signup!` to store both the access JWT and the refresh token as a [`Tokens`](@ref) value.
A background timer exchanges the refresh token for a new pair `refresh_lead_time` seconds before the access JWT expires:

```julia
db = SurrealDB.connect("ws://localhost:8000";
    refresh_lead_time = 30.0,
    auth = SurrealDB.ScopedAuth("ns", "db", "account",
        Dict("email" => "a@b.c", "pass" => "x")))

SurrealDB.tokens(db)     # Tokens(access="eyJ…", refresh="abc…")
SurrealDB.refresh!(db)   # manual rotation; returns the new access JWT
```

[`refresh!`](@ref) throws `NotAllowedError` when no refresh token is available.
The proactive timer skips while a reconnect is in flight; the reconnect path re-schedules.
