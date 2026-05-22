# Connection layer — abstract types and remote WebSocket/HTTP backend

# --- Abstract connection type ---

"""
    AbstractConnection

Abstract base type for SurrealDB connection backends.
Concrete implementations: [`RemoteWSConnection`](@ref), [`RemoteHTTPConnection`](@ref) (both `<: AbstractRemoteConnection`), and `EmbeddedConnection` (in `SurrealDB.Embedded`).
"""
abstract type AbstractConnection end

"""
    AbstractRemoteConnection <: AbstractConnection

Common supertype for remote-server backends ([`RemoteWSConnection`](@ref) and
[`RemoteHTTPConnection`](@ref)). Methods that work over either transport
(query, create, select, etc.) dispatch on this; transport-specific methods
(live queries, sessions, pinger) dispatch on the concrete type so HTTP-only
restrictions surface as `MethodError` at the API boundary instead of runtime
`ConnectionError`.
"""
abstract type AbstractRemoteConnection <: AbstractConnection end

# Forward declaration so the const aliases below can reference the parametric
# type. Defined below in full.
"""
    RemoteWSConnection = RemoteConnection{:ws}
    RemoteHTTPConnection = RemoteConnection{:http}

Remote-connection types, parametric on the transport tag (`P` = `:ws` or
`:http`) and the wire format (`W` = `:json` or `:cbor`). The aliases above
are UnionAll wildcards over `W` — `RemoteWSConnection` matches both
`RemoteConnection{:ws, :json}` and `RemoteConnection{:ws, :cbor}`. Methods
that care only about the transport dispatch on the alias; methods that
care about the wire add a `W` parameter (see `src/wire.jl`).
"""

# --- Remote connection ---

"""
    ConnectionStatus

Connection lifecycle states. Used by [`RemoteConnection.status`](@ref), the
[`events`](@ref) channel, and [`status`](@ref).

Values:
- `STATUS_DISCONNECTED`: no active session (initial state, or after `close!`).
- `STATUS_CONNECTING`: first-ever connect attempt in progress.
- `STATUS_CONNECTED`: session established; RPCs can flow.
- `STATUS_RECONNECTING`: lost session, reconnect loop attempting recovery.
"""
@enum ConnectionStatus::UInt8 begin
    STATUS_DISCONNECTED
    STATUS_CONNECTING
    STATUS_CONNECTED
    STATUS_RECONNECTING
end

"""
    LifecycleEvent

Structured payload emitted on the [`events`](@ref) channel per connection
state transition. Carries the transition target status plus reconnect
diagnostics so operators can reason about reconnect storms without scraping
ad-hoc `@warn` lines.

Fields:
- `status::ConnectionStatus` — the state being transitioned INTO.
- `attempt::Int` — `0` on first connect; reconnect attempt N (1-based) thereafter.
- `cause::Union{Exception, Nothing}` — the error that triggered
  `STATUS_RECONNECTING` / `STATUS_DISCONNECTED`, if any.
- `timestamp::Float64` — `time()` at emission, for relative duration measurements.
"""
struct LifecycleEvent
    status::ConnectionStatus
    attempt::Int
    cause::Union{Exception, Nothing}
    timestamp::Float64
end

LifecycleEvent(status::ConnectionStatus;
               attempt::Int=0,
               cause::Union{Exception, Nothing}=nothing,
               timestamp::Float64=time()) =
    LifecycleEvent(status, attempt, cause, timestamp)

function Base.show(io::IO, ev::LifecycleEvent)
    print(io, "LifecycleEvent(", ev.status, ", attempt=", ev.attempt,
              ", cause=")
    if ev.cause === nothing
        print(io, "nothing")
    else
        # `repr` keeps the cause on one line (no stack trace) and quotes
        # message strings so operators can grep for them.
        print(io, repr(ev.cause))
    end
    print(io, ")")
end

# --- Logger interface (optional plumb-through) ---

"""
    AbstractSurrealLogger

Supertype for observability hooks invoked synchronously on each
[`LifecycleEvent`](@ref) emission. Pass via `connect(...; logger=...)`.
Concrete implementations: [`NullLogger`](@ref) (default, no-op),
[`FnLogger`](@ref) (forwards to a user function).

The logger callback runs on the calling task (the reconnect loop or the
connect entry path). Long-running loggers should hand off to their own
task; the emit path catches exceptions and warns instead of propagating.
"""
abstract type AbstractSurrealLogger end

"""
    NullLogger()

Default no-op `AbstractSurrealLogger`. Drops every event.
"""
struct NullLogger <: AbstractSurrealLogger end

(::NullLogger)(::LifecycleEvent) = nothing

"""
    FnLogger(fn)

Forwards each [`LifecycleEvent`](@ref) to a user-supplied function
`fn(event::LifecycleEvent) -> nothing`. Invoked synchronously on the
calling task — see [`AbstractSurrealLogger`](@ref).
"""
struct FnLogger <: AbstractSurrealLogger
    fn::Function
end

(l::FnLogger)(ev::LifecycleEvent) = l.fn(ev)


"""
    RemoteConnection(url)

A remote connection to a SurrealDB server via WebSocket or HTTP.

URL schemes accepted:
- `ws://host:port` / `wss://host:port` — WebSocket (primary, stateful)
- `http://host:port` / `https://host:port` — HTTP (stateless)
"""
Base.@kwdef mutable struct RemoteConnection{P, W} <: AbstractRemoteConnection
    "URL the client was constructed with — `ws://...`, `wss://...`, `http://...`, or `https://...`"
    url::String = ""
    "Open WebSocket handle (only used when `P == :ws`); `nothing` when disconnected or HTTP"
    ws::Union{Any, Nothing} = nothing
    "Base HTTP URL (only used when `P == :http`)"
    http_base_url::String = ""
    "Guards `request_id` and `response_channels` against concurrent writers"
    lock::ReentrantLock = ReentrantLock()
    "Monotonic counter for JSON-RPC request ids"
    request_id::Int = 0
    "Lifecycle: `STATUS_DISCONNECTED` / `STATUS_CONNECTING` / `STATUS_CONNECTED` / `STATUS_RECONNECTING`"
    status::ConnectionStatus = STATUS_DISCONNECTED
    "request_id → response Channel; reader task delivers responses via these"
    response_channels::Dict{Int, Channel} = Dict{Int, Channel}()
    "Writer task drains this channel and writes to the WS socket; `nothing` until first connect"
    write_channel::Union{Channel, Nothing} = nothing
    "live query_id → notification Channel"
    notification_channels::Dict{String, Channel} = Dict{String, Channel}()
    "Guards the three live-query Dicts (notification_channels, live_subscriptions, live_handles) against concurrent registration/teardown across reconnect, kill!, and the WS reader"
    live_lock::ReentrantLock = ReentrantLock()
    "live query_id → (table, diff) — used by `_reconnect_apply_state!` to re-issue subscriptions on reconnect. `table` is stored as the caller-supplied type (`String` / `Table` / `RecordID`) so reconnect replay preserves CBOR tag fidelity."
    live_subscriptions::Dict{String, Tuple{Any, Bool}} = Dict{String, Tuple{Any, Bool}}()
    "live query_id → LiveSubscription handle — used by `kill!(client, qid)` to flip caller-held state"
    live_handles::Dict{String, LiveSubscription} = Dict{String, LiveSubscription}()
    "Background reader task; drains WS messages and dispatches to response/notification channels"
    reader_task::Union{Task, Nothing} = nothing
    "Back-reference to the SurrealClient — used by reconnect to re-apply auth/use!/live state"
    client::Any = nothing
    # --- Reconnection ---
    "If `false`, dropped connections do NOT auto-reconnect"
    reconnect::Bool = true
    "Max consecutive reconnect attempts before giving up; resets to 0 on successful connect"
    reconnect_max_attempts::Int = 10
    "Base delay (seconds) for exponential backoff: delay = base * 2^(attempt - 2)"
    reconnect_base_delay::Float64 = 0.5
    "Cap on the exponential backoff delay (seconds)"
    reconnect_max_delay::Float64 = 30.0
    "Random jitter factor [0, 1] applied to each backoff sleep to avoid thundering-herd"
    reconnect_jitter::Float64 = 0.1
    "Ping keepalive interval (seconds); set to 0 to disable"
    ping_interval::Float64 = 30.0
    "Background ping task; cancelled and replaced on each reconnect"
    pinger_task::Union{Task, Nothing} = nothing
    "Active pinger Timer; closed by `_stop_pinger!` to interrupt the in-flight `wait` and exit the loop"
    pinger_timer::Union{Timer, Nothing} = nothing
    "Lifecycle-event Channel — emits [`LifecycleEvent`](@ref) values on state transitions, carrying status + reconnect attempt + cause. Subscribe via [`events`](@ref). Drop-in compatible with the JS SDK's `subscribe('connected', ...)` pattern (status field carries the bare ConnectionStatus)."
    events::Channel{LifecycleEvent} = Channel{LifecycleEvent}(64)
    "Last exception observed by the reconnect loop. Used to surface a meaningful cause when `connect()` times out instead of a bare \"Failed to connect\" string."
    last_error::Union{Exception, Nothing} = nothing
    "Whether to verify TLS certificates on `wss://` connections. Default `true`. Set to `false` for self-signed certs in test/CI environments — never disable in production."
    tls_verify::Bool = true
    "Maximum time (seconds) `_rpc_call` will wait for a response before throwing `ConnectionError`. Prevents indefinite hangs when a request reaches the server but no response is delivered (e.g. server bug, malformed response that fails id-routing). Set to `Inf` to disable."
    rpc_timeout::Float64 = 30.0
    # --- Proactive token refresh ---
    "Active refresh-timer; cancelled on close!, replaced on every new signin/signup/refresh. `nothing` when the current access token has no parseable `exp` claim or no refresh token to spend."
    refresh_timer::Union{Timer, Nothing} = nothing
    "How many seconds before the access token's `exp` claim to fire the proactive refresh. Default 30s — wide enough to absorb RTT and clock skew, narrow enough that revocations surface quickly."
    refresh_lead_time::Float64 = 30.0
    "Optional structured logger invoked synchronously on every lifecycle event. Default [`NullLogger`](@ref) (no-op). Pass [`FnLogger`](@ref) to forward to a user callback; long-running loggers should hand off to their own task."
    logger::AbstractSurrealLogger = NullLogger()
end

const RemoteWSConnection = RemoteConnection{:ws}
const RemoteHTTPConnection = RemoteConnection{:http}

# Defaulting outer constructor: `RemoteConnection{:ws}(...)` (and the
# `RemoteWSConnection` / `RemoteHTTPConnection` aliases over it) fill in
# `W = :json` so test sites and pre-CBOR call paths that construct without
# specifying a wire format keep working. New CBOR call sites construct via
# the fully-parameterized form `RemoteConnection{:ws, :cbor}(...)`.
RemoteConnection{P}(; kwargs...) where {P} = RemoteConnection{P, :json}(; kwargs...)

# --- Client struct ---

"""
    SurrealClient{C<:AbstractConnection}

The main client type for interacting with a SurrealDB database.

Generic over the connection backend type `C`. Create via [`connect`](@ref).

# Examples
```julia
db = SurrealDB.connect("ws://localhost:8000")
SurrealDB.use!(db, "test", "test")
result = SurrealDB.query(db, "SELECT * FROM stream")
```
"""
mutable struct SurrealClient{C<:AbstractConnection}
    "Underlying transport — RemoteConnection (WS/HTTP) or EmbeddedConnection"
    connection::C
    "Currently selected namespace; set via `use!` or auto-applied on reconnect"
    namespace::Union{String, Nothing}
    "Currently selected database; set via `use!` or auto-applied on reconnect"
    database::Union{String, Nothing}
    "JWT token from the most recent successful signin/authenticate; `nothing` when unauthenticated. Mirrors `tokens.access` when `tokens !== nothing` — kept as a flat String for reconnect-replay simplicity."
    token::Union{String, Nothing}
    "Typed access+refresh pair when the server issued one (`WITH REFRESH` scopes); `nothing` otherwise. Public accessor: [`tokens`](@ref)."
    tokens::Union{Tokens, Nothing}
    "Session variables set via `let!` — used for state inspection and reconnect re-application"
    variables::Dict{String, Any}
end

function Base.show(io::IO, c::SurrealClient)
    auth = c.token === nothing ? "unauth" : "auth"
    ns = c.namespace === nothing ? "-" : c.namespace
    db = c.database === nothing ? "-" : c.database
    print(io, "SurrealClient(", _conn_descr(c.connection),
              ", ns=", ns, ", db=", db, ", ", auth, ")")
end

_conn_descr(conn::RemoteWSConnection) = "ws[$(conn.status)]"
_conn_descr(conn::RemoteHTTPConnection) = "http[$(conn.status)]"
_conn_descr(conn::AbstractConnection) = "embedded"

function Base.show(io::IO, conn::RemoteWSConnection)
    print(io, "RemoteWSConnection(", conn.url, ", ", conn.status, ")")
end

function Base.show(io::IO, conn::RemoteHTTPConnection)
    print(io, "RemoteHTTPConnection(", conn.url, ", ", conn.status, ")")
end

# --- URL scheme parsing ---

function _parse_scheme(url::String)
    m = match(r"^(mem(?:ory)?|surrealkv|ws|wss|http|https)://", url)
    if m === nothing
        # Extract the scheme prefix (or report the whole URL if there isn't one)
        scheme = match(r"^([a-zA-Z][a-zA-Z0-9+.-]*)://", url)
        bad = scheme === nothing ? url : String(something(scheme.captures[1], url))
        throw(UnsupportedEngineError(bad))
    end
    scheme = m.captures[1]
    if scheme == "memory" || scheme == "mem"
        return :mem
    elseif scheme == "surrealkv"
        return :surrealkv
    elseif scheme == "ws"
        return :ws
    elseif scheme == "wss"
        return :wss
    elseif scheme == "http"
        return :http
    elseif scheme == "https"
        return :https
    end
    # Unreachable: the regex above only matches the schemes above
    throw(ArgumentError("Unsupported URL scheme: $url"))
end

# --- Internal helpers (stubs, filled by agents) ---

# --- WebSocket connect with reconnection ---

"""
    _emit_lifecycle!(conn::RemoteConnection, status::ConnectionStatus;
                     attempt::Int=0, cause::Union{Exception,Nothing}=nothing)

Update `conn.status` and emit a [`LifecycleEvent`](@ref) on `conn.events`.
Best-effort channel emission via `@async`: full or closed channels never
block the caller.

Dedup: same-status calls are skipped UNLESS `attempt` changed — so a
3rd reconnect attempt still emits even if the status was already
`STATUS_RECONNECTING`.

The connection's `logger` is invoked SYNCHRONOUSLY on the calling task;
exceptions from the logger are caught and surfaced via `@warn` rather
than propagated.
"""
function _emit_lifecycle!(conn::RemoteConnection, status::ConnectionStatus;
                          attempt::Int=0,
                          cause::Union{Exception, Nothing}=nothing)
    old = conn.status
    conn.status = status
    # Same-status-same-attempt is the no-op dedup; same-status-different-attempt
    # still emits so observers see retry progress.
    if old == status && attempt == 0
        return nothing
    end
    ev = LifecycleEvent(status, attempt, cause, time())
    @async try
        isopen(conn.events) && put!(conn.events, ev)
    catch e
        e isa InvalidStateException || rethrow()
    end
    # Logger fires SYNCHRONOUSLY on the calling task. Wrap in try/catch so a
    # misbehaving user callback can't crash the reconnect loop or the connect
    # entry path; surface failures as @warn instead.
    try
        conn.logger(ev)
    catch e
        @warn "SurrealDB lifecycle logger threw" exception=e event=ev
    end
    return nothing
end

# Thin shim: pre-LifecycleEvent call sites used `_set_status!(conn, status)`.
# Forwarded as a 0-attempt, no-cause emission. New code should call
# `_emit_lifecycle!` directly so attempt/cause threading is explicit.
_set_status!(conn::RemoteConnection, status::ConnectionStatus) =
    _emit_lifecycle!(conn, status)

function _connect_remote!(conn::RemoteHTTPConnection)
    _emit_lifecycle!(conn, STATUS_CONNECTED; attempt=0, cause=nothing)
    return nothing
end

function _connect_remote!(conn::RemoteWSConnection)
    conn.reader_task = @async _ws_reconnect_loop(conn)
    return nothing
end

# --- WebSocket close ---

function _close_remote!(conn::RemoteConnection)
    conn.reconnect = false
    _set_status!(conn, STATUS_DISCONNECTED)
    # Cancel any in-flight refresh Timer so its callback doesn't fire on a
    # dead client. Safe across both transports (field lives on RemoteConnection).
    _stop_refresh_timer!(conn)
    # _stop_pinger! has no method for HTTP — short-circuit here.
    if conn isa RemoteHTTPConnection
        return nothing
    end
    _stop_pinger!(conn)
    # Close WS before signalling writer — otherwise reader blocks on receive(ws) until server timeout.
    if conn.ws !== nothing
        try; HTTP.WebSockets.close(conn.ws); catch; end
    end
    # Shutdown sentinel: empty payload of the channel's element type. The
    # writer treats any empty msg as "exit." For a `Channel{String}` push
    # `""`; for `Channel{Vector{UInt8}}` push `UInt8[]`.
    try
        ch = conn.write_channel
        if ch isa Channel{Vector{UInt8}}
            put!(ch, UInt8[])
        elseif ch isa Channel
            put!(ch, "")
        end
    catch
    end
    try
        close(conn.write_channel)
    catch
    end
    # Wait for reconnect loop to unwind — rapid connect/close/connect cycles
    # accumulate dangling reader tasks otherwise. 2s cap prevents permanent hang.
    rt = conn.reader_task
    if rt !== nothing && !istaskdone(rt)
        deadline = time() + 2.0
        while !istaskdone(rt) && time() < deadline
            sleep(0.02)
        end
    end
    conn.reader_task = nothing
    conn.ws = nothing
    return nothing
end

# --- RPC call ---

function _rpc_call_remote(client::SurrealClient{<:RemoteHTTPConnection}, method::String, params::Vector{Any};
                         session=nothing, txn=nothing)
    return _rpc_call_http(client, method, params; session=session, txn=txn)
end

function _rpc_call_remote(client::SurrealClient{<:RemoteWSConnection}, method::String, params::Vector{Any};
                         session=nothing, txn=nothing)
    return _rpc_call_ws(client, method, params; session=session, txn=txn)
end


# --- Scoping / auth helpers (thin wrappers that use conn.client) ---

function _use_remote!(conn::RemoteHTTPConnection, ns::String, db_name::String)
    # HTTP is stateless — ns/db is stored on the client + prepended per query
    return nothing
end

function _use_remote!(conn::RemoteWSConnection, ns::String, db_name::String)
    _rpc_call(conn.client, "use", Any[ns, db_name])
end

function _signin_remote!(conn::RemoteConnection, params)
    _rpc_call(conn.client, "signin", Any[params])
end

function _authenticate_remote!(conn::RemoteConnection, token::String)
    _rpc_call(conn.client, "authenticate", Any[token])
end

function _invalidate_remote!(conn::RemoteConnection)
    _rpc_call(conn.client, "invalidate", Any[])
end

# --- Public API ---

"""
    connect(url::String; ns=nothing, db=nothing, token=nothing, auth=nothing)
    connect(f::Function, url::String; kwargs...)

Connect to a SurrealDB instance. The URL scheme determines the backend:

| URL scheme | Backend | Description |
|---|---|---|
| `ws://host:port` | Remote WS | WebSocket (stateful) |
| `http://host:port` | Remote HTTP | HTTP (stateless) |
| `mem://` | Embedded | In-memory database |
| `surrealkv://path` | Embedded | File-backed database |

Keyword arguments:
- `ns`, `db`: Namespace and database to select after connecting
- `token`: JWT token for authentication
- `auth`: Auth struct ([`RootAuth`](@ref), [`NamespaceAuth`](@ref), etc.) for signin
- `reconnect::Bool=true`: Auto-reconnect on socket drop (WS only)
- `reconnect_max_attempts::Int=10`: Consecutive failures before giving up
- `reconnect_base_delay::Float64=0.5`: Initial backoff (exponential, in seconds)
- `reconnect_max_delay::Float64=30.0`: Cap on the backoff delay
- `reconnect_jitter::Float64=0.1`: Random jitter factor [0,1] applied to each backoff
- `ping_interval::Float64=30.0`: Keepalive cadence; `0` disables
- `tls_verify::Bool=true`: Verify TLS certs on `wss://`. Set `false` only for self-signed test certs
- `rpc_timeout::Float64=30.0`: Max seconds to wait for an RPC response; `Inf` disables
- `refresh_lead_time::Float64=30.0`: How far before the access token's `exp` claim to fire the proactive refresh. Only active when the server issued a refresh token (`WITH REFRESH` scopes); otherwise no timer is scheduled.
- `wire::Symbol=:cbor`: Wire format — `:cbor` (default, binary, type-faithful) or `:json` (text, legacy/debug). Selected at connect time; baked into the connection's type parameter for compile-time codec dispatch. Embedded connections ignore this parameter.
- `check_version::Bool=true`: After the socket comes up, probe `version()` and throw [`UnsupportedVersionError`](@ref) if the server is below [`MINIMUM_SERVER_VERSION`](@ref). Set `false` for development against unreleased server builds.
- `logger::AbstractSurrealLogger=NullLogger()`: Synchronous observability hook for lifecycle events. Pass [`FnLogger`](@ref) to forward to a user callback. Runs on the emitting task — long-running loggers should hand off to their own task.

Returns a `SurrealClient{C}` where `C` is the concrete connection backend type.

# Do-block form

The function form mirrors `Base.open`: the client is closed automatically
on exit, even if the block throws.

```julia
SurrealDB.connect("ws://localhost:8000"; ns="test", db="test") do db
    SurrealDB.query(db, "SELECT * FROM stream")
end  # client is closed here
```
"""
function connect(f::Function, url::String; kwargs...)
    client = connect(url; kwargs...)
    try
        return f(client)
    finally
        try; close!(client); catch; end
    end
end

function connect(url::String;
                 ns=nothing, db=nothing, token=nothing, auth=nothing,
                 reconnect::Bool=true,
                 reconnect_max_attempts::Int=10,
                 reconnect_base_delay::Float64=0.5,
                 reconnect_max_delay::Float64=30.0,
                 reconnect_jitter::Float64=0.1,
                 ping_interval::Float64=30.0,
                 tls_verify::Bool=true,
                 rpc_timeout::Float64=30.0,
                 refresh_lead_time::Float64=30.0,
                 wire::Symbol=:cbor,
                 check_version::Bool=true,
                 logger::AbstractSurrealLogger=NullLogger())
    scheme = _parse_scheme(url)
    wire in (:json, :cbor) || throw(ArgumentError("Unsupported wire format: $wire (expected :json or :cbor)"))

    if scheme in (:ws, :wss, :http, :https)
        is_http = scheme in (:http, :https)
        is_ws = scheme in (:ws, :wss)

        # Construct the proper URL
        ws_url = url
        http_base = url
        if is_ws && !endswith(url, "/rpc")
            ws_url = rstrip(url, '/') * "/rpc"
        end

        conn = is_http ?
            RemoteConnection{:http, wire}(url=ws_url,
                                 http_base_url=http_base,
                                 response_channels=Dict{Int, Channel}(),
                                 write_channel=nothing,
                                 notification_channels=Dict{String, Channel}(),
                                 reconnect=reconnect,
                                 reconnect_max_attempts=reconnect_max_attempts,
                                 reconnect_base_delay=reconnect_base_delay,
                                 reconnect_max_delay=reconnect_max_delay,
                                 reconnect_jitter=reconnect_jitter,
                                 ping_interval=ping_interval,
                                 tls_verify=tls_verify,
                                 rpc_timeout=rpc_timeout,
                                 refresh_lead_time=refresh_lead_time,
                                 logger=logger) :
            RemoteConnection{:ws, wire}(url=ws_url,
                               http_base_url=http_base,
                               response_channels=Dict{Int, Channel}(),
                               write_channel=_new_write_channel(Val(wire)),  # pre-construction: wire is local var, not yet bound to a conn
                               notification_channels=Dict{String, Channel}(),
                               reconnect=reconnect,
                               reconnect_max_attempts=reconnect_max_attempts,
                               reconnect_base_delay=reconnect_base_delay,
                               reconnect_max_delay=reconnect_max_delay,
                               reconnect_jitter=reconnect_jitter,
                               ping_interval=ping_interval,
                               tls_verify=tls_verify,
                               rpc_timeout=rpc_timeout,
                               refresh_lead_time=refresh_lead_time,
                               logger=logger)
        _connect_remote!(conn)
        if is_ws
            for _ in 1:50
                conn.status == STATUS_CONNECTED && break
                sleep(0.05)
            end
            if conn.status != STATUS_CONNECTED
                cause = conn.last_error
                msg = cause === nothing ?
                    "Failed to connect to $ws_url" :
                    "Failed to connect to $ws_url: $(sprint(showerror, cause))"
                throw(ConnectionError(msg, cause))
            end
        end
        client = SurrealClient(conn, nothing, nothing, nothing, nothing, Dict{String, Any}())
        conn.client = client

        # Version probe — runs against the live socket before any user code
        # sees the client. Throws UnsupportedVersionError on mismatch; close
        # the connection cleanly so we don't leak a half-open handle.
        if check_version
            try
                _check_server_version(client)
            catch e
                try; close!(client); catch; end
                rethrow()
            end
        end

        if auth !== nothing
            signin!(client, auth)
        end
        if token !== nothing
            authenticate!(client, token)
        end
        if ns !== nothing && db !== nothing
            use!(client, ns, db)
        end

        return client
    elseif scheme in (:mem, :surrealkv)
        conn = embedded_connect(url)
        client = SurrealClient(conn, nothing, nothing, nothing, nothing, Dict{String, Any}())

        if ns !== nothing && db !== nothing
            use!(client, ns, db)
        end

        return client
    else
        throw(ArgumentError("Unsupported URL scheme: $url"))
    end
end

# --- Version compatibility check ---

"""
    MINIMUM_SERVER_VERSION

Lowest SurrealDB server version this SDK has been tested against. Connect-time
version probes throw [`UnsupportedVersionError`](@ref) below this; bypass with
`connect(...; check_version=false)`.
"""
const MINIMUM_SERVER_VERSION = "2.0.0"

"""
    MAXIMUM_SERVER_VERSION

Upper bound (exclusive) for the supported server-version range, or `nothing`
to disable the cap. Pinned to mark untested territory — servers at or above
this version are likely to ship wire-format changes the SDK hasn't seen.
Bump after live-server shakedown against the next major.
"""
const MAXIMUM_SERVER_VERSION = "4.0.0"

# Pull the semver string out of whatever shape `version()` happens to return
# on this server build: "1.2.3", "surrealdb-1.2.3", "1.2.3+build.4", etc.
# Returns nothing if no semver shape is present.
function _parse_server_semver(raw::AbstractString)
    m = match(r"(\d+)\.(\d+)\.(\d+)", raw)
    m === nothing && return nothing
    return VersionNumber(parse(Int, m.captures[1]),
                         parse(Int, m.captures[2]),
                         parse(Int, m.captures[3]))
end

function _check_server_version(client::SurrealClient)
    raw = try
        v = version(client)
        v.version
    catch e
        # version() RPC unsupported on very old builds, or blocked by a
        # misconfigured proxy/firewall. Surface as a warning so operators
        # know the check was skipped; don't block the connect.
        @warn "SurrealDB version probe failed; skipping compat check" exception=e
        return nothing
    end
    parsed = _parse_server_semver(string(raw))
    if isnothing(parsed)
        @warn "SurrealDB server returned unrecognized version shape; skipping compat check" raw=raw
        return nothing
    end
    min_v = VersionNumber(MINIMUM_SERVER_VERSION)
    if parsed < min_v
        throw(UnsupportedVersionError(string(raw), MINIMUM_SERVER_VERSION, MAXIMUM_SERVER_VERSION))
    end
    if !isnothing(MAXIMUM_SERVER_VERSION)
        max_v = VersionNumber(MAXIMUM_SERVER_VERSION)
        parsed < max_v || throw(UnsupportedVersionError(string(raw), MINIMUM_SERVER_VERSION, MAXIMUM_SERVER_VERSION))
    end
    return parsed
end

"""
    close!(client::SurrealClient)

Close the database connection. The client cannot be used after this call.
"""
function close!(client::SurrealClient{C}) where {C<:AbstractConnection}
    _close_backend!(client.connection)
    client.namespace = nothing
    client.database = nothing
    client.token = nothing
    client.tokens = nothing
    return nothing
end

"""
    status(client::SurrealClient)

Return the current connection status as a `ConnectionStatus`:
`STATUS_CONNECTED`, `STATUS_DISCONNECTED`, `STATUS_CONNECTING`, `STATUS_RECONNECTING`
"""
function status(client::SurrealClient{C}) where {C<:AbstractConnection}
    return client.connection.status
end

"""
    tokens(client::SurrealClient) -> Union{Tokens, Nothing}

Return the typed access+refresh pair from the most recent successful
sign-in, or `nothing` if the client is unauthenticated or the auth mode
did not issue a refresh token. See [`Tokens`](@ref).
"""
function tokens(client::SurrealClient{C}) where {C<:AbstractConnection}
    return client.tokens
end

"""
    events(client::SurrealClient{<:AbstractRemoteConnection}) -> Channel{LifecycleEvent}

Return a Channel that emits [`LifecycleEvent`](@ref) values on
remote-connection state transitions. Each event carries:

- `ev.status` — `STATUS_CONNECTING` / `STATUS_CONNECTED` /
  `STATUS_RECONNECTING` / `STATUS_DISCONNECTED`
- `ev.attempt` — 0 on first connect, N (1-based) on the Nth reconnect attempt
- `ev.cause` — the `Exception` that triggered RECONNECTING / DISCONNECTED, or `nothing`
- `ev.timestamp` — `time()` at emission

Drop-in equivalent of the JS SDK's `db.subscribe('connected', ...)`
pattern (consume `ev.status` for the bare ConnectionStatus). Best-effort
emission — if no consumer drains the channel, events are queued (capacity
64) and dropped silently when the buffer is full.

For synchronous side effects (e.g. structured logging), see
[`AbstractSurrealLogger`](@ref) / [`FnLogger`](@ref) — those fire on the
emitting task rather than buffering through the channel.

# Examples
```julia
db = SurrealDB.connect("ws://localhost:8000")
@async for ev in SurrealDB.events(db)
    @info "SurrealDB lifecycle" status=ev.status attempt=ev.attempt cause=ev.cause
end
```
"""
function events(client::SurrealClient{C}) where {C<:AbstractRemoteConnection}
    return client.connection.events
end

# Embedded connections have a simpler lifecycle (no reconnect loop) but still
# emit STATUS_CONNECTED on connect and STATUS_DISCONNECTED on close so transport-
# agnostic code can rely on a uniform event stream regardless of backend.
function events(client::SurrealClient{C}) where {C<:AbstractConnection}
    return client.connection.events
end

"""
    use!(client::SurrealClient, ns::String, db::String)

Select a namespace and database for all subsequent operations.
"""
function use!(client::SurrealClient{C}, ns::String, db::String) where {C<:AbstractConnection}
    _use_backend!(client.connection, ns, db)
    client.namespace = ns
    client.database = db
    return nothing
end

"""
    info(client::SurrealClient)

Retrieve database-level information such as tables and schema.

Returns a `Dict{String, Any}`.
"""
function info(client::SurrealClient{C}) where {C<:AbstractConnection}
    return _rpc_call(client, "info", Any[])
end

"""
    version(client::SurrealClient)

Retrieve the SurrealDB server version.

Returns a `NamedTuple` with fields `:version`, `:build`, `:timestamp`.
"""
function version(client::SurrealClient{C}) where {C<:AbstractConnection}
    result = _rpc_call(client, "version", Any[])
    ver = result isa String ? result : get(result, "version", string(result))
    build = result isa Dict ? get(result, "build", "") : ""
    timestamp = result isa Dict ? get(result, "timestamp", "") : ""
    return (version=ver, build=build, timestamp=timestamp)
end

"""
    ping(client::SurrealClient) -> Bool

Send a lightweight RPC ping. Returns `true` if the server responds. Backs the
keepalive timer; exposed for callers who want a manual liveness check
without `health()`'s trivial-query fallback.
"""
function ping(client::SurrealClient{C}) where {C<:AbstractConnection}
    try
        _rpc_call(client, "ping", Any[])
        return true
    catch
        return false
    end
end

"""
    health(client::SurrealClient)

Check the health of the database connection.

Returns `true` if the database is healthy.
"""
function health(client::SurrealClient{C}) where {C<:AbstractConnection}
    try
        _rpc_call(client, "health", Any[])
        return true
    catch e
        # "method not found" used to surface as RPCError(-32601). Post-D1, the
        # -32601 wire code maps to NotFoundError via _CODE_TO_KIND. Catch both
        # so older servers (legacy RPCError path) and newer servers (kind
        # dispatch) both trigger the trivial-query fallback.
        method_not_found = (e isa NotFoundError) ||
                           (e isa RPCError && e.code == -32601)
        if method_not_found
            try
                _rpc_call(client, "query", Any["SELECT * FROM 1", Dict{String, Any}()])
                return true
            catch
                return false
            end
        end
        return false
    end
end

"""
    export_db(client::SurrealClient, filepath::String)

Export the current namespace and database to a file.
"""
function export_db(client::SurrealClient{C}, filepath::String) where {C<:AbstractConnection}
    _rpc_call(client, "export", Any[filepath])
    return nothing
end

"""
    import_db(client::SurrealClient, filepath::String)

Import data from a file into the current namespace and database.
"""
function import_db(client::SurrealClient{C}, filepath::String) where {C<:AbstractConnection}
    _rpc_call(client, "import", Any[filepath])
    return nothing
end

# --- Backend dispatch (filled by connection + embedded agents) ---

function _rpc_call(client::SurrealClient{<:RemoteConnection}, method::String, params::Vector{Any};
                   session=nothing, txn=nothing)
    return _rpc_call_remote(client, method, params; session=session, txn=txn)
end

# Embedded method is defined in embedded.jl as `SurrealDB._rpc_call(...)`,
# extending this generic stub across the Embedded submodule boundary —
# matches the pattern used by `_close_backend!` / `_use_backend!`.

# Stubs — concrete methods live in connection.jl (RemoteConnection) and
# embedded.jl (EmbeddedConnection, qualified as `SurrealDB._<name>!` so it
# extends these stubs across the module boundary).
function _close_backend! end
function _use_backend! end
function _embedded_rpc_call end
function _connect_embedded! end

function _close_backend!(conn::RemoteConnection)
    _close_remote!(conn)
end

function _use_backend!(conn::RemoteConnection, ns::String, db_name::String)
    _use_remote!(conn, ns, db_name)
end
