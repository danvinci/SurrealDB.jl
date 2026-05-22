# Wire codec dispatch — unit tests for the W type param plumbing.
#
# Three layers covered:
#   1. Struct parametrization: RemoteConnection{P, W} resolves both params,
#      aliases stay UnionAll-compatible, defaulting outer constructor still
#      lands on `W = :json` for back-compat with pre-CBOR test sites.
#   2. Codec dispatch: `_wire_encode` / `_wire_decode` pick JSON or CBOR by
#      the connection's W; round-trip of a sample RPC envelope.
#   3. `connect(; wire=...)` validation: bad wire symbol throws, good wires
#      thread through to the connection's type.
#
# Mock-WS integration (CBOR handshake + frames) lives in
# test_reconnect_integration.jl — exercised there because the mock plumbing
# is already wired into those tests.

using SurrealDB
using Test

const _W = SurrealDB  # short alias for internal helpers

@testset "wire: struct parametrization" begin
    # Both forms construct concretely.
    cj = _W.RemoteConnection{:ws, :json}(url="ws://x")
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    @test cj isa _W.RemoteConnection{:ws, :json}
    @test cc isa _W.RemoteConnection{:ws, :cbor}

    # UnionAll aliases match either wire.
    @test cj isa _W.RemoteWSConnection
    @test cc isa _W.RemoteWSConnection
    @test cj isa _W.RemoteConnection{:ws}
    @test cc isa _W.RemoteConnection{:ws}

    # Defaulting outer constructor: bare alias call still yields :json — keeps
    # pre-CBOR test sites that wrote `RemoteWSConnection(url=...)` working.
    bare = _W.RemoteWSConnection(url="ws://x")
    @test bare isa _W.RemoteConnection{:ws, :json}

    # HTTP analogue.
    hc = _W.RemoteConnection{:http, :cbor}(url="http://x")
    @test hc isa _W.RemoteHTTPConnection
end

@testset "wire: codec dispatch" begin
    cj = _W.RemoteConnection{:ws, :json}(url="ws://x")
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    msg = Dict{String, Any}("id" => 1, "method" => "ping", "params" => Any[])

    # JSON: encode returns String, decode parses back to the same Dict shape.
    enc_j = _W._wire_encode(cj, msg)
    @test enc_j isa String
    dec_j = _W._wire_decode(cj, enc_j)
    @test dec_j == msg

    # CBOR: encode returns Vector{UInt8}, decode round-trips.
    enc_c = _W._wire_encode(cc, msg)
    @test enc_c isa Vector{UInt8}
    dec_c = _W._wire_decode(cc, enc_c)
    @test dec_c["id"] == 1
    @test dec_c["method"] == "ping"
    @test dec_c["params"] == Any[]

    # Subprotocol + content-type wire-format introspection.
    @test _W._wire_subprotocol(cj) == "json"
    @test _W._wire_subprotocol(cc) == "cbor"
    @test _W._wire_content_type(cj) == "application/json"
    @test _W._wire_content_type(cc) == "application/cbor"
    @test _W._wire(cj) === :json
    @test _W._wire(cc) === :cbor
end

@testset "wire: write_channel element type matches W" begin
    chj = _W._new_write_channel(Val(:json))
    chc = _W._new_write_channel(Val(:cbor))
    @test chj isa Channel{String}
    @test chc isa Channel{Vector{UInt8}}

    # Connection-typed convenience form.
    cj = _W.RemoteConnection{:ws, :json}(url="ws://x")
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    @test _W._new_write_channel(cj) isa Channel{String}
    @test _W._new_write_channel(cc) isa Channel{Vector{UInt8}}
end

@testset "wire: connect() kwarg validation" begin
    # Bad wire symbol — caught before any socket work.
    @test_throws ArgumentError SurrealDB.connect("ws://127.0.0.1:1"; wire=:bson)
    @test_throws ArgumentError SurrealDB.connect("http://127.0.0.1:1"; wire=:msgpack)
end

@testset "wire: CBOR encode error wrapping" begin
    # BigInt larger than UInt64 overflows the CBOR uint range and triggers
    # a `SurrealCBOR.CBORError` (codec.jl:73). The wire layer re-throws as a
    # transport-friendly `SerializationError`.
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    too_big = BigInt(typemax(UInt64)) + 1
    @test_throws SurrealDB.SerializationError _W._wire_encode(cc, Dict("n" => too_big))
end

@testset "wire: CBOR decode error wrapping" begin
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    # 0x1c = major-0 + ai=28; RFC 8949 reserves ai=28..30. SurrealCBOR
    # raises CBORError("reserved additional info: 28"); wire layer
    # re-throws as SerializationError.
    @test_throws SurrealDB.SerializationError _W._wire_decode(cc, UInt8[0x1c])
end

# --- Mock-WS integration: end-to-end handshake + RPC over both wires ---
#
# The mock server (test/mock_ws_server.jl) echoes the negotiated subprotocol
# and uses its codec for frame encoding. Exercises the actual reconnect
# loop + reader/writer tasks rather than just the codec helpers.

include("mock_ws_server.jl")

function _wire_wait_until(pred; timeout_s::Float64=2.0, step_s::Float64=0.05)
    deadline = time() + timeout_s
    while time() < deadline
        pred() && return true
        sleep(step_s)
    end
    return pred()
end

@testset "wire: mock-WS handshake — explicit JSON" begin
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)"; wire=:json)
        try
            @test _wire_wait_until(() -> client.connection.status == SurrealDB.STATUS_CONNECTED)
            @test client.connection isa SurrealDB.RemoteConnection{:ws, :json}
            @test SurrealDB.ping(client) === true
            @test "ping" in MockWS.methods_seen(mock)
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "wire: mock-WS handshake — default (CBOR)" begin
    # `connect(...)` with no `wire=` defaults to :cbor per the user's
    # direction; this exercises the full CBOR path through the mock.
    mock = MockWS.start_mock()
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)")
        try
            @test _wire_wait_until(() -> client.connection.status == SurrealDB.STATUS_CONNECTED)
            @test client.connection isa SurrealDB.RemoteConnection{:ws, :cbor}
            @test SurrealDB.ping(client) === true
            @test "ping" in MockWS.methods_seen(mock)
            # Use! + info should round-trip end-to-end over CBOR frames.
            SurrealDB.use!(client, "ns", "db")
            @test "use" in MockWS.methods_seen(mock)
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end
