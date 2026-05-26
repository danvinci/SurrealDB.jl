# Session variable management for SurrealDB.jl

"""
    let!(client, key::String, value)

Set a session variable. These variables can be referenced in SurrealQL queries
using `\$key` syntax.

# Examples
```julia
SurrealDB.let!(db, "min_age", 18)
result = SurrealDB.query(db, "SELECT * FROM user WHERE age > \$min_age")
```
"""
function let!(client::SurrealClient{C}, key::String, value) where {C<:AbstractConnection}
    _rpc_call(client, "let", Any[key, value])
    client.variables[key] = value
    return nothing
end

"""
    unset!(client, key::String)

Remove a previously set session variable.
"""
function unset!(client::SurrealClient{C}, key::String) where {C<:AbstractConnection}
    _rpc_call(client, "unset", Any[key])
    delete!(client.variables, key)
    return nothing
end

# --- v3+ Sessions (attach/detach) ---

"""
    attach!(client) -> SurrealSession

Create a new ephemeral session on the server (SurrealDB v3+) and return a
[`SurrealSession`](@ref) wrapper. The session is independent: its own
namespace, database, auth, and variables. Close with [`close!`](@ref).

Matches the wrapped-session API used by surrealdb-go (`db.Attach`),
surrealdb-py (`AsyncSurrealSession` / `BlockingSurrealSession`), and
surrealdb-js (`newSession`).

WebSocket-only (not supported on HTTP connections).
"""
function attach!(client::SurrealClient{C}) where {C<:RemoteWSConnection}
    sid = UUIDs.uuid4()
    _rpc_call(client, "attach", Any[]; session=sid)
    return SurrealSession{C}(client, sid, false)
end

"""
    detach!(client, session_id::UUID)

Destroy a server-side session by raw UUID (SurrealDB v3+). Prefer
[`close!`](@ref) on a [`SurrealSession`](@ref); use this when you only have
a bare UUID (e.g. from [`sessions`](@ref) listing).
"""
function detach!(client::SurrealClient{<:RemoteWSConnection}, session_id)
    _rpc_call(client, "detach", Any[]; session=session_id)
    return nothing
end

"""
    sessions(client)

List active session UUIDs on the server (SurrealDB v3+).

Returns `Vector{UUID}`.
"""
function sessions(client::SurrealClient{<:RemoteWSConnection})
    result = _rpc_call(client, "sessions", Any[])
    # Server may return UUID strings, raw IDs, or other shapes depending on
    # version. Try parse-as-UUID; for anything that doesn't parse, keep the
    # raw string so callers can still work with it.
    out = UUIDs.UUID[]
    for id in result
        s = id isa String ? id : string(id)
        try
            push!(out, UUIDs.UUID(s))
        catch e
            e isa ArgumentError || rethrow()
            # Skip ill-formed entries rather than failing the whole call
            @debug "sessions: skipping non-UUID id" id=s
        end
    end
    return out
end

"""
    SurrealSession

A v3+ server-side session wrapping a SurrealClient.

Fields:
- `client::SurrealClient` — the underlying connection
- `session_id::UUID` — the server-assigned session identifier

All operations on this session are scoped to the session's namespace, database,
auth, and variables.
"""
mutable struct SurrealSession{C<:AbstractConnection}
    client::SurrealClient{C}
    session_id::UUID
    "Set to `true` by `close!`; session-bound RPCs check this and throw
     `ConnectionUnavailableError` rather than silently routing to a detached
     server-side session id."
    closed::Bool
end

Base.show(io::IO, s::SurrealSession) = print(io, "SurrealSession(", s.session_id, ")")

# Closed-lifecycle guard. Mirrors `_check_open(::SurrealClient)`; checks both
# the wrapped client AND the session's own closed flag.
function _check_open(s::SurrealSession)
    _check_open(s.client)
    s.closed && throw(ConnectionUnavailableError(
        "SurrealSession has been closed; create a new session via `attach!(client)`."))
    return nothing
end

"""
    close!(session::SurrealSession)

Destroy the server-side session. After closing, the session must not be used.
Wraps [`detach!`](@ref).
"""
function close!(session::SurrealSession{<:RemoteWSConnection})
    session.closed && return nothing  # idempotent
    try
        detach!(session.client, session.session_id)
    finally
        session.closed = true
    end
    return nothing
end

"""
    SurrealTransaction

A v3+ interactive transaction handle. Returned by [`begin!(session)`](@ref).
Call [`commit!(txn)`](@ref) or [`cancel!(txn)`](@ref) to finalize; either
flips `txn.closed = true` so a stale handle can't be re-committed against a
server-side transaction that no longer exists.

Matches the wrapper pattern used by surrealdb-go (`Transaction` struct with
`closed bool`, sdk-refs/go/transaction.go:24) and surrealdb-js
(`SurrealTransaction extends SurrealQueryable`, sdk-refs/js/.../api/transaction.ts:13).
"""
mutable struct SurrealTransaction{C<:AbstractConnection}
    session::SurrealSession{C}
    txn_id::UUID
    closed::Bool
end

Base.show(io::IO, t::SurrealTransaction) =
    print(io, "SurrealTransaction(", t.txn_id, t.closed ? ", closed" : "", ")")

function _check_open(t::SurrealTransaction)
    _check_open(t.session)
    t.closed && throw(ConnectionUnavailableError(
        "SurrealTransaction has already been committed or cancelled."))
    return nothing
end

"""
    begin!(session::SurrealSession) -> SurrealTransaction

Start a transaction within a v3+ session. Returns a [`SurrealTransaction`](@ref)
handle; pass it to [`commit!`](@ref) or [`cancel!`](@ref) to finalize.
"""
function begin!(session::SurrealSession{C}) where {C<:RemoteWSConnection}
    _check_open(session)
    result = _rpc_call(session.client, "begin", Any[]; session=session.session_id)
    txn_id = result isa String ? UUIDs.UUID(result) :
             result isa UUIDs.UUID ? result : UUIDs.UUID(string(result))
    return SurrealTransaction{C}(session, txn_id, false)
end

"""
    commit!(txn::SurrealTransaction)

Commit a v3+ session transaction. Flips `txn.closed = true` even if the RPC
throws, so a stale handle can't be re-used.
"""
function commit!(txn::SurrealTransaction{<:RemoteWSConnection})
    _check_open(txn)
    try
        _rpc_call(txn.session.client, "commit", Any[];
                  session=txn.session.session_id, txn=txn.txn_id)
    finally
        txn.closed = true
    end
    return nothing
end

"""
    cancel!(txn::SurrealTransaction)

Cancel/rollback a v3+ session transaction. Flips `txn.closed = true` even if
the RPC throws.
"""
function cancel!(txn::SurrealTransaction{<:RemoteWSConnection})
    _check_open(txn)
    try
        _rpc_call(txn.session.client, "cancel", Any[];
                  session=txn.session.session_id, txn=txn.txn_id)
    finally
        txn.closed = true
    end
    return nothing
end
