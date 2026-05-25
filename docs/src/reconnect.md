# Reconnect and lifecycle

WebSocket connections auto-reconnect on drop.
HTTP connections are stateless; no reconnect logic applies.

## Tuning

```julia
db = SurrealDB.connect("ws://localhost:8000";
    reconnect = true,                # false disables retries
    reconnect_max_attempts = 10,
    reconnect_base_delay = 0.5,      # seconds; exponential backoff
    reconnect_max_delay = 30.0,
    reconnect_jitter = 0.1,          # fraction of delay added randomly (0..1)
    ping_interval = 30.0,            # seconds; 0 disables keepalive
    rpc_timeout = 30.0,              # seconds; Inf disables per-RPC timeout
    refresh_lead_time = 30.0,        # seconds before JWT expiry to refresh
    wire = :cbor,                    # or :json
    check_version = true,            # skip server-version probe at connect
    logger = SurrealDB.NullLogger(),
)
```

## Lifecycle observability

```julia
ch = SurrealDB.events(db)
@async for ev::SurrealDB.LifecycleEvent in ch
    @info "lifecycle" status=ev.status attempt=ev.attempt cause=ev.cause
end
```

Each [`LifecycleEvent`](@ref) carries the status being transitioned into, the reconnect attempt count (0 on first connect), the triggering exception if any, and a `time()` timestamp.

For inline structured logging, pass an [`FnLogger`](@ref) at connect:

```julia
db = SurrealDB.connect(url;
    logger = SurrealDB.FnLogger(ev ->
        @info "surrealdb" status=ev.status attempt=ev.attempt cause=ev.cause))
```

[`STATUS_CONNECTED`](@ref) fires after state replay (`use!`, `authenticate!`, `let!` variables, live re-subscription) finishes.
Observers never see a half-restored session.
