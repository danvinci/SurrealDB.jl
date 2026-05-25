# Live queries

```julia
sub = SurrealDB.live(db, "user")
task = @async for n::SurrealDB.LiveNotification in sub
    @info "live event" action=n.action record=n.record data=n.result
end

SurrealDB.kill!(sub)   # closes the channel; the @async for-loop exits
wait(task)
```

Each notification is a [`LiveNotification`](@ref) with typed fields (`action`, `query_id`, `record`, `result`, `session`).
It also subtypes `AbstractDict`, so `n["action"]` works as well.

## Reconnect behavior

After a reconnect the SDK re-issues `LIVE SELECT` and overwrites `sub.query_id` with the new server-assigned UUID.
Caller-held handles keep working without re-subscription.

## Server-initiated KILLED

When the server kills a subscription (DDL change, resource limit, admin action), the subscriber observes a final notification with `action == "KILLED"` and the channel closes.
The `@async for` loop exits cleanly.

Client-initiated `kill!` does not produce this final notification — the channel just closes.
