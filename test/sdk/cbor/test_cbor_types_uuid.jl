# L3 — UUID tag handler tests.
#
# Wire spec:
#   TAG_SPEC_UUID  (37) = Tag(37, bytes[16])  — server canonical
#   TAG_STRING_UUID (9) = Tag(9, text)        — decode-only (peer SDKs)
# Refs: convert.rs:106-114 (decode), 407-409 (encode).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, CBORError, RecordID,
    TAG_SPEC_UUID, TAG_STRING_UUID
using UUIDs
using Test

# UUID with all-zero bytes
const NIL_UUID = UUID(UInt128(0))
# Example UUID matching the Rust gen fixture
const EX_UUID  = UUID("12345678-1234-5678-9012-345678901234")
const EX_BYTES = UInt8[
    0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
    0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34,
]

@testset "L3 UUID (tags 37, 9)" begin

    @testset "Encode (tag 37, bytes)" begin
        # Tag(37) head = 0xd8 0x25; bytes head len=16 = 0x50; then 16 bytes
        @test encode(NIL_UUID) == vcat(UInt8[0xd8, 0x25, 0x50], zeros(UInt8, 16))
        @test encode(EX_UUID)  == vcat(UInt8[0xd8, 0x25, 0x50], EX_BYTES)
    end

    @testset "Decode tag 37 (bytes form)" begin
        @test decode(vcat(UInt8[0xd8, 0x25, 0x50], zeros(UInt8, 16))) == NIL_UUID
        @test decode(vcat(UInt8[0xd8, 0x25, 0x50], EX_BYTES)) == EX_UUID
    end

    @testset "Decode tag 9 (text form, decode-only)" begin
        # Tag(9, "12345678-1234-5678-9012-345678901234")
        # Tag(9) head = 0xc9; text head = 0x78 0x24 (1-byte form, len=36)
        s = "12345678-1234-5678-9012-345678901234"
        @test length(s) == 36
        bytes = vcat(UInt8[0xc9, 0x78, 0x24], Vector{UInt8}(codeunits(s)))
        @test decode(bytes) == EX_UUID
    end

    @testset "Round-trip" begin
        # uuid4() generates a random UUID
        for _ in 1:10
            u = uuid4()
            @test decode(encode(u)) == u
        end
    end

    @testset "Malformed payloads error" begin
        # Tag(37) with 15-byte payload (one short)
        @test_throws CBORError decode(vcat(UInt8[0xd8, 0x25, 0x4f], zeros(UInt8, 15)))

        # Tag(37) with text payload (wrong type)
        @test_throws CBORError decode(UInt8[0xd8, 0x25, 0x61, 0x78])

        # Tag(9) with non-text payload
        @test_throws CBORError decode(UInt8[0xc9, 0x18, 0x2a])

        # Tag(9) with malformed UUID string
        bytes = vcat(UInt8[0xc9, 0x65], Vector{UInt8}(codeunits("notuuid")))
        @test_throws CBORError decode(bytes)
    end

    @testset "UUID inside RecordID (key composition)" begin
        # RecordID(table, ::UUID) → Tag(8, [Text, Tag(37, bytes)])
        r = RecordID("users", EX_UUID)
        bytes = encode(r)
        decoded = decode(bytes)
        @test decoded isa RecordID
        @test decoded.table == "users"
        @test decoded.id == EX_UUID
    end
end
