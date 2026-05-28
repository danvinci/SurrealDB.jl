using Dates, UUIDs

@testset "SR_NONE" begin
    sv = SurrealDB.julia_to_surreal_value(nothing)
    @test sv.kind == SurrealDB.SR_NONE
    @test SurrealDB.surreal_value_to_julia(sv) === nothing
end

@testset "SR_NULL" begin
    sv = SurrealDB.julia_to_surreal_value(missing)
    @test sv.kind == SurrealDB.SR_NULL
    @test SurrealDB.surreal_value_to_julia(sv) === missing
end

@testset "SR_BOOL" begin
    for val in (true, false)
        sv = SurrealDB.julia_to_surreal_value(val)
        @test sv.kind == SurrealDB.SR_BOOL
        @test SurrealDB.surreal_value_to_julia(sv) === val
    end
end

@testset "SR_INT" begin
    for val in (0, 1, -1, typemax(Int64), typemin(Int64))
        sv = SurrealDB.julia_to_surreal_value(val)
        @test sv.kind == SurrealDB.SR_INT
        @test SurrealDB.surreal_value_to_julia(sv) === Int64(val)
    end
    # Int32 coerced to Int64
    sv32 = SurrealDB.julia_to_surreal_value(Int32(42))
    @test sv32.kind == SurrealDB.SR_INT
    @test SurrealDB.surreal_value_to_julia(sv32) === Int64(42)
end

@testset "SR_FLOAT" begin
    for val in (0.0, 3.14, -2.718, Inf, -Inf)
        sv = SurrealDB.julia_to_surreal_value(val)
        @test sv.kind == SurrealDB.SR_FLOAT
        @test SurrealDB.surreal_value_to_julia(sv) === Float64(val)
    end
end

@testset "SR_DECIMAL" begin
    # SR_DECIMAL is produced by the C layer; construct directly to test surreal_value_to_julia
    sv = SurrealDB.SurrealValue(SurrealDB.SR_DECIMAL, "3.14159265358979323846")
    @test sv.kind == SurrealDB.SR_DECIMAL
    @test SurrealDB.surreal_value_to_julia(sv) == "3.14159265358979323846"
end

@testset "SR_STRING" begin
    for val in ("", "hello", "unicode: αβγδ ✓ 🎸", "tab\there", "newline\nhere")
        sv = SurrealDB.julia_to_surreal_value(val)
        @test sv.kind == SurrealDB.SR_STRING
        @test SurrealDB.surreal_value_to_julia(sv) == val
    end
end

@testset "SR_DATETIME" begin
    dt = DateTime(2024, 3, 15, 10, 30, 0)
    sv = SurrealDB.julia_to_surreal_value(dt)
    @test sv.kind == SurrealDB.SR_DATETIME
    @test SurrealDB.surreal_value_to_julia(sv) == dt
end

@testset "SR_DURATION" begin
    # SR_DURATION comes from the C layer; construct directly
    sv = SurrealDB.SurrealValue(SurrealDB.SR_DURATION, "1h30m")
    @test sv.kind == SurrealDB.SR_DURATION
    @test SurrealDB.surreal_value_to_julia(sv) == "1h30m"
end

@testset "SR_UUID" begin
    id = UUIDs.uuid4()
    sv = SurrealDB.julia_to_surreal_value(id)
    @test sv.kind == SurrealDB.SR_UUID
    @test SurrealDB.surreal_value_to_julia(sv) == id
end

@testset "SR_ARRAY" begin
    # Empty array
    sv_empty = SurrealDB.julia_to_surreal_value(Any[])
    @test sv_empty.kind == SurrealDB.SR_ARRAY
    @test SurrealDB.surreal_value_to_julia(sv_empty) == Any[]

    # Homogeneous ints
    sv_ints = SurrealDB.julia_to_surreal_value([1, 2, 3])
    @test sv_ints.kind == SurrealDB.SR_ARRAY
    @test SurrealDB.surreal_value_to_julia(sv_ints) == Any[1, 2, 3]

    # Mixed types
    mixed = Any[1, "two", true, nothing, 3.14]
    sv_mixed = SurrealDB.julia_to_surreal_value(mixed)
    @test sv_mixed.kind == SurrealDB.SR_ARRAY
    result = SurrealDB.surreal_value_to_julia(sv_mixed)
    @test result[1] == 1
    @test result[2] == "two"
    @test result[3] === true
    @test result[4] === nothing
end

@testset "SR_OBJECT" begin
    # Empty dict
    sv_empty = SurrealDB.julia_to_surreal_value(Dict{String, Any}())
    @test sv_empty.kind == SurrealDB.SR_OBJECT
    @test isempty(SurrealDB.surreal_value_to_julia(sv_empty))

    # Flat dict
    d = Dict{String, Any}("name" => "Alice", "value" => 42)
    sv = SurrealDB.julia_to_surreal_value(d)
    @test sv.kind == SurrealDB.SR_OBJECT
    result = SurrealDB.surreal_value_to_julia(sv)
    @test result["name"] == "Alice"
    @test result["value"] == 42

    # Deeply nested (3 levels)
    deep = Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("c" => 99)))
    sv_deep = SurrealDB.julia_to_surreal_value(deep)
    @test sv_deep.kind == SurrealDB.SR_OBJECT
    r = SurrealDB.surreal_value_to_julia(sv_deep)
    @test r["a"]["b"]["c"] == 99
end

@testset "SR_BYTES" begin
    for val in (UInt8[], UInt8[0x00, 0xff, 0x42])
        sv = SurrealDB.julia_to_surreal_value(val)
        @test sv.kind == SurrealDB.SR_BYTES
        @test SurrealDB.surreal_value_to_julia(sv) == val
    end
end

@testset "SR_THING" begin
    rid = SurrealDB.RecordID("user", "alice")
    sv = SurrealDB.julia_to_surreal_value(rid)
    @test sv.kind == SurrealDB.SR_THING
    result = SurrealDB.surreal_value_to_julia(sv)
    @test result isa SurrealDB.RecordID
    @test result.table == "user"
    @test result.id == "alice"
end

@testset "julia_to_c_value: tag mapping" begin
    @test SurrealDB.julia_to_c_value(nothing).tag    == SurrealDB.C_VALUE_NONE
    @test SurrealDB.julia_to_c_value(missing).tag    == SurrealDB.C_VALUE_NULL
    @test SurrealDB.julia_to_c_value(true).tag       == SurrealDB.C_VALUE_BOOL
    @test SurrealDB.julia_to_c_value(42).tag         == SurrealDB.C_VALUE_NUMBER
    @test SurrealDB.julia_to_c_value(3.14).tag       == SurrealDB.C_VALUE_NUMBER
    @test SurrealDB.julia_to_c_value("hello").tag    == SurrealDB.C_VALUE_STRAND
    @test SurrealDB.julia_to_c_value(Any[]).tag      == SurrealDB.C_VALUE_ARRAY
    @test SurrealDB.julia_to_c_value(Dict{String,Any}()).tag == SurrealDB.C_VALUE_OBJECT
    @test SurrealDB.julia_to_c_value(UInt8[0x01]).tag == SurrealDB.C_VALUE_BYTES
    @test SurrealDB.julia_to_c_value(SurrealDB.RecordID("t", "1")).tag == SurrealDB.C_VALUE_THING
    @test SurrealDB.julia_to_c_value(DateTime(2024,1,1)).tag == SurrealDB.C_VALUE_DATETIME
end

@testset "c_value_to_julia: no-pointer variants" begin
    @test SurrealDB.c_value_to_julia(SurrealDB.C_VALUE_NONE, C_NULL) === nothing
    @test SurrealDB.c_value_to_julia(SurrealDB.C_VALUE_NULL, C_NULL) === missing
end

@testset "c_value_to_julia: pointer variants throw EmbeddedFFIError" begin
    for tag in (SurrealDB.C_VALUE_BOOL, SurrealDB.C_VALUE_NUMBER,
                SurrealDB.C_VALUE_STRAND, SurrealDB.C_VALUE_ARRAY,
                SurrealDB.C_VALUE_OBJECT, SurrealDB.C_VALUE_BYTES,
                SurrealDB.C_VALUE_THING)
        @test_throws SurrealDB.EmbeddedFFIError SurrealDB.c_value_to_julia(tag, C_NULL)
    end
end
