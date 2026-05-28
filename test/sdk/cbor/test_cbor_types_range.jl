# L3 — Range + Bound markers (tags 49, 50, 51).
# Wire specs:
#   Tag(49, [start_bound, end_bound])
#   Tag(50, value) — BoundIncluded
#   Tag(51, value) — BoundExcluded
#   Null = Unbounded
# Refs: convert.rs:193, 511-542, 514-518.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError,
    SurrealRange, BoundIncluded, BoundExcluded,
    TAG_RANGE, TAG_BOUND_INCLUDED, TAG_BOUND_EXCLUDED
using Test

@testset "L3 SurrealRange (tags 49, 50, 51)" begin

    @testset "Construction validates bounds" begin
        @test SurrealRange(BoundIncluded(1), BoundExcluded(10)).start ==
            BoundIncluded(1)
        @test SurrealRange(nothing, BoundIncluded(5)).start === nothing

        @test_throws ArgumentError SurrealRange("not-a-bound", BoundIncluded(1))
        @test_throws ArgumentError SurrealRange(BoundIncluded(1), 42)
    end

    @testset "Encode" begin
        # [1, 10) = Tag(49, [Tag(50, 1), Tag(51, 10)])
        # 0xd8 0x31 0x82 0xd8 0x32 0x01 0xd8 0x33 0x0a
        @test encode(SurrealRange(BoundIncluded(1), BoundExcluded(10))) ==
            UInt8[0xd8, 0x31, 0x82, 0xd8, 0x32, 0x01, 0xd8, 0x33, 0x0a]

        # [1, ∞) = Tag(49, [Tag(50, 1), Null])
        @test encode(SurrealRange(BoundIncluded(1), nothing)) ==
            UInt8[0xd8, 0x31, 0x82, 0xd8, 0x32, 0x01, 0xf6]

        # (-∞, 0) = Tag(49, [Null, Tag(51, 0)])
        @test encode(SurrealRange(nothing, BoundExcluded(0))) ==
            UInt8[0xd8, 0x31, 0x82, 0xf6, 0xd8, 0x33, 0x00]

        # Fully unbounded — degenerate but valid
        @test encode(SurrealRange(nothing, nothing)) ==
            UInt8[0xd8, 0x31, 0x82, 0xf6, 0xf6]
    end

    @testset "Decode" begin
        @test decode(UInt8[0xd8, 0x31, 0x82, 0xd8, 0x32, 0x01, 0xd8, 0x33, 0x0a]) ==
            SurrealRange(BoundIncluded(1), BoundExcluded(10))

        @test decode(UInt8[0xd8, 0x31, 0x82, 0xd8, 0x32, 0x01, 0xf6]) ==
            SurrealRange(BoundIncluded(1), nothing)

        # Standalone bound markers lift to BoundIncluded/Excluded.
        @test decode(UInt8[0xd8, 0x32, 0x01]) == BoundIncluded(1)
        @test decode(UInt8[0xd8, 0x33, 0x01]) == BoundExcluded(1)
    end

    @testset "Round-trip" begin
        for r in (SurrealRange(BoundIncluded(0), BoundExcluded(100)),
                  SurrealRange(BoundIncluded("alpha"), BoundIncluded("omega")),
                  SurrealRange(nothing, BoundExcluded(0)),
                  SurrealRange(BoundIncluded(0), nothing),
                  SurrealRange(nothing, nothing))
            @test decode(encode(r)) == r
        end
    end

    @testset "Range-of-range (recursive)" begin
        # Range whose bounds are themselves ranges. Legal per spec
        # because bound payloads recurse through L2.
        inner = SurrealRange(BoundIncluded(0), BoundExcluded(10))
        outer = SurrealRange(BoundIncluded(inner), BoundExcluded(inner))
        @test decode(encode(outer)) == outer
    end

    @testset "Malformed payloads error" begin
        # Tag(49, Integer)
        @test_throws CBORError decode(UInt8[0xd8, 0x31, 0x18, 0x2a])
        # Tag(49, [a, b, c]) — too many elements
        @test_throws CBORError decode(UInt8[0xd8, 0x31, 0x83, 0xf6, 0xf6, 0xf6])
        # Tag(49, [Integer, Null]) — bound not a Tag(50/51) or null
        @test_throws CBORError decode(UInt8[0xd8, 0x31, 0x82, 0x01, 0xf6])
    end
end
