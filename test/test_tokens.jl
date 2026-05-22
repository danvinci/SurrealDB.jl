# Typed Tokens + proactive JWT refresh.
#
# Covers the no-server pieces (struct shape, JWT exp parsing, redaction) and
# the mock-WS pieces (refresh! RPC over the wire, proactive timer firing,
# tokens replay through signin!/invalidate!). Mirrors the test pattern in
# test_reconnect_integration.jl for the mock-server scaffolding.

using SurrealDB
using Test
using Base64
using JSON

include("mock_ws_server.jl")

# Build a JWT (header.payload.signature) with the supplied payload. Signature
# is a fixed placeholder — the SDK never verifies it, only decodes `exp`.
function _make_jwt(payload::AbstractDict)
    header = Dict("alg" => "HS256", "typ" => "JWT")
    h = rstrip(replace(base64encode(JSON.json(header)),  '+' => '-', '/' => '_'), '=')
    p = rstrip(replace(base64encode(JSON.json(payload)), '+' => '-', '/' => '_'), '=')
    return string(h, ".", p, ".", "sig")
end

@testset "_parse_jwt_exp: valid token" begin
    exp = 1_700_000_000
    tok = _make_jwt(Dict("exp" => exp, "sub" => "alice"))
    @test SurrealDB._parse_jwt_exp(tok) === exp
end

@testset "_parse_jwt_exp: missing exp claim" begin
    tok = _make_jwt(Dict("sub" => "alice"))
    @test SurrealDB._parse_jwt_exp(tok) === nothing
end

@testset "_parse_jwt_exp: malformed token" begin
    # Not three dot-separated segments
    @test SurrealDB._parse_jwt_exp("not-a-jwt") === nothing
    # Two segments OK structurally, but middle isn't base64-valid JSON
    @test SurrealDB._parse_jwt_exp("aaa.???.bbb") === nothing
    # Valid base64 but not a JSON object
    bad = string("h.", rstrip(base64encode("[1,2,3]"), '='), ".s")
    @test SurrealDB._parse_jwt_exp(bad) === nothing
end

@testset "_parse_jwt_exp: float exp coerced to Int" begin
    tok = _make_jwt(Dict("exp" => 1_700_000_000.5))
    @test SurrealDB._parse_jwt_exp(tok) === 1_700_000_000
end

@testset "Tokens show redacts both fields" begin
    short_access = _make_jwt(Dict("exp" => 1_700_000_000))
    long_refresh = "r" ^ 64

    t = SurrealDB.Tokens(short_access, long_refresh)
    s = sprint(show, t)
    # Truncated token form: `prefix…(length)` — never the raw secret
    @test occursin("Tokens(", s)
    @test !occursin(long_refresh, s)
    @test occursin("…(", s)

    # Refresh=nothing renders as a dash, not the literal token
    t2 = SurrealDB.Tokens(short_access, nothing)
    s2 = sprint(show, t2)
    @test occursin("refresh=-", s2)
end

@testset "signin! without refresh leaves tokens.refresh === nothing" begin
    mock = MockWS.start_mock()  # default: bare-string signin reply
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=999.0)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            tks = SurrealDB.tokens(client)
            @test tks !== nothing
            @test tks.access == "mock-jwt-token"
            @test tks.refresh === nothing
            # Mirror invariant: flat client.token equals tokens.access
            @test client.token == tks.access
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "signin! with typed reply stores both tokens" begin
    access = _make_jwt(Dict("exp" => Int(floor(time())) + 3600))
    mock = MockWS.start_mock(signin_access=access,
                             signin_refresh="REFRESH_TOK")
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=999.0)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            tks = SurrealDB.tokens(client)
            @test tks !== nothing
            @test tks.access == access
            @test tks.refresh == "REFRESH_TOK"
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "refresh! issues `refresh` RPC and updates tokens" begin
    access = _make_jwt(Dict("exp" => Int(floor(time())) + 3600))
    mock = MockWS.start_mock(signin_access=access,
                             signin_refresh="REFRESH_TOK")
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=999.0)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            seen_before = length(MockWS.methods_seen(mock))

            new_access = SurrealDB.refresh!(client)
            @test new_access == "NEW_JWT"
            tks = SurrealDB.tokens(client)
            @test tks.access == "NEW_JWT"
            @test tks.refresh == "NEW_REFRESH"
            @test client.token == "NEW_JWT"

            replayed = MockWS.methods_seen(mock)[seen_before+1:end]
            @test "refresh" in replayed
            @test MockWS.refresh_count(mock) == 1
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "refresh! throws NotAllowedError without refresh token" begin
    mock = MockWS.start_mock()  # bare-string signin → no refresh
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=999.0)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            @test_throws SurrealDB.NotAllowedError SurrealDB.refresh!(client)
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "proactive timer fires before exp" begin
    # exp ~2s out + 1.8s lead → timer fires ~0.2s after signin. Tolerate
    # ~500ms slop on the assertion to absorb scheduling noise on loaded CI.
    exp = Int(floor(time())) + 2
    access = _make_jwt(Dict("exp" => exp))
    mock = MockWS.start_mock(signin_access=access,
                             signin_refresh="REFRESH_TOK")
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=1.8)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            # Timer should have been scheduled
            @test client.connection.refresh_timer !== nothing

            deadline = time() + 2.5
            while time() < deadline && MockWS.refresh_count(mock) < 1
                sleep(0.05)
            end
            @test MockWS.refresh_count(mock) >= 1
            tks = SurrealDB.tokens(client)
            @test tks.access == "NEW_JWT"
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "timer fired during reconnect does NOT clear tokens" begin
    # Regression: a timer firing while the connection is STATUS_RECONNECTING
    # used to fall into refresh!'s catch path and wipe the tokens, leaving
    # the post-reconnect session unauthenticated. Now it skips silently and
    # waits for _reconnect_apply_state! to re-schedule.
    exp = Int(floor(time())) + 2
    access = _make_jwt(Dict("exp" => exp))
    mock = MockWS.start_mock(signin_access=access, signin_refresh="REFRESH_TOK")
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=1.8)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            tks_before = SurrealDB.tokens(client)
            @test tks_before !== nothing
            initial_refreshes = MockWS.refresh_count(mock)

            # Simulate a reconnect-in-flight: flip status, wait for the
            # timer to fire (~0.2s after signin), check tokens survived.
            client.connection.status = SurrealDB.STATUS_RECONNECTING
            sleep(0.7)
            @test SurrealDB.tokens(client) === tks_before  # untouched
            @test MockWS.refresh_count(mock) == initial_refreshes  # no RPC issued
        finally
            # Restore status before close so cleanup paths run normally.
            client.connection.status = SurrealDB.STATUS_CONNECTED
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end

@testset "invalidate! clears tokens and cancels timer" begin
    access = _make_jwt(Dict("exp" => Int(floor(time())) + 3600))
    mock = MockWS.start_mock(signin_access=access,
                             signin_refresh="REFRESH_TOK")
    try
        client = SurrealDB.connect("ws://127.0.0.1:$(mock.port)";
                                   refresh_lead_time=10.0)
        try
            SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
            @test SurrealDB.tokens(client) !== nothing
            @test client.connection.refresh_timer !== nothing

            SurrealDB.invalidate!(client)
            @test SurrealDB.tokens(client) === nothing
            @test client.token === nothing
            @test client.connection.refresh_timer === nothing
        finally
            SurrealDB.close!(client)
        end
    finally
        MockWS.stop_mock!(mock)
    end
end
