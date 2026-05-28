# L3 — TAG_RECORDID (8) handler tests.
#
# Wire spec (convert.rs:157-186 decode, 416-434 encode):
#   RecordID = Tag(8, [table_text, key])  -- server canonical
#            | Tag(8, "table:id")          -- peer-SDK / legacy form (decode-only here)
# Key polymorphism: Integer / String / Array / Map / Tag(37 UUID) / Tag(49 Range).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: encode, decode, Tagged, CBORError, RecordID, TAG_RECORDID
using Test

@testset "L3 RecordID (tag 8)" begin

    @testset "Encode — array form (server canonical)" begin
        # Integer key → 0xc8 0x82 + Text("users") + Integer(42)
        @test encode(RecordID("users", 42)) ==
            UInt8[0xc8, 0x82, 0x65, 0x75, 0x73, 0x65, 0x72, 0x73, 0x18, 0x2a]

        # String key → 0xc8 0x82 + Text("users") + Text("alice")
        @test encode(RecordID("users", "alice")) ==
            UInt8[0xc8, 0x82,
                  0x65, 0x75, 0x73, 0x65, 0x72, 0x73,
                  0x65, 0x61, 0x6c, 0x69, 0x63, 0x65]
    end

    @testset "Decode — array form" begin
        # Tag(8, [Text("users"), Integer(42)])
        @test decode(UInt8[0xc8, 0x82, 0x65, 0x75, 0x73, 0x65, 0x72, 0x73, 0x18, 0x2a]) ==
            RecordID("users", 42)

        # Tag(8, [Text("users"), Text("alice")])
        @test decode(UInt8[0xc8, 0x82,
                          0x65, 0x75, 0x73, 0x65, 0x72, 0x73,
                          0x65, 0x61, 0x6c, 0x69, 0x63, 0x65]) ==
            RecordID("users", "alice")
    end

    @testset "Decode — text form (peer-SDK fallback)" begin
        # Tag(8, Text("users:alice")) = 0xc8 0x6b + 11 bytes
        bytes = UInt8[0xc8, 0x6b, 0x75, 0x73, 0x65, 0x72, 0x73, 0x3a,
                      0x61, 0x6c, 0x69, 0x63, 0x65]
        @test decode(bytes) == RecordID("users", "alice")
    end

    @testset "Round-trip" begin
        # Simple keys
        for r in (RecordID("u", 1), RecordID("u", "x"), RecordID("logs", "2026-05-22"))
            @test decode(encode(r)) == r
        end

        # Complex key types — Array
        r = RecordID("logs", [2026, 5, 22])
        decoded = decode(encode(r))
        # Decoded array is Vector{Any}; original Vector{Int}. Compare values.
        @test decoded isa RecordID
        @test decoded.table == "logs"
        @test decoded.id == [2026, 5, 22]

        # Complex key — Dict (decode normalizes to Dict{Any,Any})
        r = RecordID("user", Dict("first" => "ada", "last" => "lovelace"))
        decoded = decode(encode(r))
        @test decoded isa RecordID
        @test decoded.table == "user"
        @test decoded.id["first"] == "ada"
        @test decoded.id["last"] == "lovelace"
    end

    @testset "Malformed payloads error" begin
        # Tag(8, Integer(42)) — wrong payload type
        @test_throws CBORError decode(UInt8[0xc8, 0x18, 0x2a])

        # Tag(8, [single_element]) — array length != 2
        @test_throws CBORError decode(UInt8[0xc8, 0x81, 0x61, 0x78])

        # Tag(8, [Integer(1), Text("x")]) — table not string
        @test_throws CBORError decode(UInt8[0xc8, 0x82, 0x01, 0x61, 0x78])
    end

    @testset "RecordID as Dict key (== + hash)" begin
        d = Dict(RecordID("u", 1) => "alice", RecordID("u", 2) => "bob")
        @test d[RecordID("u", 1)] == "alice"
        @test d[RecordID("u", 2)] == "bob"
    end
end
