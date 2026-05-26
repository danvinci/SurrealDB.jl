# Embedded connection backend for SurrealDB.jl
# Implements AbstractConnection for in-process SurrealDB via ccall into libsurreal

# --- Embedded connection type ---

"""
    EmbeddedConnection(url)

An embedded SurrealDB connection running in-process via libsurreal.

URL schemes:
- `mem://` or `memory://` — in-memory database (no persistence)
- `surrealkv://path/to/data.skv` — file-backed database

`surrealkv+versioned://` (MVCC mode) and `rocksdb://` are not enabled in the
bundled `libsurreal_c` build; passing them raises `EmbeddedFFIError(sr_connect)`.

Requires `libsurreal` to be loaded via [`libsurreal_load!`](@ref).
"""
Base.@kwdef mutable struct EmbeddedConnection <: AbstractConnection
    "Opaque sr_surreal_t* from libsurreal; `C_NULL` when disconnected"
    handle::Ptr{Cvoid}
    "Original URL string the connection was created with — `mem://`, `surrealkv://path`, etc."
    path::String
    "Lifecycle: `STATUS_CONNECTED` / `STATUS_DISCONNECTED` / `STATUS_CONNECTING`"
    status::SurrealDB.ConnectionStatus
    "Guards `handle` and `live_streams` against concurrent access from CRUD tasks"
    lock::ReentrantLock
    "live query_id → stream handle (sr_stream_t*) — passed to sr_stream_next/sr_stream_kill"
    live_streams::Dict{String, Ptr{Cvoid}}
    "live query_id → LiveSubscription handle — used by `kill!(client, qid)` to flip caller-held state"
    live_handles::Dict{String, LiveSubscription} = Dict{String, LiveSubscription}()
    "Lifecycle-event Channel (mirrors `RemoteConnection.events`). Embedded fires `STATUS_CONNECTED` once on successful connect and `STATUS_DISCONNECTED` once on close; no `STATUS_RECONNECTING` because there's no retry loop."
    events::Channel{SurrealDB.LifecycleEvent} = Channel{SurrealDB.LifecycleEvent}(8)
end

function Base.show(io::IO, conn::EmbeddedConnection)
    print(io, "EmbeddedConnection(", conn.path, ", ", conn.status, ")")
end

# Best-effort emit; never blocks the caller. Mirrors `_emit_lifecycle!` for remote.
# Takes a bare ConnectionStatus and wraps it in a LifecycleEvent with attempt=0
# and no cause — embedded has no reconnect loop, so neither field carries info.
function _emit_embedded_event!(conn::EmbeddedConnection, status::SurrealDB.ConnectionStatus)
    ev = SurrealDB.LifecycleEvent(status, 0, nothing, time())
    @async try
        isopen(conn.events) && put!(conn.events, ev)
    catch e
        e isa InvalidStateException || rethrow()
    end
    return nothing
end

# --- Connect ---

function embedded_connect(url::String)::EmbeddedConnection
    LibSurreal.ensure_loaded!()
    conn = EmbeddedConnection(
        handle=C_NULL,
        path=url,
        status=SurrealDB.STATUS_CONNECTING,
        lock=ReentrantLock(),
        live_streams=Dict{String, Ptr{Cvoid}}(),
        live_handles=Dict{String, LiveSubscription}()
    )
    _connect_embedded!(conn, url)
    return conn
end

function SurrealDB._connect_embedded!(conn::EmbeddedConnection, url::String)
    lock(conn.lock)
    try
        endpoint = url
        if startswith(url, "mem://") || url == "memory://"
            endpoint = "mem://"
        end
        conn.handle = LibSurreal.sr_connect(endpoint)
        conn.status = SurrealDB.STATUS_CONNECTED
    finally
        unlock(conn.lock)
    end
    _emit_embedded_event!(conn, SurrealDB.STATUS_CONNECTED)
    return nothing
end

# --- Close ---

function SurrealDB._close_backend!(conn::EmbeddedConnection)
    was_connected = conn.status == SurrealDB.STATUS_CONNECTED
    lock(conn.lock)
    try
        for (_, stream) in conn.live_streams
            LibSurreal.sr_stream_kill(stream)
        end
        empty!(conn.live_streams)
        if conn.handle != C_NULL
            LibSurreal.sr_disconnect(conn.handle)
            conn.handle = C_NULL
        end
        conn.status = SurrealDB.STATUS_DISCONNECTED
    finally
        unlock(conn.lock)
    end
    if was_connected
        _emit_embedded_event!(conn, SurrealDB.STATUS_DISCONNECTED)
        try; close(conn.events); catch; end
    end
    return nothing
end

# --- Scoping ---

function SurrealDB._use_backend!(conn::EmbeddedConnection, ns::String, db_name::String)
    lock(conn.lock)
    try
        LibSurreal.sr_use_ns(conn.handle, ns)
        LibSurreal.sr_use_db(conn.handle, db_name)
    finally
        unlock(conn.lock)
    end
    return nothing
end

# --- RPC dispatch ---

# Compile-time dispatch for embedded backend — extends the generic stub in
# connection.jl. Lives here (not in connection.jl) because `EmbeddedConnection`
# is defined inside this submodule and isn't visible to the parent at parse time.
function SurrealDB._rpc_call(client::SurrealDB.SurrealClient{<:EmbeddedConnection}, method::String,
                             params::Vector{Any}; session=nothing, txn=nothing)
    SurrealDB._check_open(client)
    return SurrealDB._embedded_rpc_call(client.connection, method, params)
end

# Embedded RPC dispatch. Most arms are mechanical: method name → sr_* function
# with one of four argument shapes. Shapes:
#   :handle_only            — sr_fn(handle)
#   :passthrough            — sr_fn(handle, params...)
#   :coerce_first           — sr_fn(handle, string(params[1]))
#   :coerce_first_with_rest — sr_fn(handle, string(params[1]), params[2:end]...)
#
# Adding a new mechanical RPC: one line in the table. Special-case arms with
# genuine per-method logic (query / relate / patch / live / kill / signin /
# signup / let) stay as branches below the table dispatch.
# Methods reachable on an EmbeddedConnection that libsurreal_c doesn't expose.
# Throwing UnsupportedFeatureError names the gap; the generic else-arm at the
# bottom of _embedded_rpc_call would otherwise mask these as the same
# "Unsupported method" error as a true typo. `attach` / `detach` / `sessions`
# are also listed for defense-in-depth even though their public API is already
# constrained to RemoteWSConnection at the call site.
const _EMBEDDED_UNSUPPORTED = ("run", "info", "ping", "refresh",
                               "attach", "detach", "sessions")

# Special-case method names handled by the if/elseif chain below the dispatch
# table. Source of truth for the coverage test in test_wire.jl.
const _EMBEDDED_SPECIAL_CASE = ("query", "relate", "patch", "live", "kill",
                                "signin", "signup", "let")

const _RPC_ARMS = Dict{String, Tuple{Function, Symbol}}(
    "create"          => (LibSurreal.sr_create,          :coerce_first_with_rest),
    "select"          => (LibSurreal.sr_select,          :coerce_first),
    "update"          => (LibSurreal.sr_update,          :coerce_first_with_rest),
    "delete"          => (LibSurreal.sr_delete,          :coerce_first),
    "insert"          => (LibSurreal.sr_insert,          :coerce_first_with_rest),
    "upsert"          => (LibSurreal.sr_upsert,          :coerce_first_with_rest),
    "merge"           => (LibSurreal.sr_merge,           :coerce_first_with_rest),
    "insert_relation" => (LibSurreal.sr_insert_relation, :coerce_first_with_rest),
    "authenticate"    => (LibSurreal.sr_authenticate,    :coerce_first),
    "unset"           => (LibSurreal.sr_unset,           :coerce_first),
    "invalidate"      => (LibSurreal.sr_invalidate,      :handle_only),
    "begin"           => (LibSurreal.sr_begin,           :handle_only),
    "commit"          => (LibSurreal.sr_commit,          :handle_only),
    "cancel"          => (LibSurreal.sr_cancel,          :handle_only),
    "version"         => (LibSurreal.sr_version,         :handle_only),
    "health"          => (LibSurreal.sr_health,          :handle_only),
    "export"          => (LibSurreal.sr_export_db,       :passthrough),
    "import"          => (LibSurreal.sr_import_db,       :passthrough),
)

function _dispatch_rpc_arm(arm::Tuple{Function, Symbol}, conn::EmbeddedConnection, params)
    fn, shape = arm
    shape === :handle_only            && return fn(conn.handle)
    shape === :passthrough            && return fn(conn.handle, params...)
    shape === :coerce_first           && return fn(conn.handle, string(params[1]))
    shape === :coerce_first_with_rest && return fn(conn.handle, string(params[1]), params[2:end]...)
    throw(ConnectionError("Unknown embedded RPC arg shape: $shape"))
end

function SurrealDB._embedded_rpc_call(conn::EmbeddedConnection, method::String, params::Vector{Any})
    # Substrate boundary: the C FFI ccalls want raw strings for resource
    # identifiers; coerce typed RecordID / Table here via Base.string so
    # methods.jl can pass typed values through unmodified for the CBOR wire
    # path (system-design-principles.md § Boundary discipline).
    # Locking is done inside each sr_* call in libsurreal.jl

    method in _EMBEDDED_UNSUPPORTED &&
        throw(SurrealDB.UnsupportedFeatureError(Symbol(method), :embedded))

    arm = get(_RPC_ARMS, method, nothing)
    isnothing(arm) || return _dispatch_rpc_arm(arm, conn, params)

    # Special-case arms — each has per-method logic beyond uniform sr_* dispatch.
    if method == "query"
        sql = params[1]
        vars = length(params) > 1 ? params[2] : Dict{String, Any}()
        return LibSurreal.sr_query(conn.handle, sql, vars)
    elseif method == "relate"
        # (from, edge, to, [data]) — three string-coerced positional args.
        return LibSurreal.sr_relate(conn.handle,
                                    string(params[1]),
                                    string(params[2]),
                                    string(params[3]),
                                    params[4:end]...)
    elseif method == "patch"
        # params = [resource, patches::Vector{Dict}, diff_flag]
        # Each patch is {"op" => "add"|"remove"|"replace", "path" => p, "value" => v}.
        # libsurreal exposes one ccall per op kind; iterate and apply each.
        resource = string(params[1])
        patches = params[2]
        last_result = Any[]
        for p in patches
            op = string(get(p, "op", ""))
            path = string(get(p, "path", ""))
            if op == "add"
                last_result = LibSurreal.sr_patch_add(conn.handle, resource, path, get(p, "value", nothing))
            elseif op == "remove"
                last_result = LibSurreal.sr_patch_remove(conn.handle, resource, path)
            elseif op == "replace"
                last_result = LibSurreal.sr_patch_replace(conn.handle, resource, path, get(p, "value", nothing))
            else
                throw(ConnectionError("Unsupported embedded patch op: $op"))
            end
        end
        return last_result
    elseif method == "live"
        resource = string(params[1])
        diff = length(params) > 1 ? params[2] : false
        stream = LibSurreal.sr_select_live(conn.handle, resource)
        key = string(stream)
        conn.live_streams[key] = stream
        return key
    elseif method == "kill"
        query_id = string(params[1])
        if haskey(conn.live_streams, query_id)
            LibSurreal.sr_stream_kill(conn.live_streams[query_id])
            delete!(conn.live_streams, query_id)
        end
        return LibSurreal.sr_kill(conn.handle, query_id)
    elseif method == "signin"
        p = params[1]
        if p isa AbstractDict
            scope = !isnothing(get(p, "AC", nothing)) ? :RECORD :
                    !isnothing(get(p, "DB", nothing)) ? :DATABASE :
                    !isnothing(get(p, "NS", nothing)) ? :NAMESPACE : :ROOT
            return LibSurreal.sr_signin(conn.handle, scope,
                string(get(p, "user", "")), string(get(p, "pass", "")),
                string(get(p, "NS", "")), string(get(p, "DB", "")),
                string(get(p, "AC", "")))
        else
            return LibSurreal.sr_signin(conn.handle, :ROOT, string(p), "", "", "", "")
        end
    elseif method == "signup"
        p = params[1]
        if p isa AbstractDict
            return LibSurreal.sr_signup(conn.handle, :RECORD,
                string(get(p, "user", "")), string(get(p, "pass", "")),
                string(get(p, "NS", "")), string(get(p, "DB", "")),
                string(get(p, "AC", "")))
        else
            return LibSurreal.sr_signup(conn.handle, :RECORD, string(p), "", "", "", "")
        end
    elseif method == "let"
        # sr_set's second arg is positional, not variadic — pass explicit nothing.
        return LibSurreal.sr_set(conn.handle, string(params[1]), length(params) > 1 ? params[2] : nothing)
    else
        throw(ConnectionError("Unsupported embedded method: $method"))
    end
end

# --- Live query polling (called from live.jl) ---

function SurrealDB._register_live!(conn::EmbeddedConnection,
                                   sub::SurrealDB.LiveSubscription,
                                   table, diff::Bool)
    lock(conn.lock) do
        conn.live_handles[sub.query_id] = sub
    end
    @async SurrealDB._poll_embedded_live(conn, sub.query_id, sub.channel)
    return nothing
end

function SurrealDB._deregister_live!(conn::EmbeddedConnection, query_id::String)
    lock(conn.lock) do
        pop!(conn.live_handles, query_id, nothing)
    end
end

function SurrealDB._poll_embedded_live(conn::EmbeddedConnection, query_id::String, ch::Channel)
    stream = get(conn.live_streams, query_id, nothing)
    if isnothing(stream)
        return
    end
    try
        while isopen(ch)
            raw = LibSurreal.sr_stream_next(stream)
            isnothing(raw) && break
            get(raw, "action", "") == "KILLED" && continue
            ln = SurrealDB.LiveNotification(
                string(get(raw, "action", "")),
                string(get(raw, "query_id", query_id)),
                nothing,
                get(raw, "result", nothing),
                nothing,
            )
            try
                put!(ch, ln)
            catch e
                e isa InvalidStateException && break
                rethrow()
            end
        end
    catch e
        # Surface unexpected errors instead of silently dying
        @warn "_poll_embedded_live: terminated on error" query_id exception=(e, catch_backtrace())
    finally
        # Drop the subscription's active flag so consumers know to stop iterating.
        # conn.lock serializes against concurrent kill! / live() on live_handles.
        sub = lock(conn.lock) do
            get(conn.live_handles, query_id, nothing)
        end
        if !isnothing(sub)
            sub.active = false
        end
    end
end
