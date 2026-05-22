using SurrealDB
using Test
using Sockets

include("setup.jl")

# Probe whether the integration test server (TEST_URL) is reachable. Lets us
# skip — rather than error — server-dependent testsets when running locally
# without a `surreal start` instance. CI sets SURREALDB_URL and the probe
# always succeeds. Without this gate, a dev who runs the suite without a
# server gets 17 confusing "errored" results that look like real failures.
function _server_reachable(url::String; timeout_s::Float64=0.5)
    m = match(r"^(?:ws|wss|http|https)://([^:/]+):?(\d+)?", url)
    m === nothing && return false
    host = m.captures[1]
    port_str = m.captures[2]
    port = port_str === nothing ? 8000 : parse(Int, port_str)
    return try
        sock = nothing
        ok = Ref(false)
        task = @async begin
            try
                sock = Sockets.connect(host, port)
                ok[] = true
            catch
            end
        end
        deadline = time() + timeout_s
        while time() < deadline && !ok[]
            sleep(0.02)
        end
        sock !== nothing && (try; close(sock); catch; end)
        ok[]
    catch
        false
    end
end

const SERVER_AVAILABLE = _server_reachable(TEST_URL)
SERVER_AVAILABLE || @info "Skipping server-dependent tests — no SurrealDB at $(TEST_URL). Set SURREALDB_URL or start `surreal start --bind 127.0.0.1:8001`."

# Per-testset progress marker. Surfaces "which testset hung?" in CI logs when
# the suite is force-cancelled by the timeout cap. Uses `println` directly +
# explicit flush because @info may buffer behind log level filters and CI log
# tailers cut on the last flushed line.
const _T0 = time()
function _mark(phase::String, name::String)
    elapsed = round(time() - _T0; digits=1)
    println(stdout, "::group::[$phase t=$(elapsed)s] $name")
    println(stderr, "[$phase t=$(elapsed)s] $name")
    flush(stdout); flush(stderr)
end
function _section(fn::Function, name::String)
    _mark("BEGIN", name)
    try
        fn()
    finally
        _mark("END  ", name)
        println(stdout, "::endgroup::"); flush(stdout)
    end
end

@testset "SurrealDB.jl" begin
    # --- No-server testsets (always run) ---

    _section("Types") do
        @testset "Types" begin include("test_types.jl") end
    end
    _section("Public API surface") do
        @testset "Public API surface" begin include("test_api_surface.jl") end
    end
    _section("Aqua") do
        @testset "Aqua" begin include("test_aqua.jl") end
    end
    _section("JET") do
        @testset "JET" begin include("test_jet.jl") end
    end
    _section("Errors") do
        @testset "Errors" begin include("test_errors.jl") end
    end
    _section("Fuzz") do
        @testset "Fuzz" begin include("test_fuzz.jl") end
    end
    _section("Wire codec dispatch") do
        @testset "Wire codec dispatch" begin include("test_wire.jl") end
    end
    _section("HTTP adapt method") do
        @testset "HTTP adapt method" begin include("test_http_adapt.jl") end
    end
    _section("Live KILLED dispatch") do
        @testset "Live KILLED dispatch" begin include("test_live_kill.jl") end
    end
    _section("Reconnect") do
        @testset "Reconnect" begin include("test_reconnect.jl") end
    end
    _section("Reconnect Integration") do
        @testset "Reconnect Integration" begin include("test_reconnect_integration.jl") end
    end
    _section("Tokens / refresh") do
        @testset "Tokens / refresh" begin include("test_tokens.jl") end
    end
    _section("Load resilience") do
        @testset "Load resilience" begin include("test_load_resilience.jl") end
    end
    _section("MetaGraph") do
        @testset "MetaGraph" begin include("test_metagraph.jl") end
    end
    _section("CBOR I/O (L1)") do
        @testset "CBOR I/O (L1)" begin include("test_cbor_io.jl") end
    end
    _section("CBOR codec (L2)") do
        @testset "CBOR codec (L2)" begin include("test_cbor_codec.jl") end
    end
    _section("CBOR parity (vs ciborium)") do
        @testset "CBOR parity (vs ciborium)" begin include("test_cbor_parity.jl") end
    end
    _section("CBOR types: NONE") do
        @testset "CBOR types: NONE" begin include("test_cbor_types_none.jl") end
    end
    _section("CBOR types: RecordID") do
        @testset "CBOR types: RecordID" begin include("test_cbor_types_recordid.jl") end
    end
    _section("CBOR types: UUID") do
        @testset "CBOR types: UUID" begin include("test_cbor_types_uuid.jl") end
    end
    _section("CBOR types: Table") do
        @testset "CBOR types: Table" begin include("test_cbor_types_table.jl") end
    end
    _section("CBOR types: Decimal") do
        @testset "CBOR types: Decimal" begin include("test_cbor_types_decimal.jl") end
    end
    _section("CBOR types: DateTime") do
        @testset "CBOR types: DateTime" begin include("test_cbor_types_datetime.jl") end
    end
    _section("CBOR types: Duration") do
        @testset "CBOR types: Duration" begin include("test_cbor_types_duration.jl") end
    end
    _section("CBOR types: File") do
        @testset "CBOR types: File" begin include("test_cbor_types_file.jl") end
    end
    _section("CBOR types: Set") do
        @testset "CBOR types: Set" begin include("test_cbor_types_set.jl") end
    end
    _section("CBOR types: Range") do
        @testset "CBOR types: Range" begin include("test_cbor_types_range.jl") end
    end
    _section("CBOR types: Geometry") do
        @testset "CBOR types: Geometry" begin include("test_cbor_types_geometry.jl") end
    end

    # --- Server-dependent testsets (gated on SERVER_AVAILABLE) ---

    if SERVER_AVAILABLE
        _section("Connection") do
            @testset "Connection" begin include("test_connection.jl") end
        end
        _section("Auth") do
            @testset "Auth" begin include("test_auth.jl") end
        end
        _section("Methods") do
            @testset "Methods" begin include("test_methods.jl") end
        end
        _section("Query") do
            @testset "Query" begin include("test_query.jl") end
        end
        _section("Session") do
            @testset "Session" begin include("test_session.jl") end
        end
        _section("Live") do
            @testset "Live" begin include("test_live.jl") end
        end
        _section("Integration Gaps") do
            @testset "Integration Gaps" begin include("test_integration_gaps.jl") end
        end
        _section("Go SDK Conformance") do
            @testset "Go SDK Conformance" begin include("test_go_conformance.jl") end
        end
        _section("Type round-trip") do
            @testset "Type round-trip" begin include("test_type_roundtrip.jl") end
        end
        _section("JWT expiry") do
            @testset "JWT expiry" begin include("test_jwt_expiry.jl") end
        end
        _section("Signup") do
            @testset "Signup" begin include("test_signup.jl") end
        end
    end

    # --- Embedded (requires libsurreal) ---

    if SurrealDB.LibSurreal.is_loaded()
        _section("Embedded") do
            @testset "Embedded" begin include("test_embedded.jl") end
        end
        _section("FFI Types") do
            @testset "FFI Types" begin include("test_ffi_types.jl") end
        end
        _section("Memory leak (embedded)") do
            @testset "Memory leak (embedded)" begin include("test_memory.jl") end
        end
    end
end
