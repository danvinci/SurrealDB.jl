using SurrealDB
using Test
using Sockets
using StructTypes  # test_types.jl extends StructType; needs module-scope visibility

include("setup.jl")

# Probe whether the integration test server (TEST_URL) is reachable. Locally
# (no SURREALDB_URL) this gates server-dependent testsets so they skip rather
# than error when no `surreal start` is running. When SURREALDB_URL IS set
# (CI, the docker harness) a server is expected: an unreachable one is a hard
# error, never a silent skip, or the suite goes vacuously green having tested
# nothing server-side.
#
# Tries every resolved address: `localhost` yields ::1 AND 127.0.0.1, and a
# server bound IPv4-only is unreachable via ::1. Raw `Sockets.connect(host,…)`
# tries one address and gives up — that false negative silently skipped every
# server test under the harness's shared-netns localhost topology.
function _server_reachable(url::String; timeout_s::Float64=2.0)
    m = match(r"^(?:ws|wss|http|https)://([^:/]+):?(\d+)?", url)
    m === nothing && return false
    host = m.captures[1]
    port = m.captures[2] === nothing ? 8000 : parse(Int, m.captures[2])
    addrs = try
        Sockets.getalladdrinfo(host)
    catch
        return false
    end
    ok = Ref(false)
    for addr in addrs
        @async begin
            try
                sock = Sockets.connect(addr, port)
                ok[] = true
                close(sock)
            catch
            end
        end
    end
    deadline = time() + timeout_s
    while time() < deadline && !ok[]
        sleep(0.02)
    end
    return ok[]
end

const SERVER_EXPECTED = haskey(ENV, "SURREALDB_URL")
const SERVER_AVAILABLE = _server_reachable(TEST_URL)
if SERVER_EXPECTED && !SERVER_AVAILABLE
    error("SURREALDB_URL=$(TEST_URL) is set but no server is reachable there. " *
          "Refusing to skip server tests silently — that would be a vacuous pass. " *
          "Start the server, or unset SURREALDB_URL to run unit-only.")
end
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
        @testset "Types" begin include("sdk/test_types.jl") end
    end
    _section("FFI struct layout") do
        @testset "FFI struct layout" begin include("sdk/test_ffi_layout.jl") end
    end
    _section("Public API surface") do
        @testset "Public API surface" begin include("sdk/test_api_surface.jl") end
    end
    _section("Aqua") do
        @testset "Aqua" begin include("sdk/test_aqua.jl") end
    end
    _section("JET") do
        @testset "JET" begin include("sdk/test_jet.jl") end
    end
    _section("Errors") do
        @testset "Errors" begin include("sdk/test_errors.jl") end
    end
    _section("Fuzz") do
        @testset "Fuzz" begin include("sdk/test_fuzz.jl") end
    end
    _section("Wire codec dispatch") do
        @testset "Wire codec dispatch" begin include("sdk/test_wire.jl") end
    end
    _section("query_verbose") do
        @testset "query_verbose" begin include("sdk/test_query_verbose.jl") end
    end
    _section("HTTP adapt method") do
        @testset "HTTP adapt method" begin include("sdk/test_http_adapt.jl") end
    end
    _section("Live KILLED dispatch") do
        @testset "Live KILLED dispatch" begin include("sdk/test_live_kill.jl") end
    end
    _section("Closed lifecycle") do
        @testset "Closed lifecycle" begin include("sdk/test_closed.jl") end
    end
    _section("ExplicitImports") do
        @testset "ExplicitImports" begin include("sdk/test_explicit_imports.jl") end
    end
    _section("Reconnect") do
        @testset "Reconnect" begin include("sdk/test_reconnect.jl") end
    end
    _section("Reconnect Integration") do
        @testset "Reconnect Integration" begin include("sdk/test_reconnect_integration.jl") end
    end
    _section("Lifecycle events") do
        @testset "Lifecycle events" begin include("sdk/test_lifecycle_events.jl") end
    end
    _section("Tokens / refresh") do
        @testset "Tokens / refresh" begin include("sdk/test_tokens.jl") end
    end
    _section("Version check") do
        @testset "Version check" begin include("sdk/test_version_check.jl") end
    end
    _section("Load resilience") do
        @testset "Load resilience" begin include("sdk/test_load_resilience.jl") end
    end
    _section("MetaGraph") do
        @testset "MetaGraph" begin include("sdk/test_metagraph.jl") end
    end
    _section("CBOR I/O (L1)") do
        @testset "CBOR I/O (L1)" begin include("sdk/cbor/test_cbor_io.jl") end
    end
    _section("CBOR codec (L2)") do
        @testset "CBOR codec (L2)" begin include("sdk/cbor/test_cbor_codec.jl") end
    end
    _section("CBOR parity (vs ciborium)") do
        @testset "CBOR parity (vs ciborium)" begin include("sdk/cbor/test_cbor_parity.jl") end
    end
    _section("CBOR types: NONE") do
        @testset "CBOR types: NONE" begin include("sdk/cbor/test_cbor_types_none.jl") end
    end
    _section("CBOR types: RecordID") do
        @testset "CBOR types: RecordID" begin include("sdk/cbor/test_cbor_types_recordid.jl") end
    end
    _section("CBOR types: UUID") do
        @testset "CBOR types: UUID" begin include("sdk/cbor/test_cbor_types_uuid.jl") end
    end
    _section("CBOR types: Table") do
        @testset "CBOR types: Table" begin include("sdk/cbor/test_cbor_types_table.jl") end
    end
    _section("CBOR types: Decimal") do
        @testset "CBOR types: Decimal" begin include("sdk/cbor/test_cbor_types_decimal.jl") end
    end
    _section("CBOR types: DateTime") do
        @testset "CBOR types: DateTime" begin include("sdk/cbor/test_cbor_types_datetime.jl") end
    end
    _section("CBOR types: Duration") do
        @testset "CBOR types: Duration" begin include("sdk/cbor/test_cbor_types_duration.jl") end
    end
    _section("CBOR types: File") do
        @testset "CBOR types: File" begin include("sdk/cbor/test_cbor_types_file.jl") end
    end
    _section("CBOR types: Set") do
        @testset "CBOR types: Set" begin include("sdk/cbor/test_cbor_types_set.jl") end
    end
    _section("CBOR types: Range") do
        @testset "CBOR types: Range" begin include("sdk/cbor/test_cbor_types_range.jl") end
    end
    _section("CBOR types: Geometry") do
        @testset "CBOR types: Geometry" begin include("sdk/cbor/test_cbor_types_geometry.jl") end
    end

    # --- Server-dependent testsets (gated on SERVER_AVAILABLE) ---

    if SERVER_AVAILABLE
        _section("Connection") do
            @testset "Connection" begin include("sdk/test_connection.jl") end
        end
        _section("Auth") do
            @testset "Auth" begin include("sdk/test_auth.jl") end
        end
        _section("Methods") do
            @testset "Methods" begin include("sdk/test_methods.jl") end
        end
        _section("Query") do
            @testset "Query" begin include("sdk/test_query.jl") end
        end
        _section("Session") do
            @testset "Session" begin include("sdk/test_session.jl") end
        end
        _section("Live") do
            @testset "Live" begin include("sdk/test_live.jl") end
        end
        _section("Transactions") do
            @testset "Transactions" begin include("sdk/test_transactions.jl") end
        end
        _section("Typed structs") do
            @testset "Typed structs" begin include("sdk/test_typed_struct.jl") end
        end
        _section("Type round-trip") do
            @testset "Type round-trip" begin include("sdk/test_type_roundtrip.jl") end
        end
        _section("JWT expiry") do
            @testset "JWT expiry" begin include("sdk/test_jwt_expiry.jl") end
        end
        _section("Signup") do
            @testset "Signup" begin include("sdk/test_signup.jl") end
        end
    end

    # --- Embedded (requires libsurreal) ---

    if SurrealDB.LibSurreal.is_loaded()
        _section("Embedded") do
            @testset "Embedded" begin include("sdk/test_embedded.jl") end
        end
        _section("FFI Types") do
            @testset "FFI Types" begin include("sdk/test_ffi_types.jl") end
        end
        _section("Memory leak (embedded)") do
            @testset "Memory leak (embedded)" begin include("sdk/test_memory.jl") end
        end
    end
end
