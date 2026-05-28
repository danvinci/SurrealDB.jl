# L3 — TAG_NONE (6) handler tests.
#
# Wire spec (from convert.rs:104,369):
#   NONE = Tag(6, Null) = 2 bytes `0xC6 0xF6`
#   Julia: `missing`
#   Distinct from CBOR `Null` (1 byte `0xF6`) → Julia `nothing`.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, Tagged, CBORError, TAG_NONE
using Test

@testset "L3 NONE (tag 6)" begin

    @testset "Encode" begin
        @test encode(missing) == UInt8[0xc6, 0xf6]
    end

    @testset "Decode" begin
        @test decode(UInt8[0xc6, 0xf6]) === missing
    end

    @testset "NONE distinct from Null" begin
        # Wire-distinct: bare null is 1 byte, NONE is 2 bytes.
        @test encode(nothing) == UInt8[0xf6]
        @test encode(missing) == UInt8[0xc6, 0xf6]
        @test decode(UInt8[0xf6]) === nothing
        @test decode(UInt8[0xc6, 0xf6]) === missing
    end

    @testset "Round-trip" begin
        @test decode(encode(missing)) === missing
        @test decode(encode(nothing)) === nothing
    end

    @testset "Tag(6) with non-null payload errors" begin
        # Tag 6 wrapping anything other than null is malformed.
        # Byte sequence: Tag(6) + integer 42 = 0xc6 0x18 0x2a
        @test_throws CBORError decode(UInt8[0xc6, 0x18, 0x2a])
        # Tag(6) + text "x" = 0xc6 0x61 0x78
        @test_throws CBORError decode(UInt8[0xc6, 0x61, 0x78])
    end

    @testset "NONE inside collections" begin
        # Arrays + maps preserve missing through the registry lift.
        # `==` on values containing missing returns missing (three-valued
        # logic); use `isequal` for boolean true/false.
        @test isequal(decode(encode([1, missing, 3])), Any[1, missing, 3])
        @test isequal(decode(encode(Dict("a" => missing))), Dict{Any,Any}("a" => missing))
    end
end
