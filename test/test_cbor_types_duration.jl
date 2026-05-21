# L3 — Duration tag handler tests.
# Wire specs:
#   Tag(14, [] | [secs] | [secs, nanos])  — server canonical (compact)
#   Tag(13, text "1h30m")                  — decode-only (SurrealQL form)
# Refs: convert.rs:124-155 (decode), 380-393 (encode).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, SurrealDuration,
    TAG_CUSTOM_DURATION, TAG_STRING_DURATION
using Test

# Helper: build a Tag(13, text) byte sequence for ISO-form duration tests.
# Text head: len ≤ 23 → 0x60+len; 24 ≤ len ≤ 255 → 0x78 + 1 byte.
function _decode_iso(s::AbstractString)
    head = if ncodeunits(s) <= 23
        UInt8[0xcd, 0x60 + UInt8(ncodeunits(s))]
    else
        UInt8[0xcd, 0x78, UInt8(ncodeunits(s))]
    end
    return decode(vcat(head, Vector{UInt8}(codeunits(s))))
end

@testset "L3 SurrealDuration (tags 13, 14)" begin

    @testset "Construction + invariants" begin
        @test SurrealDuration(0, 0).seconds == 0
        @test SurrealDuration(3600, 500_000_000).nanos == 500_000_000

        @test_throws ArgumentError SurrealDuration(-1, 0)
        @test_throws ArgumentError SurrealDuration(0, 1_000_000_000)
    end

    @testset "Encode (server-canonical compact)" begin
        # (0, 0) → Tag(14, []) = 0xce 0x80
        @test encode(SurrealDuration(0, 0)) == UInt8[0xce, 0x80]

        # (1, 0) → Tag(14, [1]) = 0xce 0x81 0x01
        @test encode(SurrealDuration(1, 0)) == UInt8[0xce, 0x81, 0x01]

        # (3600, 0) → Tag(14, [3600]) = 0xce 0x81 0x19 0x0e 0x10
        @test encode(SurrealDuration(3600, 0)) ==
            UInt8[0xce, 0x81, 0x19, 0x0e, 0x10]

        # (1, 500_000_000) → Tag(14, [1, 500_000_000])
        # 500_000_000 = 0x1DCD6500, 4-byte uint head
        @test encode(SurrealDuration(1, 500_000_000)) ==
            UInt8[0xce, 0x82, 0x01, 0x1a, 0x1d, 0xcd, 0x65, 0x00]
    end

    @testset "Decode tag 14 (compact array)" begin
        @test decode(UInt8[0xce, 0x80]) == SurrealDuration(0, 0)
        @test decode(UInt8[0xce, 0x81, 0x01]) == SurrealDuration(1, 0)
        @test decode(UInt8[0xce, 0x82, 0x01, 0x1a, 0x1d, 0xcd, 0x65, 0x00]) ==
            SurrealDuration(1, 500_000_000)
    end

    @testset "Decode tag 13 (SurrealQL text, decode-only)" begin
        @test _decode_iso("1s")   == SurrealDuration(1, 0)
        @test _decode_iso("1m")   == SurrealDuration(60, 0)
        @test _decode_iso("1h")   == SurrealDuration(3600, 0)
        @test _decode_iso("1d")   == SurrealDuration(86_400, 0)
        @test _decode_iso("1w")   == SurrealDuration(7 * 86_400, 0)

        # Compound
        @test _decode_iso("1h30m") == SurrealDuration(3600 + 30*60, 0)
        @test _decode_iso("1h30m45s") == SurrealDuration(3600 + 30*60 + 45, 0)

        # Sub-second
        @test _decode_iso("500ms") == SurrealDuration(0, 500_000_000)
        @test _decode_iso("1ms500us") == SurrealDuration(0, 1_500_000)
        @test _decode_iso("1s500ms") == SurrealDuration(1, 500_000_000)

        # Microsecond variants
        @test _decode_iso("1us")  == SurrealDuration(0, 1_000)
        @test _decode_iso("1µs")  == SurrealDuration(0, 1_000)

        # Nanosecond
        @test _decode_iso("999ns") == SurrealDuration(0, 999)
    end

    @testset "Round-trip" begin
        for (s, ns) in ((0, 0), (1, 0), (3600, 0), (0, 500_000_000),
                         (86_400, 999_999_999))
            d = SurrealDuration(s, ns)
            @test decode(encode(d)) == d
        end
    end

    @testset "Malformed payloads error" begin
        # Tag(14, Integer) — wrong type
        @test_throws CBORError decode(UInt8[0xce, 0x18, 0x2a])

        # Tag(14, [a, b, c]) — too many elements
        @test_throws CBORError decode(UInt8[0xce, 0x83, 0x01, 0x02, 0x03])

        # Tag(14, ["s", 0]) — non-integer seconds
        bytes = vcat(UInt8[0xce, 0x82, 0x61], Vector{UInt8}(codeunits("s")), UInt8[0x00])
        @test_throws CBORError decode(bytes)

        # Tag(13) with unparseable text
        bytes = vcat(UInt8[0xcd, 0x67], Vector{UInt8}(codeunits("hello!!")))
        @test_throws CBORError decode(bytes)

        # Tag(13) with calendar unit 'y' (not supported by our parser)
        bytes = vcat(UInt8[0xcd, 0x62], Vector{UInt8}(codeunits("1y")))
        @test_throws CBORError decode(bytes)
    end
end
