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

    # Create channel for notifications
    ch = Channel{Any}(32)
    sub = LiveSubscription(query_id, ch, client, true)

    # Register channel + handle on the connection so kill!-by-id can find it.
    # All three live-query Dicts are mutated under one lock per backend to
    # serialize against concurrent kill! and (WS only) the reconnect loop.
    if client.connection isa RemoteWSConnection
        lock(client.connection.live_lock) do
            client.connection.notification_channels[query_id] = ch
            client.connection.live_subscriptions[query_id] = (table, diff)
            client.connection.live_handles[query_id] = sub
        end
    elseif client.connection isa EmbeddedConnection
        lock(client.connection.lock) do
            client.connection.live_handles[query_id] = sub
        end
        # Embedded mode: spawn a task to poll the stream
        @async _poll_embedded_live(client.connection, query_id, ch)
    end

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
    sub = nothing
    if client.connection isa RemoteWSConnection
        sub = lock(client.connection.live_lock) do
            delete!(client.connection.notification_channels, query_id)
            delete!(client.connection.live_subscriptions, query_id)
            pop!(client.connection.live_handles, query_id, nothing)
        end
    elseif client.connection isa EmbeddedConnection
        sub = lock(client.connection.lock) do
            pop!(client.connection.live_handles, query_id, nothing)
        end
    end
    if sub !== nothing
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

# Stub — concrete method added by embedded.jl (qualified as
# `SurrealDB._poll_embedded_live`) so dispatch crosses the module boundary.
function _poll_embedded_live end
