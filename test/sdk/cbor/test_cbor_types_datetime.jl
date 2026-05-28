# L3 — DateTime tag handler tests.
# Wire specs:
#   Tag(12, [i64 seconds, u32 nanos])  — server canonical
#   Tag(0, text RFC 3339)               — decode-only
# Refs: convert.rs:68-101 (decode), 395-405 (encode).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, SurrealDateTime,
    TAG_CUSTOM_DATETIME, TAG_SPEC_DATETIME
using Dates
using Test

@testset "L3 SurrealDateTime (tags 0, 12)" begin

    @testset "Construction + invariants" begin
        d = SurrealDateTime(1_716_423_296, 123_456_789)
        @test d.seconds == 1_716_423_296
        @test d.nanos == 123_456_789

        # nanos must be in [0, 1_000_000_000)
        @test_throws ArgumentError SurrealDateTime(0, 1_000_000_000)
        @test_throws ArgumentError SurrealDateTime(0, -1)

        # Negative seconds OK (pre-epoch)
        @test SurrealDateTime(-1, 0).seconds == -1
    end

    @testset "Encode (tag 12 canonical)" begin
        # Epoch: SurrealDateTime(0, 0) → Tag(12, [0, 0])
        # 0xcc 0x82 0x00 0x00
        @test encode(SurrealDateTime(0, 0)) == UInt8[0xcc, 0x82, 0x00, 0x00]

        # SurrealDateTime(1, 0) → Tag(12, [1, 0]) → 0xcc 0x82 0x01 0x00
        @test encode(SurrealDateTime(1, 0)) == UInt8[0xcc, 0x82, 0x01, 0x00]
    end

    @testset "Decode tag 12 (array form)" begin
        @test decode(UInt8[0xcc, 0x82, 0x00, 0x00]) == SurrealDateTime(0, 0)
        @test decode(UInt8[0xcc, 0x82, 0x01, 0x00]) == SurrealDateTime(1, 0)
    end

    @testset "Decode tag 0 (ISO 8601 text, decode-only)" begin
        # "1970-01-01T00:00:00Z" → SurrealDateTime(0, 0)
        s = "1970-01-01T00:00:00Z"
        # Tag(0) head = 0xc0; text head = 0x74 (len 20); + 20 bytes
        bytes = vcat(UInt8[0xc0, 0x74], Vector{UInt8}(codeunits(s)))
        @test decode(bytes) == SurrealDateTime(0, 0)

        # With ns fractional + Z
        s = "2024-05-22T22:54:56.123456789Z"
        bytes = vcat(UInt8[0xc0, 0x78, UInt8(length(s))], Vector{UInt8}(codeunits(s)))
        decoded = decode(bytes)
        @test decoded.nanos == 123_456_789

        # With timezone offset (positive)
        s = "2024-05-22T22:54:56+02:00"
        bytes = vcat(UInt8[0xc0, 0x78, UInt8(length(s))], Vector{UInt8}(codeunits(s)))
        decoded = decode(bytes)
        # 22:54:56 +02:00 = 20:54:56 UTC; nanos = 0
        @test decoded.nanos == 0

        # With fractional shorter than 9 digits (pad-right with zeros)
        s = "2024-05-22T22:54:56.5Z"
        bytes = vcat(UInt8[0xc0, 0x78, UInt8(length(s))], Vector{UInt8}(codeunits(s)))
        decoded = decode(bytes)
        @test decoded.nanos == 500_000_000

        # Truncate fractional > 9 digits
        s = "2024-05-22T22:54:56.1234567890123Z"
        bytes = vcat(UInt8[0xc0, 0x78, UInt8(length(s))], Vector{UInt8}(codeunits(s)))
        decoded = decode(bytes)
        @test decoded.nanos == 123_456_789
    end

    @testset "Round-trip (tag 12)" begin
        for (s, ns) in ((0, 0), (1_716_423_296, 0), (1_716_423_296, 123_456_789),
                         (-86_400, 999_999_999))
            d = SurrealDateTime(s, ns)
            @test decode(encode(d)) == d
        end
    end

    @testset "Conversion ↔ Dates.DateTime" begin
        # Epoch
        @test Dates.DateTime(SurrealDateTime(0, 0)) == DateTime(1970, 1, 1)
        # Sub-second precision rounds to ms
        d = SurrealDateTime(0, 123_456_789)
        dt = Dates.DateTime(d)
        @test dt == DateTime(1970, 1, 1, 0, 0, 0, 123)  # 123 ms

        # Round-trip Julia DateTime → SurrealDateTime preserves ms-precision
        jd = DateTime(2024, 5, 22, 22, 54, 56, 123)
        sd = SurrealDateTime(jd)
        @test Dates.DateTime(sd) == jd
        @test sd.nanos == 123_000_000   # ms → ns
    end

    @testset "Malformed payloads error" begin
        # Tag(12, Integer(42)) — wrong payload type
        @test_throws CBORError decode(UInt8[0xcc, 0x18, 0x2a])

        # Tag(12, [secs]) — array length 1
        @test_throws CBORError decode(UInt8[0xcc, 0x81, 0x00])

        # Tag(12, ["seconds", 0]) — non-integer seconds
        bytes = vcat(UInt8[0xcc, 0x82, 0x67],
                     Vector{UInt8}(codeunits("seconds")), UInt8[0x00])
        @test_throws CBORError decode(bytes)

        # Tag(0) with malformed text
        s = "not-a-date"
        bytes = vcat(UInt8[0xc0, 0x6a], Vector{UInt8}(codeunits(s)))
        @test_throws CBORError decode(bytes)
    end
end
