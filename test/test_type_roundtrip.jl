# Type round-trip coverage: every supported SurrealDB type writes-then-
# reads-equal through the SDK. Catches SerDes drift where Julia encodes a
# value the server can't decode (or vice versa).
#
# Scope: types reachable via the public API (Dict-of-Any payloads).
# Currently NOT covered: SurrealDB's Decimal, Duration, Geometry types
# (no Julia-side wrappers exposed yet — round-trip via raw SurrealQL only).
#
# Server-gated.

using SurrealDB
using Test
using Dates
using UUIDs

const RT_TABLE = "rt_type_test"

function _rt_client()
    db = SurrealDB.connect(TEST_URL; ns=TEST_NS, db=TEST_DB,
        auth=SurrealDB.RootAuth("root", "root"))
    try; SurrealDB.query(db, "REMOVE TABLE IF EXISTS $RT_TABLE"); catch; end
    SurrealDB.query(db, "DEFINE TABLE $RT_TABLE")
    return db
end

function _rt_close(db)
    try; SurrealDB.query(db, "REMOVE TABLE IF EXISTS $RT_TABLE"); catch; end
    SurrealDB.close!(db)
end

# Round-trip helper: create with a single value field, select back, return
# the field. Asserts the row was created and a single record came back.
function _roundtrip(db, id::String, value)
    rec = SurrealDB.RecordID(RT_TABLE, id)
    SurrealDB.create(db, rec, Dict("v" => value))
    got = SurrealDB.select(db, rec)
    row = got isa AbstractVector ? first(got) : got
    @test row isa AbstractDict
    return row["v"]
end

# SurrealDB v2 rejects strings containing NUL bytes with "Parse error" at the
# SurrealQL level (server-side limitation, fixed in v3). Detect once per
# testset to gate the NUL-byte assertion.
function _server_is_v2(db)
    try
        v = SurrealDB.version(db)
        ver = v isa NamedTuple ? v.version : string(v)
        return occursin(r"surrealdb-2\.", ver)
    catch
        return false
    end
end

@testset "scalar types" begin
    db = _rt_client()
    try
        @test _roundtrip(db, "int_pos", 42) == 42
        @test _roundtrip(db, "int_neg", -123456789) == -123456789
        @test _roundtrip(db, "int_zero", 0) == 0
        @test _roundtrip(db, "int_2pow53", 9_007_199_254_740_992) == 9_007_199_254_740_992
        # Above 2^53: JS clients lose precision here, JSON.jl + SurrealDB i64
        # preserve exactly. Locks in the Julia-side guarantee.
        @test _roundtrip(db, "int_2pow53_plus_1", 9_007_199_254_740_993) == 9_007_199_254_740_993
        @test _roundtrip(db, "int_i64_max", typemax(Int64)) == typemax(Int64)
        @test _roundtrip(db, "int_i64_min", typemin(Int64)) == typemin(Int64)

        @test _roundtrip(db, "float_pi", 3.14159) ≈ 3.14159
        @test _roundtrip(db, "float_neg", -2.71828) ≈ -2.71828
        @test _roundtrip(db, "float_zero", 0.0) == 0.0

        @test _roundtrip(db, "bool_t", true) === true
        @test _roundtrip(db, "bool_f", false) === false

        @test _roundtrip(db, "str_ascii", "hello world") == "hello world"
        @test _roundtrip(db, "str_unicode", "αβγ ✓ 中文 🦀") == "αβγ ✓ 中文 🦀"
        @test _roundtrip(db, "str_empty", "") == ""

        # NUL bytes — JSON encoders sometimes drop these silently. Current
        # v2 + v3 server builds both accept NUL through SurrealQL (older v2
        # builds rejected at the parser; see git history if that regresses).
        nul_str = "before\0after"
        @test _roundtrip(db, "str_nul", nul_str) == nul_str
    finally
        _rt_close(db)
    end
end

@testset "collection types" begin
    db = _rt_client()
    try
        # Arrays
        @test _roundtrip(db, "arr_int", [1, 2, 3]) == [1, 2, 3]
        @test _roundtrip(db, "arr_str", ["a", "b", "c"]) == ["a", "b", "c"]
        @test _roundtrip(db, "arr_empty", Any[]) == Any[]
        # Mixed arrays — JSON tolerates them, SurrealDB stores as ARRAY<ANY>.
        mixed = _roundtrip(db, "arr_mixed", Any[1, "two", 3.0, true])
        @test mixed == Any[1, "two", 3.0, true]

        # Nested objects
        nested = Dict("outer" => Dict("inner" => Dict("leaf" => 42)))
        result = _roundtrip(db, "obj_nested", nested)
        @test result["outer"]["inner"]["leaf"] == 42

        # Object-in-array
        oia = _roundtrip(db, "obj_in_arr", [Dict("k" => 1), Dict("k" => 2)])
        @test oia[1]["k"] == 1 && oia[2]["k"] == 2

        # Array-in-object
        aio = _roundtrip(db, "arr_in_obj", Dict("xs" => [10, 20, 30]))
        @test aio["xs"] == [10, 20, 30]
    finally
        _rt_close(db)
    end
end

@testset "RecordID round-trip" begin
    db = _rt_client()
    try
        # The `id` field of any record is itself a RecordID. Selecting it
        # back exercises the RecordID parse path.
        rec = SurrealDB.RecordID(RT_TABLE, "rid_check")
        SurrealDB.create(db, rec, Dict("v" => 1))
        got = SurrealDB.select(db, rec)
        row = got isa AbstractVector ? first(got) : got
        @test haskey(row, "id")
        # The id should be parseable back to a RecordID with matching parts.
        # Wire format may return it as a String "table:id" or a structured
        # RecordID; tolerate both.
        id = row["id"]
        if id isa SurrealDB.RecordID
            @test id.table == RT_TABLE
            @test string(id.id) == "rid_check"
        elseif id isa AbstractString
            parsed = SurrealDB.RecordID(String(id))
            @test parsed.table == RT_TABLE
        else
            @test false  # unexpected shape
        end

        # Embedding a RecordID as a field value (graph reference pattern).
        ref = SurrealDB.RecordID(RT_TABLE, "rid_check")
        SurrealDB.create(db, SurrealDB.RecordID(RT_TABLE, "with_ref"),
                         Dict("ref" => ref))
        got2 = SurrealDB.select(db, SurrealDB.RecordID(RT_TABLE, "with_ref"))
        row2 = got2 isa AbstractVector ? first(got2) : got2
        @test haskey(row2, "ref")
    finally
        _rt_close(db)
    end
end

@testset "datetime via raw SurrealQL" begin
    db = _rt_client()
    try
        # SurrealDB's datetime is a tagged type; the SDK doesn't expose a
        # Julia DateTime wrapper yet. Round-trip via SurrealQL literals so
        # the wire format gets exercised end-to-end.
        SurrealDB.query(db, """
            CREATE $RT_TABLE:dt_iso CONTENT {
                ts: <datetime>"2024-06-15T12:30:45Z"
            };
        """)
        got = SurrealDB.select(db, SurrealDB.RecordID(RT_TABLE, "dt_iso"))
        row = got isa AbstractVector ? first(got) : got
        @test haskey(row, "ts")
        # CBOR returns a typed `SurrealDateTime`; 1718454645s = 2024-06-15T12:30:45Z.
        ts = row["ts"]
        @test ts isa SurrealDateTime || (ts isa AbstractString && occursin(r"^2024-06-15", ts))
        if ts isa SurrealDateTime
            @test ts.seconds == 1718454645
        end
    finally
        _rt_close(db)
    end
end

@testset "uuid via raw SurrealQL" begin
    db = _rt_client()
    try
        # u"..." is SurrealQL's UUID literal syntax. Round-trip exercises
        # the UUID tagged-value path.
        SurrealDB.query(db, """
            CREATE $RT_TABLE:uuid_check CONTENT {
                u: u"550e8400-e29b-41d4-a716-446655440000"
            };
        """)
        got = SurrealDB.select(db, SurrealDB.RecordID(RT_TABLE, "uuid_check"))
        row = got isa AbstractVector ? first(got) : got
        @test haskey(row, "u")
        @test occursin("550e8400", string(row["u"]))
    finally
        _rt_close(db)
    end
end

@testset "deeply nested structure" begin
    db = _rt_client()
    try
        # 5 levels of nesting with mixed types at each level. Catches
        # encode/decode bugs that only fire at depth.
        nested = Dict(
            "level1" => Dict(
                "level2" => Dict(
                    "level3" => Dict(
                        "level4" => Dict(
                            "leaf_str" => "deep value",
                            "leaf_int" => 999,
                            "leaf_arr" => [1, 2, [3, [4, [5]]]],
                        ),
                        "sibling" => "level3 sibling",
                    ),
                ),
            ),
        )
        result = _roundtrip(db, "deep_nested", nested)
        @test result["level1"]["level2"]["level3"]["level4"]["leaf_str"] == "deep value"
        @test result["level1"]["level2"]["level3"]["level4"]["leaf_int"] == 999
        @test result["level1"]["level2"]["level3"]["level4"]["leaf_arr"][3][2][2][1] == 5
        @test result["level1"]["level2"]["level3"]["sibling"] == "level3 sibling"
    finally
        _rt_close(db)
    end
end
