# Live query subscriptions for SurrealDB.jl

# --- LiveNotification ---

"""
    LiveNotification(action, query_id, record, result, session)

One live-query event delivered to a [`LiveSubscription`](@ref) channel.
Subtype of `AbstractDict{String, Any}` so legacy `n["action"]` access keeps
working alongside the typed `n.action` form.

Fields:
- `action::String`: `"CREATE"`, `"UPDATE"`, or `"DELETE"` (`"KILLED"` events are dropped by the dispatcher)
- `query_id::String`: live UUID matching `sub.query_id`
- `record::Union{String, Nothing}`: affected record id, e.g. `"users:abc"`
- `result::Any`: payload — the record on CREATE/UPDATE, the pre-delete record on DELETE
- `session::Union{String, Nothing}`: v3 session id; `nothing` on v2
"""
struct LiveNotification <: AbstractDict{String, Any}
    action::String
    query_id::String
    record::Union{String, Nothing}
    result::Any
    session::Union{String, Nothing}
end

function LiveNotification(d::AbstractDict)
    LiveNotification(
        string(get(d, "action", "")),
        string(get(d, "id", "")),
        _opt_string(get(d, "record", nothing)),
        get(d, "result", nothing),
        _opt_string(get(d, "session", nothing)),
    )
end

_opt_string(x) = isnothing(x) ? nothing : string(x)

# AbstractDict interface — backwards-compat dict access.
const _LIVE_NOTIF_KEYS = ("action", "id", "record", "result", "session")
Base.length(::LiveNotification) = 5
Base.keys(::LiveNotification) = _LIVE_NOTIF_KEYS
function Base.haskey(::LiveNotification, k)
    s = k isa AbstractString ? String(k) : string(k)
    return s in _LIVE_NOTIF_KEYS
end
function Base.getindex(n::LiveNotification, k)
    s = k isa AbstractString ? String(k) : string(k)
    s == "action"  && return n.action
    s == "id"      && return n.query_id
    s == "record"  && return n.record
    s == "result"  && return n.result
    s == "session" && return n.session
    throw(KeyError(k))
end
function Base.get(n::LiveNotification, k, default)
    s = k isa AbstractString ? String(k) : string(k)
    s == "action"  && return n.action
    s == "id"      && return n.query_id
    s == "record"  && return n.record
    s == "result"  && return n.result
    s == "session" && return n.session
    return default
end
function Base.iterate(n::LiveNotification, state=1)
    state > 5 && return nothing
    p = state == 1 ? ("action"  => n.action)    :
        state == 2 ? ("id"      => n.query_id)  :
        state == 3 ? ("record"  => n.record)    :
        state == 4 ? ("result"  => n.result)    :
                     ("session" => n.session)
    return p, state + 1
end

function Base.show(io::IO, n::LiveNotification)
    rec = isnothing(n.record) ? "-" : n.record
    print(io, "LiveNotification(", n.action, " ", rec, ")")
end

# --- LiveSubscription ---

"""
    LiveSubscription(query_id, channel, client)

A live query subscription. Iterate over `sub.channel` (or `sub` directly) to
receive [`LiveNotification`](@ref) events. Call `kill!(sub)` to terminate.

Fields:
- `query_id::String`: UUID string identifying the live query on the server
- `channel::Channel`: receives `LiveNotification` events
- `active::Bool`: subscription state
"""
mutable struct LiveSubscription
    query_id::String
    channel::Channel
    client::Any                                    # SurrealClient (avoid circular dep)
    active::Bool
end

function Base.show(io::IO, sub::LiveSubscription)
    state = sub.active ? "active" : "killed"
    print(io, "LiveSubscription(", sub.query_id, ", ", state, ")")
end

# Iterate the underlying notification channel directly so callers can write
# `for n in sub` instead of `for n in sub.channel`. Matches Channel's own
# iteration semantics: blocks waiting for the next message; ends when the
# channel closes (via `kill!`).
Base.IteratorSize(::Type{LiveSubscription}) = Base.SizeUnknown()
Base.eltype(::Type{LiveSubscription}) = Any
Base.iterate(sub::LiveSubscription, state...) = iterate(sub.channel, state...)

"""
    live(client, table; diff=false)

Start a live query subscription on a table.

Returns a [`LiveSubscription`](@ref) with a `channel` field you can iterate over
to receive real-time notifications.

- `table`: Table name (String or [`Table`](@ref))
- `diff`: If `true`, notifications include the diff between old and new values

# Examples
```julia
sub = SurrealDB.live(db, "stream")
for notification in sub.channel
    println("Action: ", notification["action"])
    println("Data: ", notification["data"])
    break  # or loop forever
end
SurrealDB.kill!(sub)
```
"""
function live(client::SurrealClient{C}, table; diff::Bool=false) where {C<:AbstractConnection}
    result = _rpc_call(client, "live", Any[table, diff])
    query_id = result isa String ? result : string(result)
    sub = LiveSubscription(query_id, Channel{Any}(32), client, true)
    _register_live!(client.connection, sub, table, diff)
    return sub
end

"""
    kill!(client, query_id::String)

Terminate a live query by its UUID. If a [`LiveSubscription`](@ref) handle was
registered for this id (i.e. created via [`live`](@ref)), its `active` flag is
flipped to `false` and its channel is closed so consumers iterating it observe
the termination.
"""
function kill!(client::SurrealClient{C}, query_id::String) where {C<:AbstractConnection}
    # Tear down local state first so sub.active is always flipped, even if the
    # RPC call fails (e.g. embedded path sends a pointer string as the UUID).
    sub = _deregister_live!(client.connection, query_id)
    if !isnothing(sub)
        sub.active = false
        try; close(sub.channel); catch; end
    end
    _rpc_call(client, "kill", Any[query_id])
    return nothing
end

"""
    kill!(sub::LiveSubscription)

Terminate a live query subscription. Delegates to [`kill!`](@ref) by id, which
flips `sub.active` and closes the channel.
"""
function kill!(sub::LiveSubscription)
    kill!(sub.client, sub.query_id)
    return nothing
end

"""
    subscribe(sub::LiveSubscription) -> LiveSubscription

Register an additional consumer on `sub`'s server-side live query. The returned
subscription shares `query_id` with the input but holds a fresh `channel`;
both channels receive every notification (fan-out at the SDK level).

`kill!(original_sub)` (or `kill!(client, query_id)`) tears down ALL subscribers
sharing the UUID — per-consumer teardown is not supported. WS-only.

```julia
sub  = SurrealDB.live(db, "stream")
sub2 = SurrealDB.subscribe(sub)
@async for n in sub.channel;  process(n); end    # consumer A
@async for n in sub2.channel; log(n);     end    # consumer B
SurrealDB.kill!(sub)                              # both channels close
```
"""
function subscribe(sub::LiveSubscription)
    sub.active || throw(ArgumentError(
        "subscribe: source LiveSubscription is no longer active."))
    client = sub.client
    isnothing(client) && throw(ArgumentError(
        "subscribe: source LiveSubscription has no client (unregistered handle)."))
    client.connection isa RemoteWSConnection || throw(UnsupportedFeatureError(
        :subscribe, :embedded))

    ch = Channel{Any}(32)
    new_sub = LiveSubscription(sub.query_id, ch, client, true)
    conn = client.connection
    lock(conn.live_lock) do
        chs = get!(conn.notification_channels, sub.query_id, Channel[])
        push!(chs, ch)
    end
    return new_sub
end

# Stub — concrete method added by embedded.jl (qualified as
# `SurrealDB._poll_embedded_live`) so dispatch crosses the module boundary.
# Backend-specific live registration/deregistration stubs live in
# connection.jl alongside `_close_backend!` / `_use_backend!`.
function _poll_embedded_live end
