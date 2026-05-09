# Shared test setup for SurrealDB.jl

using SurrealDB

# Auto-load libsurreal if SURREALDB_LIB is set or the dylib sits next to Project.toml
let lib = get(ENV, "SURREALDB_LIB", "")
    if isempty(lib)
        candidate = joinpath(@__DIR__, "..", "libsurrealdb_c.dylib")
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

function get_test_client(; url=TEST_URL)
    client = SurrealDB.connect(url)
    SurrealDB.use!(client, TEST_NS, TEST_DB)
    SurrealDB.signin!(client, SurrealDB.RootAuth("root", "root"))
    return client
end

function clean_table!(client, table::String)
    try
        SurrealDB.query(client, "DELETE FROM $table")
    catch e
        @warn "Failed to clean table $table: $e"
    end
end

function get_embedded_client(; url="mem://")
    client = SurrealDB.connect(url)
    SurrealDB.use!(client, TEST_NS, TEST_DB)
    return client
end
