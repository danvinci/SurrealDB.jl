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

    # ns/db preflight — pass both or neither (mirrors JS controller:312).
    @test_throws SurrealDB.MissingNamespaceDatabaseError SurrealDB.connect(
        "ws://127.0.0.1:1"; db="foo")
    @test_throws SurrealDB.MissingNamespaceDatabaseError SurrealDB.connect(
        "ws://127.0.0.1:1"; ns="bar")
    # Both nil → past preflight; throws ConnectionError on the unreachable URL.
    @test_throws SurrealDB.ConnectionError SurrealDB.connect(
        "ws://127.0.0.1:1"; connect_timeout=0.2)
end

@testset "wire: CBOR encode error wrapping" begin
    # BigInt larger than UInt64 overflows the CBOR uint range and triggers
    # a `SurrealCBOR.CBORError` (codec.jl:73). The wire layer re-throws as a
    # transport-friendly `SerializationError`.
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    too_big = BigInt(typemax(UInt64)) + 1
    @test_throws SurrealDB.SerializationError _W._wire_encode(cc, Dict("n" => too_big))
end

@testset "wire: Missing + Set round-trip on JSON wire (no lower needed)" begin
    # CBOR decoder maps Surreal NONE → `missing` and Surreal Set → Julia
    # `Set{T}`. JSON.jl handles both natively (missing → null, Set → JSON
    # array). Pin the behavior so a future JSON.jl change surfaces here
    # rather than corrupting wire shape silently.
    using JSON
    cj = _W.RemoteConnection{:ws, :json}(url="ws://x")
    @test occursin("null", String(_W._wire_encode(cj, Dict("v" => missing))))
    @test occursin("[1,2,3]", JSON.json(sort!(collect(Set([1, 2, 3])))))
    s_payload = _W._wire_encode(cj, Dict("v" => Set([1, 2, 3])))
    @test occursin("[", String(s_payload)) && occursin("]", String(s_payload))
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

include("../mock_ws_server.jl")

function _wire_wait_until(pred; timeout_s::Float64=2.0, step_s::Float64=0.025)
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

@testset "wire: type fidelity — RecordID + Table through both wires" begin
    # Regression guard for the s12-s13 transition: methods.jl no longer
    # pre-stringifies typed values at the application layer. JSON wire must
    # still produce the canonical `"user:alice"` shape (via JSON.lower); CBOR
    # must preserve the type as Tag(8, [table, key]) / Tag(7, name).
    r = SurrealDB.RecordID("user", "alice")
    t = SurrealDB.Table("user")
    env = Dict{String, Any}("id" => 1, "method" => "select", "params" => Any[r])

    # --- JSON wire ---
    cj = _W.RemoteConnection{:ws, :json}(url="ws://x")
    enc_j = _W._wire_encode(cj, env)
    # Canonical wire shape: bare string, not the struct-shaped default
    # JSON.jl would otherwise emit for a RecordID.
    @test occursin("\"user:alice\"", enc_j)
    @test !occursin("\"table\":", enc_j)
    # Table lowers to its name string.
    env_t = Dict{String, Any}("id" => 1, "method" => "select", "params" => Any[t])
    enc_jt = _W._wire_encode(cj, env_t)
    @test occursin("\"user\"", enc_jt)
    @test !occursin("\"name\":", enc_jt)

    # --- CBOR wire ---
    cc = _W.RemoteConnection{:ws, :cbor}(url="ws://x")
    enc_c = _W._wire_encode(cc, env)
    # 0xc8 = Tag(8, ...) header byte; presence confirms typed encode.
    @test 0xc8 in enc_c
    # Round-trip back to a typed RecordID.
    dec_c = _W._wire_decode(cc, enc_c)
    @test dec_c["params"][1] isa SurrealDB.RecordID
    @test dec_c["params"][1].table == "user"
    @test dec_c["params"][1].id == "alice"
    # Table → Tag(7); round-trip preserves Table type.
    enc_ct = _W._wire_encode(cc, env_t)
    @test 0xc7 in enc_ct
    dec_ct = _W._wire_decode(cc, enc_ct)
    @test dec_ct["params"][1] isa SurrealDB.Table
    @test dec_ct["params"][1].name == "user"

    # --- The rest of the typed-value family ---

    cj_env(v) = _W._wire_encode(cj, Dict("v" => v))
    cc_env(v) = _W._wire_encode(cc, Dict("v" => v))

    # Decimal: bare numeric string, no quoting of struct fields.
    d = SurrealDecimal("123.45")
    @test occursin("\"v\":\"123.45\"", cj_env(d))
    @test 0xca in cc_env(d)  # Tag 10
    @test _W._wire_decode(cc, cc_env(d)) == Dict("v" => d)

    # DateTime: ISO 8601 with 9-digit fractional seconds + Z.
    dt = SurrealDateTime(1700000000, 123456789)
    j = String(cj_env(dt))
    @test occursin("\"v\":\"2023-11-14T22:13:20.123456789Z\"", j)
    @test _W._wire_decode(cc, cc_env(dt)) == Dict("v" => dt)

    # Duration: compact SurrealQL form, all four shape branches.
    @test occursin("\"v\":\"0ns\"",          String(cj_env(SurrealDuration(0, 0))))
    @test occursin("\"v\":\"60s\"",          String(cj_env(SurrealDuration(60, 0))))
    @test occursin("\"v\":\"750ns\"",        String(cj_env(SurrealDuration(0, 750))))
    @test occursin("\"v\":\"42s500ns\"",     String(cj_env(SurrealDuration(42, 500))))

    # File: "bucket:key" — same shape as RecordID-style refs.
    f = SurrealFile("bucket-a", "key-b")
    @test occursin("\"v\":\"bucket-a:key-b\"", String(cj_env(f)))
    @test _W._wire_decode(cc, cc_env(f)) == Dict("v" => f)

    # Geometry: GeoJSON shape (presence of type + coordinates fields).
    pt = GeometryPoint(1.5, 2.5)
    jpt = String(cj_env(pt))
    @test occursin("\"type\":\"Point\"", jpt)
    @test occursin("\"coordinates\":[1.5,2.5]", jpt)
    @test _W._wire_decode(cc, cc_env(pt)) == Dict("v" => pt)

    poly = GeometryPolygon(
        GeometryLine([GeometryPoint(0.0,0.0), GeometryPoint(1.0,0.0),
                      GeometryPoint(1.0,1.0), GeometryPoint(0.0,0.0)]),
        GeometryLine[]
    )
    jpoly = String(cj_env(poly))
    @test occursin("\"type\":\"Polygon\"", jpoly)
    @test occursin("\"coordinates\":[[[0.0,0.0]", jpoly)
    @test _W._wire_decode(cc, cc_env(poly)) == Dict("v" => poly)

    # GeometryCollection nests recursively through JSON.lower.
    gc = GeometryCollection([GeometryPoint(0.0,0.0),
                              GeometryMultiPoint([GeometryPoint(1.0,1.0)])])
    jgc = String(cj_env(gc))
    @test occursin("\"type\":\"GeometryCollection\"", jgc)
    @test occursin("\"type\":\"Point\"", jgc)
    @test occursin("\"type\":\"MultiPoint\"", jgc)

    # Range: structured object with explicit inclusivity; unbounded → null.
    rg = SurrealRange(BoundIncluded(1), BoundExcluded(10))
    jrg = String(cj_env(rg))
    @test occursin("\"inclusive\":true", jrg)
    @test occursin("\"inclusive\":false", jrg)
    @test occursin("\"value\":1", jrg)
    @test occursin("\"value\":10", jrg)
    junb = String(cj_env(SurrealRange(BoundIncluded(1), nothing)))
    @test occursin("\"stop\":null", junb)
    # CBOR round-trip preserves Range structure.
    @test _W._wire_decode(cc, cc_env(rg)) == Dict("v" => rg)

    # --- Embedded inside a data Dict (insert_relation shape) ---
    payload = Dict{String, Any}(
        "in"  => SurrealDB.RecordID("person", "john"),
        "out" => SurrealDB.RecordID("person", "jane"),
        "kind" => "knows"
    )
    env_ir = Dict{String, Any}("id" => 2, "method" => "insert_relation",
                                "params" => Any[SurrealDB.Table("knows"), payload])
    # JSON lowers all three.
    enc_ir_j = _W._wire_encode(cj, env_ir)
    @test occursin("\"person:john\"", enc_ir_j)
    @test occursin("\"person:jane\"", enc_ir_j)
    @test occursin("\"knows\"", enc_ir_j)
    # CBOR preserves all three as their tags.
    enc_ir_c = _W._wire_encode(cc, env_ir)
    dec_ir_c = _W._wire_decode(cc, enc_ir_c)
    @test dec_ir_c["params"][1] isa SurrealDB.Table
    @test dec_ir_c["params"][2]["in"] isa SurrealDB.RecordID
    @test dec_ir_c["params"][2]["out"] isa SurrealDB.RecordID
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

@testset "wire: embedded transport covers every RPC method" begin
    # Drift detector for the embedded dispatcher. SurrealDB._RPC_METHODS is the
    # canonical set of every RPC method the SDK invokes via `_rpc_call`. Every
    # entry must be dispatched on EmbeddedConnection — either via the _RPC_ARMS
    # table, a special-case branch, or an explicit UnsupportedFeatureError. A
    # silent fall-through to the generic else-arm is the drift we want to catch.
    table_keys = Set(keys(SurrealDB.Embedded._RPC_ARMS))
    special    = Set(SurrealDB.Embedded._EMBEDDED_SPECIAL_CASE)
    unsupp     = Set(SurrealDB.Embedded._EMBEDDED_UNSUPPORTED)

    # Coverage: every wire-known method lives in exactly one of the three sets.
    for m in SurrealDB._RPC_METHODS
        @test m in table_keys || m in special || m in unsupp
    end

    # Disjointness: a method handled twice is a wiring bug.
    @test isempty(intersect(table_keys, special))
    @test isempty(intersect(table_keys, unsupp))
    @test isempty(intersect(special, unsupp))

    # No spurious entries — every embedded-listed method must also be in the
    # wire-level set (catches stale entries when an SDK call is removed).
    @test issubset(table_keys, Set(SurrealDB._RPC_METHODS))
    @test issubset(special,    Set(SurrealDB._RPC_METHODS))
    @test issubset(unsupp,     Set(SurrealDB._RPC_METHODS))
end
