# Structured connection-lifecycle observability tests.
#
# Covers:
# - LifecycleEvent construction + Base.show
# - _emit_lifecycle! threading attempt/cause/timestamp
# - Same-status-different-attempt re-emit (no dedup on retry counter bump)
# - Mock-WS reconnect cycle: STATUS_RECONNECTING (attempt>=1, cause!=nothing)
#   followed by STATUS_CONNECTED (attempt>=1, cause=nothing).
# - FnLogger forwarding
# - Logger-thrown exceptions don't crash the emit path

using SurrealDB
using Test
using Sockets

include("mock_ws_server.jl")

function _wait_until(pred; timeout_s::Float64=2.0, step_s::Float64=0.025)
    deadline = time() + timeout_s
    while time() < deadline
        pred() && return true
        sleep(step_s)
    end
    return pred()
end

@testset "LifecycleEvent construction" begin
    ev = SurrealDB.LifecycleEvent(SurrealDB.STATUS_CONNECTING, 0, nothing, 123.456)
    @test ev.status == SurrealDB.STATUS_CONNECTING
    @test ev.attempt == 0
    @test ev.cause === nothing
    @test ev.timestamp == 123.456

    # kwarg outer constructor with sane defaults
    before = time()
    ev2 = SurrealDB.LifecycleEvent(SurrealDB.STATUS_RECONNECTING)
    after = time()
    @test ev2.attempt == 0
    @test ev2.cause === nothing
    @test before <= ev2.timestamp <= after

    cause = ErrorException("boom")
    ev3 = SurrealDB.LifecycleEvent(SurrealDB.STATUS_DISCONNECTED; attempt=4, cause=cause)
    @test ev3.attempt == 4
    @test ev3.cause === cause
end

@testset "LifecycleEvent show is one-line operator-friendly" begin
    ev = SurrealDB.LifecycleEvent(SurrealDB.STATUS_RECONNECTING, 3,
                                  Base.IOError("unexpected EOF", -1), 100.0)
    s = sprint(show, ev)
    @test occursin("LifecycleEvent", s)
    @test occursin("STATUS_RECONNECTING", s)
    @test occursin("attempt=3", s)
    @test occursin("IOError", s)
    # No newlines — operators grep one line per event.
    @test !occursin('\n', s)

    ev_nocause = SurrealDB.LifecycleEvent(SurrealDB.STATUS_CONNECTED, 0, nothing, 0.0)
    @test occursin("cause=nothing", sprint(show, ev_nocause))
end

@testset "_emit_lifecycle! threads attempt, cause, and timestamp" begin
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    cause = ErrorException("drop")
    t_before = time()
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_RECONNECTING;
                                attempt=2, cause=cause)
    t_after = time()
    sleep(0.05)  # async put!
    @test isready(conn.events)
    ev = take!(conn.events)
    @test ev.status == SurrealDB.STATUS_RECONNECTING
    @test ev.attempt == 2
    @test ev.cause === cause
    @test t_before <= ev.timestamp <= t_after
end

@testset "_emit_lifecycle! same-status different-attempt re-emits" begin
    # The dedup guard only skips when status AND attempt are both unchanged.
    # Two reconnect attempts at the same RECONNECTING status (attempt 2 then 3)
    # must both reach the observer — operators need to count retry progress.
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_RECONNECTING; attempt=2)
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_RECONNECTING; attempt=3)
    sleep(0.1)
    received = SurrealDB.LifecycleEvent[]
    while isready(conn.events)
        push!(received, take!(conn.events))
    end
    @test length(received) == 2
    @test received[1].attempt == 2
    @test received[2].attempt == 3
end

@testset "_emit_lifecycle! dedups same-status, attempt=0" begin
    # Same status with default attempt=0 (the legacy _set_status! path) still
    # dedups — otherwise a polling caller would flood the channel.
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTED)
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTED)
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTED)
    sleep(0.1)
    received = SurrealDB.LifecycleEvent[]
    while isready(conn.events)
        push!(received, take!(conn.events))
    end
    @test length(received) == 1
end

@testset "reconnect cycle emits RECONNECTING(attempt>=1, cause!=nothing) then CONNECTED(attempt>=1, cause=nothing)" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        client.connection.reconnect_base_delay = 0.05
        client.connection.reconnect_max_delay = 0.5
        client.connection.reconnect_jitter = 0.0

        ch = SurrealDB.events(client)
        seen = SurrealDB.LifecycleEvent[]
        collector = @async try
            while isopen(ch)
                push!(seen, take!(ch))
            end
        catch
        end

        try
            initial_upgrades = MockWS.upgrade_count(mock)
            MockWS.force_drop!(mock)

            @test _wait_until(timeout_s=3.0) do
                MockWS.upgrade_count(mock) > initial_upgrades &&
                    client.connection.status == SurrealDB.STATUS_CONNECTED
            end

            # Allow the post-reconnect CONNECTED event to flush.
            @test _wait_until(timeout_s=2.0) do
                any(ev -> ev.status == SurrealDB.STATUS_RECONNECTING, seen) &&
                    any(ev -> ev.status == SurrealDB.STATUS_CONNECTED && ev.attempt >= 1, seen)
            end

            reconnecting = filter(ev -> ev.status == SurrealDB.STATUS_RECONNECTING, seen)
            @test !isempty(reconnecting)
            # At least one RECONNECTING carries a non-zero attempt count.
            @test any(ev -> ev.attempt >= 1, reconnecting)

            # The post-reconnect CONNECTED carries attempt>=1 and no cause —
            # the cause field is cleared on successful re-establish.
            reconnected = filter(ev -> ev.status == SurrealDB.STATUS_CONNECTED && ev.attempt >= 1, seen)
            @test !isempty(reconnected)
            @test all(ev -> ev.cause === nothing, reconnected)
        finally
            try; SurrealDB.close!(client); catch; end
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "FnLogger fires synchronously with the LifecycleEvent" begin
    seen = SurrealDB.LifecycleEvent[]
    logger = SurrealDB.FnLogger(ev -> push!(seen, ev))
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8),
                                        logger=logger)
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTING)
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTED;
                                attempt=2, cause=nothing)
    # Logger runs synchronously — no sleep needed before assertions.
    @test length(seen) == 2
    @test seen[1].status == SurrealDB.STATUS_CONNECTING
    @test seen[2].status == SurrealDB.STATUS_CONNECTED
    @test seen[2].attempt == 2
end

@testset "NullLogger is the default and silently drops events" begin
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8))
    @test conn.logger isa SurrealDB.NullLogger
    # Should not throw.
    SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTED)
    @test conn.status == SurrealDB.STATUS_CONNECTED
end

@testset "Logger exception is contained — emit path still updates status and channel" begin
    bad = SurrealDB.FnLogger(_ -> error("logger crashed"))
    conn = SurrealDB.RemoteWSConnection(url="ws://localhost:0/rpc",
                                        events=Channel{SurrealDB.LifecycleEvent}(8),
                                        logger=bad)
    # The emit must not propagate the logger exception.
    @test_logs (:warn, "SurrealDB lifecycle logger threw") match_mode=:any begin
        SurrealDB._emit_lifecycle!(conn, SurrealDB.STATUS_CONNECTING)
    end
    @test conn.status == SurrealDB.STATUS_CONNECTING
    sleep(0.05)
    @test isready(conn.events)
    @test take!(conn.events).status == SurrealDB.STATUS_CONNECTING
end

@testset "connect kwarg threads logger onto the connection" begin
    mock = MockWS.start_mock()
    try
        seen = SurrealDB.LifecycleEvent[]
        logger = SurrealDB.FnLogger(ev -> push!(seen, ev))
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)"; logger=logger)
        try
            @test client.connection.logger === logger
            # The successful initial connect fires CONNECTED with attempt=0.
            @test _wait_until(timeout_s=2.0) do
                any(ev -> ev.status == SurrealDB.STATUS_CONNECTED, seen)
            end
            connected = filter(ev -> ev.status == SurrealDB.STATUS_CONNECTED, seen)
            @test !isempty(connected)
            @test connected[1].attempt == 0
            @test connected[1].cause === nothing
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end
