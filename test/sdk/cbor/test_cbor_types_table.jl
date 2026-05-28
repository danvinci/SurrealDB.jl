# L3 — TAG_TABLE (7) handler tests.
# Wire spec: Tag(7, text). Ref convert.rs:188, 413-415.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, Table, TAG_TABLE
using Test

@testset "L3 Table (tag 7)" begin

    @testset "Encode / decode" begin
        # Tag(7) head = 0xc7; text head = 0x66 (len 6); "stream" bytes
        @test encode(Table("stream")) ==
            UInt8[0xc7, 0x66, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d]
        @test decode(UInt8[0xc7, 0x66, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d]) ==
            Table("stream")
    end

    @testset "Round-trip" begin
        for name in ("a", "users", "long_table_name_v2", "ü-table")
            @test decode(encode(Table(name))) == Table(name)
        end
        @test decode(encode(Table(""))) == Table("")
    end

    @testset "Malformed payload errors" begin
        # Tag(7, Integer(42))
        @test_throws CBORError decode(UInt8[0xc7, 0x18, 0x2a])
        # Tag(7, Array([1, 2]))
        @test_throws CBORError decode(UInt8[0xc7, 0x82, 0x01, 0x02])
    end

    @testset "Equality + hash" begin
        @test Table("x") == Table("x")
        @test Table("x") != Table("y")
        @test hash(Table("x")) == hash(Table("x"))
        d = Dict(Table("a") => 1, Table("b") => 2)
        @test d[Table("a")] == 1
        @test d[Table("b")] == 2
    end
end
