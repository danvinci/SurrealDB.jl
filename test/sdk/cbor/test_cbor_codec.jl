# L2 native codec tests.
#
# Three layers:
#   1. RFC 8949 §A worked-example byte forms — every encode(value) must
#      produce the exact bytes the RFC specifies.
#   2. Self round-trip — decode(encode(x)) == x over a generated corpus.
#   3. Indefinite-length decode tolerance — peer SDKs may emit; we read.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, Tagged, Undefined, undefined, CBORError
using Test

# Convenience
_enc(v) = encode(v)
_dec(b::Vector{UInt8}) = decode(b)
_roundtrip(v) = decode(encode(v))

@testset "L2 — RFC 8949 §A byte forms" begin

    @testset "Integers" begin
        # Unsigned
        @test _enc(0)   == UInt8[0x00]
        @test _enc(1)   == UInt8[0x01]
        @test _enc(10)  == UInt8[0x0a]
        @test _enc(23)  == UInt8[0x17]
        @test _enc(24)  == UInt8[0x18, 0x18]
        @test _enc(25)  == UInt8[0x18, 0x19]
        @test _enc(100) == UInt8[0x18, 0x64]
        @test _enc(1000) == UInt8[0x19, 0x03, 0xe8]
        @test _enc(1000000) == UInt8[0x1a, 0x00, 0x0f, 0x42, 0x40]
        @test _enc(1000000000000) == UInt8[0x1b, 0x00, 0x00, 0x00, 0xe8, 0xd4, 0xa5, 0x10, 0x00]

        # Negative
        @test _enc(-1)   == UInt8[0x20]
        @test _enc(-10)  == UInt8[0x29]
        @test _enc(-100) == UInt8[0x38, 0x63]
        @test _enc(-1000) == UInt8[0x39, 0x03, 0xe7]

        # i64 boundaries
        @test _enc(typemax(Int64)) == UInt8[0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        @test _enc(typemin(Int64)) == UInt8[0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

        # u64 max
        @test _enc(typemax(UInt64)) == UInt8[0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    end

    @testset "Floats" begin
        # Float64 (canonical for our encoder)
        @test _enc(1.1) == UInt8[0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a]
        @test _enc(1.0e+300) == UInt8[0xfb, 0x7e, 0x37, 0xe4, 0x3c, 0x88, 0x00, 0x75, 0x9c]
        @test _enc(-4.1)     == UInt8[0xfb, 0xc0, 0x10, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66]

        # Float32 round-trip via explicit emit
        @test _enc(Float32(100000.0)) == UInt8[0xfa, 0x47, 0xc3, 0x50, 0x00]
        @test _enc(Float32(3.4028235e38)) == UInt8[0xfa, 0x7f, 0x7f, 0xff, 0xff]

        # Float16 / canonical-shrink (RFC §4.2.2)
        @test _enc(Float16(0.0))  == UInt8[0xf9, 0x00, 0x00]
        @test _enc(Float16(-0.0)) == UInt8[0xf9, 0x80, 0x00]
        @test _enc(Float16(1.0))  == UInt8[0xf9, 0x3c, 0x00]
        @test _enc(Float16(Inf))  == UInt8[0xf9, 0x7c, 0x00]
        # Float64 ±Inf / NaN canonical-shrink to Float16
        @test _enc(Inf64)  == UInt8[0xf9, 0x7c, 0x00]
        @test _enc(-Inf64) == UInt8[0xf9, 0xfc, 0x00]
        @test _enc(NaN64)  == UInt8[0xf9, 0x7e, 0x00]   # canonical NaN pattern
    end

    @testset "Simple values / sentinels" begin
        @test _enc(false)    == UInt8[0xf4]
        @test _enc(true)     == UInt8[0xf5]
        @test _enc(nothing)  == UInt8[0xf6]
        @test _enc(undefined) == UInt8[0xf7]
    end

    @testset "Text strings" begin
        @test _enc("")     == UInt8[0x60]
        @test _enc("a")    == UInt8[0x61, 0x61]
        @test _enc("IETF") == UInt8[0x64, 0x49, 0x45, 0x54, 0x46]
        @test _enc("\"\\") == UInt8[0x62, 0x22, 0x5c]
        # UTF-8 multibyte
        @test _enc("ü") == UInt8[0x62, 0xc3, 0xbc]   # ü (2 bytes)
        @test _enc("水") == UInt8[0x63, 0xe6, 0xb0, 0xb4]  # 水 (3 bytes)
    end

    @testset "Byte strings" begin
        @test _enc(UInt8[]) == UInt8[0x40]
        @test _enc(UInt8[0x01, 0x02, 0x03, 0x04]) == UInt8[0x44, 0x01, 0x02, 0x03, 0x04]
    end

    @testset "Arrays" begin
        @test _enc(Any[]) == UInt8[0x80]
        @test _enc([1, 2, 3]) == UInt8[0x83, 0x01, 0x02, 0x03]
        @test _enc([1, [2, 3], [4, 5]]) ==
            UInt8[0x83, 0x01, 0x82, 0x02, 0x03, 0x82, 0x04, 0x05]
        # Length-25 array → ai=24 form
        @test _enc(collect(1:25)) ==
            UInt8[0x98, 0x19,
                  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
                  0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
                  0x15, 0x16, 0x17, 0x18, 0x18, 0x18, 0x19]
    end

    @testset "Maps — canonical key sort" begin
        @test _enc(Dict{Any,Any}()) == UInt8[0xa0]

        # {1: 2, 3: 4}
        @test _enc(Dict(1 => 2, 3 => 4)) == UInt8[0xa2, 0x01, 0x02, 0x03, 0x04]

        # {"a": 1, "b": [2, 3]} — RFC §A canonical example
        @test _enc(Dict("a" => 1, "b" => [2, 3])) ==
            UInt8[0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03]

        # Out-of-order input → canonical output (sort by encoded key bytes)
        @test _enc(Dict("b" => 2, "a" => 1)) ==
            UInt8[0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02]

        # Server-convention sort (raw String bytes, not encoded form):
        # "aa" (0x61, 0x61) < "b" (0x62) → "aa" emits first. Differs from
        # strict-RFC encoded-form sort; see codec.jl encode(::AbstractDict)
        # docstring for rationale.
        @test _enc(Dict("aa" => 2, "b" => 1)) ==
            UInt8[0xa2, 0x62, 0x61, 0x61, 0x02, 0x61, 0x62, 0x01]
    end

    @testset "Tags (passthrough, unregistered)" begin
        # Use unregistered tag numbers — L3-registered tags (0, 6, 8, 37,
        # etc.) round-trip via their typed handler, not as Tagged.
        @test _enc(Tagged(UInt64(100), "x")) ==
            vcat(UInt8[0xd8, 0x64], _enc("x"))
        @test _enc(Tagged(UInt64(200), UInt8[1,2,3])) ==
            vcat(UInt8[0xd8, 0xc8], _enc(UInt8[1,2,3]))
    end
end

@testset "L2 — round-trip identity" begin

    @testset "Scalars" begin
        for v in (0, 1, 23, 24, 100, 1000, typemax(Int64), typemax(UInt64))
            @test _roundtrip(v) == v
        end
        for v in (-1, -24, -25, -100, typemin(Int64))
            @test _roundtrip(v) == v
        end
        for v in (0.0, 1.1, -4.1, 1.0e+300, -Inf64)
            @test _roundtrip(v) === v
        end
        @test isnan(_roundtrip(NaN64))
        @test _roundtrip(true)  === true
        @test _roundtrip(false) === false
        @test _roundtrip(nothing) === nothing
        @test _roundtrip(undefined) === undefined
    end

    @testset "Strings + bytes" begin
        for v in ("", "a", "hello", "ü", "水", "café", "\"\\")
            @test _roundtrip(v) == v
        end
        @test _roundtrip(UInt8[]) == UInt8[]
        @test _roundtrip(UInt8[0x01, 0x02, 0xff]) == UInt8[0x01, 0x02, 0xff]
    end

    @testset "Collections" begin
        # Arrays
        @test _roundtrip(Any[]) == Any[]
        @test _roundtrip([1, 2, 3]) == [1, 2, 3]
        @test _roundtrip([1, "two", 3.0, true, nothing]) == Any[1, "two", 3.0, true, nothing]
        # Nested
        @test _roundtrip([[1, 2], [3, 4]]) == [[1, 2], [3, 4]]

        # Maps — decode produces Dict{Any,Any} regardless of input type
        m = Dict{Any,Any}("a" => 1, "b" => [2, 3])
        @test _roundtrip(m) == m
        # Empty
        @test _roundtrip(Dict{Any,Any}()) == Dict{Any,Any}()
    end

    @testset "Tagged passthrough (unregistered)" begin
        # Unregistered tag numbers round-trip as Tagged. Registered tags
        # (0, 6, 8, 37, ...) lift to typed values; see test_cbor_types_*.jl.
        @test _roundtrip(Tagged(UInt64(100), "x"))  == Tagged(UInt64(100), "x")
        @test _roundtrip(Tagged(UInt64(101), UInt8[1,2,3])) == Tagged(UInt64(101), UInt8[1,2,3])
        @test _roundtrip(Tagged(UInt64(200), ["a", "b"])) ==
            Tagged(UInt64(200), Any["a", "b"])
    end
end

@testset "L2 — indefinite-length decode (peer-SDK tolerance)" begin
    # Indefinite text: 0x7f <chunks> 0xff
    # "stream" = "stre" + "aming"
    @test _dec(UInt8[0x7f, 0x64, 0x73, 0x74, 0x72, 0x65, 0x65, 0x61, 0x6d, 0x69, 0x6e, 0x67, 0xff]) ==
        "streaming"

    # Indefinite bytes
    @test _dec(UInt8[0x5f, 0x42, 0x01, 0x02, 0x43, 0x03, 0x04, 0x05, 0xff]) ==
        UInt8[0x01, 0x02, 0x03, 0x04, 0x05]

    # Indefinite array: [1, [2, 3], [4, 5]]
    @test _dec(UInt8[0x9f, 0x01, 0x82, 0x02, 0x03, 0x82, 0x04, 0x05, 0xff]) ==
        Any[1, Any[2, 3], Any[4, 5]]

    # Indefinite map: {"a": 1, "b": [2, 3]}
    @test _dec(UInt8[0xbf, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03, 0xff]) ==
        Dict{Any,Any}("a" => 1, "b" => Any[2, 3])

    # Nested: array containing indefinite-array
    @test _dec(UInt8[0x82, 0x01, 0x9f, 0x02, 0x03, 0xff]) ==
        Any[1, Any[2, 3]]
end

@testset "L2 — error surface" begin
    # Trailing bytes
    @test_throws CBORError decode(UInt8[0x01, 0x02])

    # Reserved AI on a non-trivial path
    @test_throws CBORError decode(UInt8[0x1c])  # major 0 + ai 28

    # Unsupported simple ai (e.g. simple value with 1-byte form — niche)
    @test_throws CBORError decode(UInt8[0xf8, 0xff])  # ai 24 + payload byte
end
