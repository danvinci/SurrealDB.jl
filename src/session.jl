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
    attach!(client)

Create a new ephemeral session on the server (SurrealDB v3+).

Returns a `UUID` session identifier. The session is independent — it has its
own namespace, database, auth, and variables. Use [`detach!`](@ref) to clean up.

WebSocket-only (not supported on HTTP connections).
"""
function attach!(client::SurrealClient{<:RemoteWSConnection})
    sid = UUIDs.uuid4()
    _rpc_call(client, "attach", Any[]; session=sid)
    return sid
end

"""
    detach!(client, session_id::UUID)

Destroy a server-side session (SurrealDB v3+).

After detaching, the session cannot be used for further operations.
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
end

"""
    begin!(session::SurrealSession)

Start a transaction within a v3+ session.

Returns the transaction UUID. Pass this to [`commit!`](@ref) or [`cancel!`](@ref).
"""
function begin!(session::SurrealSession{<:RemoteWSConnection})
    result = _rpc_call(session.client, "begin", Any[]; session=session.session_id)
    txn_id = result isa String ? UUIDs.UUID(result) :
             result isa UUIDs.UUID ? result : UUIDs.UUID(string(result))
    return txn_id
end

"""
    commit!(session::SurrealSession, txn_id)

Commit a transaction within a v3+ session.
"""
function commit!(session::SurrealSession{<:RemoteWSConnection}, txn_id)
    _rpc_call(session.client, "commit", Any[]; session=session.session_id, txn=txn_id)
    return nothing
end

"""
    cancel!(session::SurrealSession, txn_id)

Cancel/rollback a transaction within a v3+ session.
"""
function cancel!(session::SurrealSession{<:RemoteWSConnection}, txn_id)
    _rpc_call(session.client, "cancel", Any[]; session=session.session_id, txn=txn_id)
    return nothing
end
