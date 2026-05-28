# Shared test setup for SurrealDB.jl

using SurrealDB

# Auto-load libsurreal if SURREALDB_LIB is set or the dylib sits under deps/lib/
let lib = get(ENV, "SURREALDB_LIB", "")
    if isempty(lib)
        candidate = joinpath(@__DIR__, "..", "deps", "lib", "libsurrealdb_c.dylib")
        isfile(candidate) && (lib = candidate)
    end
    if !isempty(lib) && !SurrealDB.LibSurreal.is_loaded()
        try
            SurrealDB.libsurreal_load!(lib)
        catch e
            @warn "Could not load libsurreal: $e"
        end
    end
end

const TEST_NS = "test"
const TEST_DB = "test"
const TEST_URL = get(ENV, "SURREALDB_URL", "ws://localhost:8001")

const TEST_WIRE = Symbol(get(ENV, "SURREALDB_WIRE", "cbor"))

function get_test_client(; url=TEST_URL, wire=TEST_WIRE)
    # `ping_interval=0` disables the keepalive task. Without this, every
    # test client spawns a Timer + @async task that may not be torn down
    # cleanly between rapid connect/close cycles, eventually starving the
    # scheduler and making the 6th-or-so connect hang past its 2.5s
    # timeout. Tests don't need keepalive — they're synchronous and
    # short-lived.
    #
    # `wire` defaults to the SURREALDB_WIRE env var (`:cbor` if unset) so
    # CI can pivot the full server-dependent suite between wires via a
    # matrix axis without per-call edits.
    println(stderr, "[get_test_client] connect (wire=$wire)..."); flush(stderr)
    client = SurrealDB.connect(url; ping_interval=0.0, wire=wire)
    println(stderr, "[get_test_client] use!..."); flush(stderr)
    SurrealDB.use!(client, TEST_NS, TEST_DB)
    println(stderr, "[get_test_client] signin!..."); flush(stderr)
    SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    println(stderr, "[get_test_client] ready"); flush(stderr)
    return client
end

function clean_table!(client, table::String)
    try
        SurrealDB.query(client, "DELETE FROM $table")
    catch e
        @warn "Failed to clean table $table: $e"
    end
end
