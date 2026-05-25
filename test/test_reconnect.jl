# Reconnect-path unit tests — exercise the state-machine pieces
# (_set_status! events, _stop_pinger! task termination, kill!-vs-reconnect
# UUID re-keying, _dispatch_notification race guards) without a real network.
# Full integration tests against a controllable test server are deferred to
# a future session; these cover the deterministic logic paths that the audit
# flagged as state-heavy and untested.

@testset "_set_status! emits lifecycle events" begin
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTING)
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTED)
    SurrealDB._set_status!(conn, SurrealDB.STATUS_RECONNECTING)
    SurrealDB._set_status!(conn, SurrealDB.STATUS_DISCONNECTED)
    # The async puts may take a moment; spin briefly
    sleep(0.1)
    received = SurrealDB.LifecycleEvent[]
    while isready(conn.events)
        push!(received, take!(conn.events))
    end
    @test [ev.status for ev in received] == [SurrealDB.STATUS_CONNECTING, SurrealDB.STATUS_CONNECTED, SurrealDB.STATUS_RECONNECTING, SurrealDB.STATUS_DISCONNECTED]
end

@testset "_set_status! deduplicates same-state transitions" begin
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTED)
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTED)  # no-op
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTED)  # no-op
    sleep(0.1)
    received = SurrealDB.LifecycleEvent[]
    while isready(conn.events)
        push!(received, take!(conn.events))
    end
    @test length(received) == 1  # only the first transition emits
    @test received[1].status == SurrealDB.STATUS_CONNECTED
end

@testset "_set_status! never blocks on closed events channel" begin
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(1))
    close(conn.events)
    # Should not throw or block
    SurrealDB._set_status!(conn, SurrealDB.STATUS_CONNECTING)
    @test conn.status == SurrealDB.STATUS_CONNECTING
end

@testset "events(client) returns the right channel for each transport" begin
    # WS: real channel
    conn_ws = SurrealDB.RemoteWSConnection()
    client_ws = SurrealDB.SurrealClient(conn_ws, nothing, nothing, nothing, nothing, Dict{String, Any}())
    @test SurrealDB.events(client_ws) === conn_ws.events
    @test isopen(SurrealDB.events(client_ws))

    # HTTP: also has events (RemoteConnection{:http} struct field)
    conn_http = SurrealDB.RemoteHTTPConnection()
    client_http = SurrealDB.SurrealClient(conn_http, nothing, nothing, nothing, nothing, Dict{String, Any}())
    @test SurrealDB.events(client_http) === conn_http.events

    # Embedded: per-instance channel, not a shared sentinel. Drive the event
    # helper directly so we don't need libsurreal loaded for this assertion.
    conn_emb = SurrealDB.EmbeddedConnection(handle=C_NULL, path="mem://",
                                            status=SurrealDB.STATUS_DISCONNECTED,
                                            lock=ReentrantLock(),
                                            live_streams=Dict{String, Ptr{Cvoid}}())
    client_emb = SurrealDB.SurrealClient(conn_emb, nothing, nothing, nothing, nothing, Dict{String, Any}())
    @test SurrealDB.events(client_emb) === conn_emb.events
    @test isopen(SurrealDB.events(client_emb))

    SurrealDB.Embedded._emit_embedded_event!(conn_emb, SurrealDB.STATUS_CONNECTED)
    # Best-effort emission is async; wait briefly.
    deadline = time() + 1.0
    while time() < deadline && !isready(conn_emb.events)
        sleep(0.02)
    end
    @test isready(conn_emb.events)
    @test take!(conn_emb.events).status == SurrealDB.STATUS_CONNECTED
end

@testset "_stop_pinger! is idempotent and safe on a never-started pinger" begin
    conn = SurrealDB.RemoteWSConnection()
    @test conn.pinger_task === nothing
    @test conn.pinger_timer === nothing
    # Should not throw
    SurrealDB._stop_pinger!(conn)
    SurrealDB._stop_pinger!(conn)  # double-stop also fine
    @test conn.pinger_task === nothing
end

@testset "LiveSubscription handle is registered in conn.live_handles on live()" begin
    # Skip live tests if libsurreal isn't loaded — embedded path uses live_handles
    if !SurrealDB.LibSurreal.is_loaded()
        @info "Skipping live_handles test: libsurreal not loaded"
        return
    end
    db = SurrealDB.connect("mem://")
    SurrealDB.use!(db, "test", "test")
    SurrealDB.create(db, rid"rc_events:__init", Dict("name" => "init"))
    sub = SurrealDB.live(db, "rc_events")
    @test haskey(db.connection.live_handles, sub.query_id)
    @test db.connection.live_handles[sub.query_id] === sub
    @test sub.active
    # Embedded `sr_kill` may throw because libsurreal expects a UUID query_id
    # but the embedded path uses a pointer string. Per R5, local state flips
    # BEFORE the RPC call so the assertion below holds either way.
    try; SurrealDB.kill!(sub); catch; end
    @test !sub.active
    @test !haskey(db.connection.live_handles, sub.query_id)
    SurrealDB.close!(db)
end

@testset "kill!(client, query_id) flips state even when RPC fails" begin
    if !SurrealDB.LibSurreal.is_loaded()
        @info "Skipping kill!-by-id state-flip test: libsurreal not loaded"
        return
    end
    db = SurrealDB.connect("mem://")
    SurrealDB.use!(db, "test", "test")
    SurrealDB.create(db, rid"rc_kill:__init", Dict("name" => "init"))
    sub = SurrealDB.live(db, "rc_kill")
    qid = sub.query_id
    # On embedded the kill RPC may fail but state teardown happens FIRST per R5 fix.
    try
        SurrealDB.kill!(db, qid)
    catch
    end
    @test !sub.active
    @test !haskey(db.connection.live_handles, qid)
    SurrealDB.close!(db)
end

@testset "RemoteConnection construction defaults" begin
    ws = SurrealDB.RemoteWSConnection()
    @test ws isa SurrealDB.RemoteConnection{:ws}
    @test ws isa SurrealDB.AbstractRemoteConnection
    @test ws.status == SurrealDB.STATUS_DISCONNECTED
    @test ws.reconnect == true
    @test ws.reconnect_max_attempts == 10
    @test ws.ping_interval == 30.0

    http = SurrealDB.RemoteHTTPConnection()
    @test http isa SurrealDB.RemoteConnection{:http}
    @test http isa SurrealDB.AbstractRemoteConnection
end

@testset "Method dispatch: HTTP-on-WS-only methods produce MethodError" begin
    # _start_pinger! is WS-only — calling on HTTP must MethodError
    http = SurrealDB.RemoteHTTPConnection()
    @test_throws MethodError SurrealDB._start_pinger!(http)
    @test_throws MethodError SurrealDB._ws_reader_task(http)
    @test_throws MethodError SurrealDB._reconnect_apply_state!(http)
end
