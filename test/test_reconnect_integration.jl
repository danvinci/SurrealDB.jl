# Reconnect integration tests against an in-process mock WebSocket server.
# Complements the deterministic state-machine tests in test_reconnect.jl.
#
# What's covered here that test_reconnect.jl can't:
# - The actual `_ws_reconnect_loop` running over a real socket.
# - State replay (`_reconnect_apply_state!`) re-issuing use!/authenticate!
#   after a drop, observed via the mock's `methods_seen` log.
# - reconnect=false short-circuiting the loop.
# - Failure modes when the server is unreachable.

using SurrealDB
using Test
using Sockets

include("mock_ws_server.jl")

# Wait until `pred()` returns true or `timeout_s` elapses. Returns whether the
# predicate held by the deadline. Polls every 50ms — fast enough that a 1s
# timeout is responsive without burning CPU.
function _wait_until(pred; timeout_s::Float64=2.0, step_s::Float64=0.05)
    deadline = time() + timeout_s
    while time() < deadline
        pred() && return true
        sleep(step_s)
    end
    return pred()
end

@testset "connect happy path" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        try
            @test client.connection.status == :connected
            SurrealDB.use!(client, "ns", "db")
            @test "use" in MockWS.methods_seen(mock)
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "connect do-block auto-closes" begin
    # The function form mirrors Base.open: client closed on block exit.
    mock = MockWS.start_mock()
    try
        captured = Ref{Any}(nothing)
        result = SurrealDB.connect("ws://127.0.0.1:$(mock.port)") do db
            captured[] = db
            @test db.connection.status == :connected
            SurrealDB.use!(db, "ns", "db")
            42
        end
        @test result == 42
        # Client was closed inside the block.
        @test captured[] !== nothing
        @test captured[].connection.status == :disconnected
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "connect do-block closes on exception" begin
    mock = MockWS.start_mock()
    try
        captured = Ref{Any}(nothing)
        @test_throws ErrorException SurrealDB.connect("ws://127.0.0.1:$(mock.port)") do db
            captured[] = db
            error("boom")
        end
        # Block threw, but client was still closed.
        @test captured[] !== nothing
        @test captured[].connection.status == :disconnected
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "reconnect after force_drop replays use!/authenticate!" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        # Tighten reconnect timing so the test runs fast.
        client.connection.reconnect_base_delay = 0.05
        client.connection.reconnect_max_delay = 0.5
        client.connection.reconnect_jitter = 0.0

        try
            SurrealDB.use!(client, "ns", "db")
            # Set token directly so reconnect re-applies it without contacting
            # a real signin endpoint (the mock would happily accept signin too,
            # but we want to assert just the auth replay branch).
            client.token = "tok-pre-drop"

            seen_before = length(MockWS.methods_seen(mock))
            initial_upgrades = MockWS.upgrade_count(mock)

            # Drop the active socket out-of-band.
            MockWS.force_drop!(mock)

            # Wait for the reconnect loop to bring the socket back up.
            ok = _wait_until(() -> MockWS.upgrade_count(mock) > initial_upgrades;
                              timeout_s=3.0)
            @test ok
            @test _wait_until(() -> client.connection.status == :connected;
                              timeout_s=3.0)

            # _reconnect_apply_state! should have re-issued `use` + `authenticate`
            # on the new socket. They appear AFTER the seen_before mark.
            ok2 = _wait_until(timeout_s=2.0) do
                replayed = MockWS.methods_seen(mock)[seen_before+1:end]
                "use" in replayed && "authenticate" in replayed
            end
            @test ok2
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "reconnect=false: no re-attempt after drop" begin
    mock = MockWS.start_mock()
    try
        # reconnect kwarg is plumbed through connect(), no manual mutation.
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   reconnect=false)
        @test client.connection.reconnect == false
        try
            SurrealDB.use!(client, "ns", "db")
            initial_upgrades = MockWS.upgrade_count(mock)

            MockWS.force_drop!(mock)

            # Status moves to :disconnected (loop exits), no second upgrade.
            @test _wait_until(timeout_s=2.0) do
                client.connection.status == :disconnected
            end
            @test MockWS.upgrade_count(mock) == initial_upgrades
        finally
            try; SurrealDB.close!(client); catch; end
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "reconnect tuning kwargs are applied" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   reconnect_max_attempts=3,
                                   reconnect_base_delay=0.05,
                                   reconnect_max_delay=0.5,
                                   reconnect_jitter=0.0,
                                   ping_interval=0.0)
        try
            @test client.connection.reconnect_max_attempts == 3
            @test client.connection.reconnect_base_delay == 0.05
            @test client.connection.reconnect_max_delay == 0.5
            @test client.connection.reconnect_jitter == 0.0
            @test client.connection.ping_interval == 0.0
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "live subscription handle re-keyed on reconnect" begin
    # Test approach: stand up a live() against the mock, drop the socket, and
    # assert the handle's query_id was overwritten with a fresh UUID. The mock
    # generates a unique uuid4() per `live` call.
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        client.connection.reconnect_base_delay = 0.05
        client.connection.reconnect_max_delay = 0.5
        client.connection.reconnect_jitter = 0.0
        try
            SurrealDB.use!(client, "ns", "db")
            sub = SurrealDB.live(client, "stream")
            qid_before = sub.query_id
            @test qid_before isa AbstractString && !isempty(qid_before)

            initial_upgrades = MockWS.upgrade_count(mock)
            MockWS.force_drop!(mock)

            @test _wait_until(timeout_s=3.0) do
                MockWS.upgrade_count(mock) > initial_upgrades &&
                    client.connection.status == :connected
            end

            # _reconnect_apply_state! re-issues `live`; the new server-assigned
            # UUID overwrites the handle's query_id. Allow a brief settle.
            @test _wait_until(timeout_s=2.0) do
                sub.query_id != qid_before
            end
            @test sub.query_id != qid_before
        finally
            try; SurrealDB.close!(client); catch; end
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "connect fails fast when no server" begin
    # Bind a TCP listener and immediately close it so the port is free; this
    # gives us a deterministically-unused port (vs. picking 1 and hoping).
    probe = listen(IPv4("127.0.0.1"), 0)
    free_port = Int(getsockname(probe)[2])
    close(probe)

    err = try
        SurrealDB.connect("ws://127.0.0.1:$free_port")
        nothing
    catch e
        e
    end
    @test err isa SurrealDB.ConnectionError
    # The thrown error must reference the underlying cause so users can
    # debug "ECONNREFUSED" vs. "TLS handshake" vs. "DNS unresolvable" etc.,
    # not just see a useless "Failed to connect".
    @test err.cause !== nothing
    msg = sprint(showerror, err)
    @test occursin("Failed to connect", msg)
end

@testset "lifecycle events fire for connect / drop / reconnect" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        client.connection.reconnect_base_delay = 0.05
        client.connection.reconnect_max_delay = 0.5
        client.connection.reconnect_jitter = 0.0
        ch = SurrealDB.events(client)
        try
            seen = Symbol[]
            collector = @async try
                while isopen(ch)
                    ev = take!(ch)
                    push!(seen, ev)
                end
            catch
            end

            MockWS.force_drop!(mock)
            @test _wait_until(timeout_s=3.0) do
                client.connection.status == :connected &&
                    :reconnecting in seen
            end

            # Drop+reconnect should produce :reconnecting and a new :connected.
            @test :reconnecting in seen
            @test count(==(:connected), seen) >= 1
        finally
            try; SurrealDB.close!(client); catch; end
        end
    finally
        MockWS.stop_mock!(mock)
    end
end
