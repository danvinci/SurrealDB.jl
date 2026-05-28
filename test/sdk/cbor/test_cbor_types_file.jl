# L3 — TAG_FILE (55) handler tests.
# Wire spec: Tag(55, [bucket_text, key_text]). Ref convert.rs:337-352, 437-443.

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, SurrealFile, TAG_FILE
using Test

@testset "L3 SurrealFile (tag 55)" begin

    @testset "Encode / decode" begin
        f = SurrealFile("avatars", "user_42.png")
        # Tag(55) head = 0xd8 0x37; array head len=2 = 0x82
        bytes = encode(f)
        @test bytes[1:3] == UInt8[0xd8, 0x37, 0x82]
        @test decode(bytes) == f
    end

    @testset "Round-trip" begin
        for (b, k) in (("a", "b"), ("bucket", "path/to/key"),
                       ("", "empty-bucket-ok"), ("ü-bucket", "ñame"))
            @test decode(encode(SurrealFile(b, k))) == SurrealFile(b, k)
        end
    end

    @testset "Malformed payload errors" begin
        # Tag(55, Integer)
        @test_throws CBORError decode(UInt8[0xd8, 0x37, 0x18, 0x2a])
        # Tag(55, [a]) — 1 element
        @test_throws CBORError decode(UInt8[0xd8, 0x37, 0x81, 0x61, 0x78])
        # Tag(55, [a, b, c]) — 3 elements
        @test_throws CBORError decode(UInt8[0xd8, 0x37, 0x83, 0x61, 0x78, 0x61, 0x79, 0x61, 0x7a])
        # Tag(55, [Integer(1), "x"]) — bucket not string
        @test_throws CBORError decode(UInt8[0xd8, 0x37, 0x82, 0x01, 0x61, 0x78])
    end

    @testset "Equality + Dict key" begin
        @test SurrealFile("a", "b") == SurrealFile("a", "b")
        @test SurrealFile("a", "b") != SurrealFile("a", "c")
        d = Dict(SurrealFile("u", "1") => "alice")
        @test d[SurrealFile("u", "1")] == "alice"
    end
end
