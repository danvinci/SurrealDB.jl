# WebSocket transport layer — reader, writer, reconnection, ping keepalive, notifications

function _ws_reconnect_loop(conn::RemoteWSConnection)
    # `attempt`: consecutive failures for backoff; resets on success.
    # `ever_connected`: true once any session established — gates STATUS_RECONNECTING emit and retry logic.
    attempt = 0
    ever_connected = false

    while true
        if attempt > conn.reconnect_max_attempts
            break
        end
        if ever_connected && !conn.reconnect && attempt == 0
            break
        end

        # Backoff before any attempt that isn't the very first.
        if ever_connected || attempt > 0
            # `attempt+1` here: emit the upcoming attempt number so observers
            # see "reconnecting, try 3" before the connect call, not after.
            # `conn.last_error` carries the cause of the previous failure
            # (drop or failed-attempt exception).
            _emit_lifecycle!(conn, STATUS_RECONNECTING;
                             attempt=attempt + 1, cause=conn.last_error)
            if attempt > 0
                delay = min(conn.reconnect_base_delay * (2.0 ^ (attempt - 1)),
                            conn.reconnect_max_delay)
                jitter = rand() * conn.reconnect_jitter * delay
                sleep(delay + jitter)
            end
        end

        attempt += 1

        try
            # `Sec-WebSocket-Protocol`: v3 requires an explicit subprotocol
            # (`json` or `cbor`); v2 inferred it. Without this header, v3
            # accepts the upgrade then drops the first RPC. Wire is fixed by
            # the connection's `W` type parameter — dispatched, no branching.
            HTTP.WebSockets.open(conn.url;
                                 headers = ["Sec-WebSocket-Protocol" => _wire_subprotocol(conn)],
                                 require_ssl_verification = conn.tls_verify) do ws
                conn.ws = ws
                # Capture the attempt number this connect succeeded on so the
                # CONNECTED event below carries "reconnected after N tries".
                # First-ever connect: report 0 (not a retry). Reconnect: report
                # the in-progress attempt count (1-based, includes this success).
                connected_attempt = ever_connected ? attempt : 0
                attempt = 0           # consecutive-failure counter resets
                ever_connected = true

                # Writer + reader must be up before state replay — replay issues RPCs.
                # Channel element type matches the wire payload (String for
                # JSON, Vector{UInt8} for CBOR) so the writer's send picks the
                # right WS frame type without runtime branching.
                if isnothing(conn.write_channel) || !isopen(conn.write_channel)
                    conn.write_channel = _new_write_channel(conn)
                else
                    try; close(conn.write_channel); catch; end
                    conn.write_channel = _new_write_channel(conn)
                end
                writer = @async _ws_writer_task(conn)
                reader = @async _ws_reader_task(conn)

                # Replay before STATUS_CONNECTED so observers see a fully-restored session.
                _reconnect_apply_state!(conn)

                # Clear the prior-failure cause so the CONNECTED event isn't
                # mis-attributed to whatever drop preceded the reconnect chain.
                conn.last_error = nothing
                _emit_lifecycle!(conn, STATUS_CONNECTED;
                                 attempt=connected_attempt, cause=nothing)
                _start_pinger!(conn)

                try; wait(reader); catch; end

                # Signal in-flight RPCs so take! returns a typed error instead of hanging.
                _signal_inflight_disconnect!(conn)

                _stop_pinger!(conn)
                try; close(conn.write_channel); catch; end
                try; wait(writer); catch; end
            end
        catch e
            conn.last_error = e
            if !conn.reconnect
                @error "WebSocket connection failed" exception=e
            end
        end
    end

    _stop_pinger!(conn)
    # Terminal disconnect: report the attempt counter at exit (max_attempts+1
    # when retries were exhausted, 0 when reconnect=false short-circuited) and
    # the last observed error so operators can attribute the give-up to a root
    # cause without scraping logs.
    _emit_lifecycle!(conn, STATUS_DISCONNECTED;
                     attempt=attempt, cause=conn.last_error)
    conn.ws = nothing
    _teardown_channels!(conn)
    return nothing
end

# --- Live subscription dispatch (RemoteWSConnection) ---
#
# Concrete methods for `_register_live!` / `_deregister_live!` (stubs in
# connection.jl). All three live-query Dicts are mutated under live_lock to
# serialize against the user-thread kill! / live() and the reconnect loop.

function _register_live!(conn::RemoteWSConnection, sub::LiveSubscription, table, diff::Bool)
    lock(conn.live_lock) do
        chs = get!(conn.notification_channels, sub.query_id, Channel[])
        push!(chs, sub.channel)
        conn.live_subscriptions[sub.query_id] = (table, diff)
        # First registrant owns the kill!-by-handle semantics; later subscribers
        # piggyback on the same server-side live and share the kill! teardown.
        haskey(conn.live_handles, sub.query_id) || (conn.live_handles[sub.query_id] = sub)
    end
    return nothing
end

function _deregister_live!(conn::RemoteWSConnection, query_id::String)
    lock(conn.live_lock) do
        delete!(conn.notification_channels, query_id)
        delete!(conn.live_subscriptions, query_id)
        pop!(conn.live_handles, query_id, nothing)
    end
end

function _reconnect_apply_state!(conn::RemoteWSConnection)
    client = conn.client
    if isnothing(client)
        return
    end

    # Re-select namespace/database if previously set
    if !isnothing(client.namespace) && !isnothing(client.database)
        try
            _use_remote!(conn, client.namespace, client.database)
        catch
        end
    end

    # Re-authenticate if token exists
    if !isnothing(client.token)
        try
            _authenticate_remote!(conn, client.token)
        catch
        end
    end

    # Re-evaluate proactive refresh against the current token's exp. The
    # access token may have expired during the disconnect — if so, fire
    # refresh! immediately (scheduling a 0-delay timer); the next RPC will
    # otherwise hit a NotAllowed from the server. If the refresh itself
    # fails the timer callback clears tokens and emits a warning.
    if !isnothing(client.tokens) && !isnothing(client.tokens.refresh)
        _schedule_refresh_timer!(conn, client)
    end

    # Re-set session variables (`let!`) — server-side state is wiped on
    # reconnect; the client tracks them in `client.variables` for replay.
    # Best-effort: a single failed key shouldn't block the rest.
    for (key, value) in client.variables
        try
            _rpc_call(client, "let", Any[key, value])
        catch
        end
    end

    # Re-subscribe live queries. New UUIDs replace old ones; update live_handles
    # so kill!(sub) targets the server-side subscription after reconnect.
    # All three live-query Dicts are mutated under live_lock to serialize against
    # concurrent user-thread kill! / live().
    old_subs, old_channels, old_handles = lock(conn.live_lock) do
        subs = copy(conn.live_subscriptions)
        chs = copy(conn.notification_channels)
        hs = copy(conn.live_handles)
        empty!(conn.live_subscriptions)
        empty!(conn.notification_channels)
        empty!(conn.live_handles)
        (subs, chs, hs)
    end

    for (old_qid, (table, diff)) in old_subs
        chs = get(old_channels, old_qid, Channel[])
        # All subscribers share one server-side live; skip the re-subscribe if
        # everyone has already torn down their consumer end.
        any(isopen, chs) || continue
        try
            result = _rpc_call(client, "live", Any[table, diff])
            new_qid = result isa String ? result : string(result)
            sub = get(old_handles, old_qid, nothing)
            lock(conn.live_lock) do
                conn.live_subscriptions[new_qid] = (table, diff)
                conn.notification_channels[new_qid] = chs
                # Re-key handle so kill!(sub) targets the new server-side query_id.
                if !isnothing(sub)
                    sub.query_id = new_qid
                    conn.live_handles[new_qid] = sub
                end
            end
        catch
            # Re-subscription failed: close every consumer channel and mark
            # the (primary) sub dead so iteration loops terminate.
            for ch in chs
                try; close(ch); catch; end
            end
            sub = get(old_handles, old_qid, nothing)
            if !isnothing(sub)
                sub.active = false
            end
        end
    end
end

function _ws_writer_task(conn::RemoteWSConnection)
    # Gate on socket, not status — writes during state replay must go out.
    while !isnothing(conn.ws) && !HTTP.WebSockets.isclosed(conn.ws)
        msg = try
            take!(conn.write_channel)
        catch e
            # Channel closed externally — exit cleanly.
            break
        end
        # Empty payload is the shutdown sentinel — `_close_remote!` pushes
        # `""` or `UInt8[]` (matching the channel's element type) to wake the
        # writer; either way an empty payload means exit.
        isempty(msg) && break
        if !isnothing(conn.ws) && !HTTP.WebSockets.isclosed(conn.ws)
            try
                HTTP.WebSockets.send(conn.ws, msg)
            catch e
                e isa InvalidStateException && break
                # Force-close so the reader EOFs and _signal_inflight_disconnect! fires.
                @debug "SurrealDB ws writer error; closing socket" exception=e
                try; HTTP.WebSockets.close(conn.ws); catch; end
                break
            end
        end
    end
end

function _ws_reader_task(conn::RemoteWSConnection)
    while !isnothing(conn.ws) && !HTTP.WebSockets.isclosed(conn.ws)
        raw = try
            HTTP.WebSockets.receive(conn.ws)
        catch e
            # WebSocketError covers server-Close + protocol violations;
            # EOFError/IOError cover raw socket loss.
            if e isa HTTP.WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError
                break
            end
            rethrow()
        end
        isempty(raw) && continue
        # `receive` returns `String` for TEXT frames (JSON) and
        # `Vector{UInt8}` for BINARY frames (CBOR). `_wire_decode` dispatches
        # on the connection's `W` param and accepts either form.

        msg = try
            _wire_decode(conn, raw)
        catch
            continue
        end

        if haskey(msg, "id") && !isnothing(msg["id"])
            rid = msg["id"]
            @debug "SurrealDB ws RPC ←" rid=rid has_error=haskey(msg, "error")
            # Snapshot the channel under the lock, then `put!` outside. Holding
            # `conn.lock` across `put!` on a 1-cap channel would deadlock the
            # writer / RPC-registration paths if the channel were already full
            # (caller raced to tear it down) — same shape as the snapshot-then-
            # signal pattern in `_drain_and_signal_response_channels!` below.
            ch = lock(conn.lock) do
                get(conn.response_channels, rid, nothing)
            end
            if !isnothing(ch) && isopen(ch)
                try
                    put!(ch, msg)
                catch e
                    # Channel closed between snapshot and put — caller raced to
                    # tear down. Drop; the caller will surface the timeout / drop
                    # via its own error path.
                    e isa InvalidStateException || rethrow()
                end
            end
        elseif get(msg, "method", "") == "notify"
            # Legacy notification envelope: {method:"notify", params:{id, ...}}
            @debug "SurrealDB ws notification ← (legacy)"
            _dispatch_notification(conn, msg)
        elseif _is_live_notification(msg)
            @debug "SurrealDB ws notification ←"
            _dispatch_live_notification(conn, msg["result"])
        elseif haskey(msg, "error")
            # Orphan error: no usable id (JSON-RPC parse errors fire before id is parsed).
            # Signal all in-flight RPCs so they fail fast rather than hang until rpc_timeout.
            err = msg["error"]
            @warn "SurrealDB ws orphan error frame" raw=first(raw, 300)
            _signal_inflight_with_error!(conn, err)
        else
            @warn "SurrealDB ws unrecognized frame" raw=first(raw, 300)
        end
    end
end

# Drain response_channels under lock and deliver `payload` to every open
# non-ready channel — used by the three signal-inflight paths. Skips channels
# that already received the real response (their caller's take! will succeed).
# Snapshot-then-signal: holding conn.lock across put! on a 1-cap channel would
# deadlock the reader, which needs the lock to dispatch responses.
function _drain_and_signal_response_channels!(conn::RemoteWSConnection, payload::Dict)
    channels = lock(conn.lock) do
        chs = collect(values(conn.response_channels))
        empty!(conn.response_channels)
        chs
    end
    for ch in channels
        if isopen(ch) && !isready(ch)
            try; put!(ch, payload); catch; end
        end
    end
    return nothing
end

# Unblock in-flight RPCs on socket drop with a synthetic transport error.
# Unlike _teardown_channels!, does NOT close notification channels or empty dicts.
function _signal_inflight_disconnect!(conn::RemoteWSConnection)
    _drain_and_signal_response_channels!(conn,
        Dict("error" => Dict("code" => -1, "message" => "Connection lost mid-request")))
end

# Forward the server-supplied error to all in-flight RPCs (connection still alive).
# Used for no-id frames where the server can't attribute the error to a specific request.
function _signal_inflight_with_error!(conn::RemoteWSConnection, err)
    _drain_and_signal_response_channels!(conn, Dict("error" => err))
end

function _teardown_channels!(conn::RemoteWSConnection)
    _drain_and_signal_response_channels!(conn,
        Dict("error" => Dict("code" => -1, "message" => "Connection closed")))
    notif_chs = lock(conn.live_lock) do
        # Flatten Vector{Vector{Channel}} into a single list so the close-loop
        # below doesn't care about the multi-subscriber registry shape.
        snap = Channel[]
        for v in values(conn.notification_channels)
            append!(snap, v)
        end
        empty!(conn.notification_channels)
        empty!(conn.live_subscriptions)
        empty!(conn.live_handles)
        snap
    end
    for ch in notif_chs
        if isopen(ch)
            try; close(ch); catch; end
        end
    end
end

function _start_pinger!(conn::RemoteWSConnection)
    _stop_pinger!(conn)
    client = conn.client
    interval = conn.ping_interval
    interval > 0 || return nothing  # 0 disables ping
    conn.pinger_task = @async begin
        try
            while conn.status == STATUS_CONNECTED
                # Use a Timer so `_stop_pinger!` can interrupt the wait
                # immediately by closing the timer (otherwise we'd block up to
                # `ping_interval` seconds before noticing the shutdown).
                conn.pinger_timer = Timer(interval)
                try
                    wait(conn.pinger_timer)
                catch e
                    # Timer closed externally (shutdown signal) → exit cleanly
                    e isa EOFError && break
                    rethrow()
                end
                conn.status == STATUS_CONNECTED || break
                try
                    if !isnothing(client)
                        _rpc_call(client, "ping", Any[])
                    end
                catch
                    # Ping failed — close socket to trigger reconnection
                    if !isnothing(conn.ws)
                        try; HTTP.WebSockets.close(conn.ws); catch; end
                    end
                    break
                end
            end
        finally
            conn.pinger_timer = nothing
        end
    end
    return nothing
end

function _stop_pinger!(conn::RemoteWSConnection)
    timer = conn.pinger_timer
    if !isnothing(timer)
        try; close(timer); catch; end
    end
    task = conn.pinger_task
    if !isnothing(task) && !istaskdone(task)
        try
            t_end = time() + 1.0  # 1s cap; normally exits in microseconds
            while !istaskdone(task) && time() < t_end
                yield()
            end
        catch
        end
    end
    conn.pinger_task = nothing
    conn.pinger_timer = nothing
    return nothing
end

# Live-notification discriminator: result.action + result.id both present.
# Two-field check avoids false-matching plain RPC responses with a Dict result.
function _is_live_notification(msg)
    haskey(msg, "result") || return false
    r = msg["result"]
    r isa AbstractDict || return false
    return haskey(r, "action") && haskey(r, "id")
end

# Deliver a payload to a live-subscription channel. Snapshot under live_lock then
# put! after release — channels are bounded (32); holding the lock across a
# slow subscriber's put! would deadlock any concurrent kill! / reconnect on the
# same lock. (Cf. Go SDK aef39d3a.)
function _deliver_to_subscriber!(conn::RemoteWSConnection, qid::String, payload)
    # Snapshot the subscriber vector under the lock, then fan out outside —
    # a slow consumer mustn't block the lock that registration / kill! / the
    # reconnect loop contend on.
    chs = lock(conn.live_lock) do
        v = get(conn.notification_channels, qid, nothing)
        isnothing(v) ? Channel[] : copy(v)
    end
    for ch in chs
        isopen(ch) || continue
        try
            put!(ch, payload)
        catch e
            e isa InvalidStateException || rethrow()
        end
    end
    return nothing
end

function _dispatch_live_notification(conn::RemoteWSConnection, result::AbstractDict)
    query_id = get(result, "id", nothing)
    isnothing(query_id) && return nothing
    qid = string(query_id)
    action = get(result, "action", "")

    if action == "KILLED"
        # Distinguish client- vs server-initiated kill: client-side `kill!`
        # tears down `notification_channels[qid]` BEFORE issuing the kill RPC,
        # so by the time KILLED arrives the entry is gone — drop silently.
        # If the channel is still present, the server killed unprompted (DDL
        # change, resource limit, admin action) — surface KILLED to the
        # subscriber so they can react, then tear down.
        chs, sub = lock(conn.live_lock) do
            v = get(conn.notification_channels, qid, nothing)
            s = pop!(conn.live_handles, qid, nothing)
            isnothing(v) || delete!(conn.notification_channels, qid)
            delete!(conn.live_subscriptions, qid)
            (isnothing(v) ? Channel[] : copy(v), s)
        end
        isempty(chs) && return nothing  # client-initiated; already torn down
        # Server-initiated: fan out KILLED to every subscriber, then close each
        # channel so `for n in sub.channel` loops terminate.
        notif = LiveNotification(result)
        for ch in chs
            isopen(ch) || continue
            try; put!(ch, notif); catch e
                e isa InvalidStateException || rethrow()
            end
            try; close(ch); catch; end
        end
        !isnothing(sub) && (sub.active = false)
        return nothing
    end

    _deliver_to_subscriber!(conn, qid, LiveNotification(result))
end

# Legacy {method:"notify"} envelope — no production server emits this, kept for compatibility.
function _dispatch_notification(conn::RemoteWSConnection, notif)
    params = get(notif, "params", Dict{String, Any}())
    query_id = params isa Dict ? get(params, "id", nothing) : nothing
    if isnothing(query_id)
        @warn "SurrealDB ws legacy notification dropped (no id)" notif
        return
    end
    _deliver_to_subscriber!(conn, string(query_id), params)
end

function _rpc_call_ws(client::SurrealClient{<:RemoteWSConnection}, method::String, params::Vector{Any};
                      session=nothing, txn=nothing)
    conn = client.connection

    max_retries = 3
    attempt = 0

    while true
        attempt += 1

        # Release lock before put!(write_channel) — holding it across a blocking
        # write deadlocks the reader, which needs the lock to dispatch responses.
        rid = 0
        ch = Channel{Any}(1)
        registered = false
        lock(conn.lock) do
            conn.request_id += 1
            rid = conn.request_id
            if !isnothing(conn.write_channel) && isopen(conn.write_channel)
                conn.response_channels[rid] = ch
                registered = true
            end
        end

        if !registered
            if attempt < max_retries && conn.status == STATUS_RECONNECTING
                sleep(0.5)
                continue
            end
            throw(ConnectionError("No active WebSocket connection (status: $(conn.status))"))
        end

        msg = Dict{String, Any}("id" => rid, "method" => method, "params" => params)
        if !isnothing(session)
            msg["session"] = string(session)
        end
        if !isnothing(txn)
            msg["txn"] = string(txn)
        end
        payload = _wire_encode(conn, msg)
        @debug "SurrealDB ws RPC →" rid=rid method=method params=params wire=_wire(conn)
        try
            put!(conn.write_channel, payload)
        catch e
            lock(conn.lock) do
                delete!(conn.response_channels, rid)
            end
            if attempt < max_retries
                sleep(0.5)
                continue
            end
            throw(ConnectionError("Failed to send RPC: $e", e))
        end

        # timed_out_ref distinguishes a watchdog-induced close from any other
        # InvalidStateException source: on watchdog, the catch must NOT retry
        # (channel is already closed, retry would hit it again immediately).
        response = nothing
        retry_after = false
        if isinf(conn.rpc_timeout)
            try
                response = take!(ch)
            catch e
                if e isa InvalidStateException && attempt < max_retries
                    retry_after = true
                    sleep(0.5)
                else
                    rethrow()
                end
            end
        else
            timed_out_ref = Ref(false)
            watchdog = Timer(conn.rpc_timeout) do _
                # Skip close if response already landed (buffered in ch).
                if isopen(ch) && !isready(ch)
                    timed_out_ref[] = true
                    try; close(ch); catch; end
                end
            end
            try
                response = take!(ch)
            catch e
                e isa InvalidStateException || rethrow()
                if !timed_out_ref[]
                    if attempt < max_retries
                        retry_after = true
                        sleep(0.5)
                    else
                        rethrow()
                    end
                end
            finally
                close(watchdog)
            end
        end
        if isnothing(response)
            if retry_after
                continue
            end
            lock(conn.lock) do
                delete!(conn.response_channels, rid)
            end
            throw(ConnectionError("RPC timeout after $(conn.rpc_timeout)s waiting for `$method` response"))
        end

        if haskey(response, "error")
            err = response["error"]
            if err isa AbstractDict
                code_raw = get(err, "code", -1)
                code = code_raw isa Integer ? Int(code_raw) : -1
                if code == -1 && attempt < max_retries  # transport-level error, retry
                    sleep(0.5)
                    continue
                end
                throw(_parse_rpc_error(err))
            else
                throw(RPCError(-1, string(err)))
            end
        end

        lock(conn.lock) do
            delete!(conn.response_channels, rid)
        end
        return get(response, "result", nothing)
    end
end
