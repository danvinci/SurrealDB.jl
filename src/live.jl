# Live query subscriptions for SurrealDB.jl

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
