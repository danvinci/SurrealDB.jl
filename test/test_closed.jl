# Closed-lifecycle guards on SurrealClient + SurrealSession. The fix replaces
# the previous "close! mutates fields to nothing, downstream RPC silently
# fails server-side" pattern with an explicit `closed::Bool` + `_check_open`
# guard that throws `ConnectionUnavailableError` at the call site.

using SurrealDB
using Test

include("mock_ws_server.jl")

@testset "closed: SurrealClient guard" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        @test client.closed === false

        # Pre-close: RPC works.
        @test SurrealDB.ping(client) === true
        SurrealDB._check_open(client)  # no throw

        # Close: flag flips, fields cleared.
        SurrealDB.close!(client)
        @test client.closed === true
        @test isnothing(client.namespace)

        # Post-close: every RPC throws ConnectionUnavailableError, not a
        # server-side nil-field downstream error.
        @test_throws SurrealDB.ConnectionUnavailableError SurrealDB.query(client, "RETURN 1")
        @test_throws SurrealDB.ConnectionUnavailableError SurrealDB.use!(client, "x", "y")
        @test_throws SurrealDB.ConnectionUnavailableError SurrealDB._check_open(client)

        # close! is idempotent.
        SurrealDB.close!(client)
        @test client.closed === true
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "closed: SurrealSession guard" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        try
            # Construct a session directly. Bypasses attach! (which needs a v3
            # server) — the closed lifecycle is independent of the server's
            # session-machinery support.
            sess = SurrealDB.SurrealSession{typeof(client.connection)}(
                client, Base.UUID(UInt128(1)), false)
            @test sess.closed === false
            SurrealDB._check_open(sess)  # no throw

            # Closing the session sets the flag; client unaffected.
            sess.closed = true
            @test_throws SurrealDB.ConnectionUnavailableError SurrealDB._check_open(sess)
            @test_throws SurrealDB.ConnectionUnavailableError SurrealDB.begin!(sess)
            # SurrealTransaction wrapper: construct directly (bypass begin!) to
            # exercise the txn-side guard on a closed session.
            fake_txn = SurrealDB.SurrealTransaction{typeof(client.connection)}(
                sess, Base.UUID(UInt128(2)), false)
            @test_throws SurrealDB.ConnectionUnavailableError SurrealDB.commit!(fake_txn)
            @test_throws SurrealDB.ConnectionUnavailableError SurrealDB.cancel!(fake_txn)

            # Client still works (until we close it).
            SurrealDB._check_open(client)
            @test SurrealDB.ping(client) === true

            # Closing the client cascades: session guard now fails on the
            # wrapped client even if we reset session.closed.
            SurrealDB.close!(client)
            sess.closed = false
            @test_throws SurrealDB.ConnectionUnavailableError SurrealDB._check_open(sess)
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end
