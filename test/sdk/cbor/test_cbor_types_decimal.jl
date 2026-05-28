# L3 — TAG_STRING_DECIMAL (10) handler tests.
# Wire spec: Tag(10, text). Ref convert.rs:116-122 (decode), 375-377 (encode).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, SurrealDecimal, TAG_STRING_DECIMAL
using Test

@testset "L3 SurrealDecimal (tag 10)" begin

    @testset "Encode / decode" begin
        # Tag(10) head = 0xca; text head + "3.14"
        @test encode(SurrealDecimal("3.14")) ==
            UInt8[0xca, 0x64, 0x33, 0x2e, 0x31, 0x34]
        @test decode(UInt8[0xca, 0x64, 0x33, 0x2e, 0x31, 0x34]) ==
            SurrealDecimal("3.14")
    end

    @testset "Round-trip" begin
        for s in ("0", "1", "-1", "0.5", "3.14", "-2.71",
                  "123.456", "1000000.001", "-0.000001",
                  "999999999999999999.99999999")
            @test decode(encode(SurrealDecimal(s))) == SurrealDecimal(s)
        end
    end

    @testset "BigFloat conversion" begin
        @test BigFloat(SurrealDecimal("0.5")) == BigFloat("0.5")
        @test BigFloat(SurrealDecimal("3.14")) ≈ BigFloat("3.14")
        @test BigFloat(SurrealDecimal("-1.0")) == BigFloat(-1)
    end

    @testset "Equality + hash + Dict key" begin
        @test SurrealDecimal("1.5") == SurrealDecimal("1.5")
        @test SurrealDecimal("1.5") != SurrealDecimal("1.50")  # string-exact
        d = Dict(SurrealDecimal("1.5") => "one-and-a-half")
        @test d[SurrealDecimal("1.5")] == "one-and-a-half"
    end

    @testset "Malformed payload errors" begin
        # Tag(10, Integer(42))
        @test_throws CBORError decode(UInt8[0xca, 0x18, 0x2a])
        # Tag(10, Bytes([1, 2]))
        @test_throws CBORError decode(UInt8[0xca, 0x42, 0x01, 0x02])
    end
end
