# L3 — TAG_SET (56) handler tests.
# Wire spec: Tag(56, array). Ref convert.rs:353-358, 444-449.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, TAG_SET
using Test

@testset "L3 Set (tag 56)" begin

    @testset "Encode (sorted-by-encoded-bytes)" begin
        # Set([1, 2, 3]) → Tag(56, [1, 2, 3]) — integers sort naturally
        # 0xd8 0x38 0x83 0x01 0x02 0x03
        @test encode(Set([1, 2, 3])) ==
            UInt8[0xd8, 0x38, 0x83, 0x01, 0x02, 0x03]

        # Insertion-order-independent (sorted output)
        @test encode(Set([3, 1, 2])) ==
            UInt8[0xd8, 0x38, 0x83, 0x01, 0x02, 0x03]

        # Empty set
        @test encode(Set{Int}()) == UInt8[0xd8, 0x38, 0x80]

        # Set of strings — sorted lex
        @test encode(Set(["b", "a", "c"])) ==
            UInt8[0xd8, 0x38, 0x83, 0x61, 0x61, 0x61, 0x62, 0x61, 0x63]
    end

    @testset "Decode" begin
        @test decode(UInt8[0xd8, 0x38, 0x83, 0x01, 0x02, 0x03]) == Set([1, 2, 3])
        @test decode(UInt8[0xd8, 0x38, 0x80]) == Set{Any}()
    end

    @testset "Round-trip" begin
        for s in (Set{Int}(), Set([1]), Set([1, 2, 3]),
                  Set(["alpha", "beta", "gamma"]),
                  Set([true, false]))
            @test decode(encode(s)) == s
        end
    end

    @testset "Malformed payload errors" begin
        # Tag(56, Integer)
        @test_throws CBORError decode(UInt8[0xd8, 0x38, 0x18, 0x2a])
        # Tag(56, Text)
        @test_throws CBORError decode(UInt8[0xd8, 0x38, 0x61, 0x78])
    end
end
