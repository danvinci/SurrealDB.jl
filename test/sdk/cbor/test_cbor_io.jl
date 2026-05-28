# L1 head-byte tests against RFC 8949 Appendix A worked examples.
#
# Every (value, hex-bytes) pair below is sourced from RFC 8949 §A. We
# test the *head* portion — major + ai + argument — independently of
# content (string/array contents are L2's concern).

using SurrealDB.SurrealCBOR
using SurrealDB.SurrealCBOR: read_head, write_head, write_simple_head, CBORError,
    MAJOR_UINT, MAJOR_NINT, MAJOR_BYTES, MAJOR_TEXT,
    MAJOR_ARRAY, MAJOR_MAP, MAJOR_TAG, MAJOR_SIMPLE,
    AI_FALSE, AI_TRUE, AI_NULL, AI_UNDEFINED,
    AI_SIMPLE_1B, AI_FLOAT16, AI_FLOAT32, AI_FLOAT64, AI_INDEFINITE
using Test

# Helper: encode + return bytes
_enc(major, arg) = (io = IOBuffer(); write_head(io, UInt8(major), UInt64(arg)); take!(io))
_enc_simple(ai)  = (io = IOBuffer(); write_simple_head(io, UInt8(ai)); take!(io))
_dec(hex::Vector{UInt8}) = read_head(IOBuffer(hex))

@testset "L1 — RFC 8949 §A head bytes" begin

    @testset "Unsigned int head (major 0)" begin
        # RFC §A: 0 → 0x00; 1 → 0x01; 10 → 0x0a; 23 → 0x17 (last immediate)
        @test _enc(MAJOR_UINT, 0)  == UInt8[0x00]
        @test _enc(MAJOR_UINT, 1)  == UInt8[0x01]
        @test _enc(MAJOR_UINT, 10) == UInt8[0x0a]
        @test _enc(MAJOR_UINT, 23) == UInt8[0x17]

        # 24 → 0x18 0x18 (first 1-byte form; ai=24)
        @test _enc(MAJOR_UINT, 24)  == UInt8[0x18, 0x18]
        @test _enc(MAJOR_UINT, 25)  == UInt8[0x18, 0x19]
        @test _enc(MAJOR_UINT, 100) == UInt8[0x18, 0x64]
        @test _enc(MAJOR_UINT, 255) == UInt8[0x18, 0xff]

        # 256 → 2-byte form
        @test _enc(MAJOR_UINT, 256)   == UInt8[0x19, 0x01, 0x00]
        @test _enc(MAJOR_UINT, 1000)  == UInt8[0x19, 0x03, 0xe8]
        @test _enc(MAJOR_UINT, 65535) == UInt8[0x19, 0xff, 0xff]

        # 65536 → 4-byte form
        @test _enc(MAJOR_UINT, 65536)        == UInt8[0x1a, 0x00, 0x01, 0x00, 0x00]
        @test _enc(MAJOR_UINT, 1_000_000)    == UInt8[0x1a, 0x00, 0x0f, 0x42, 0x40]
        @test _enc(MAJOR_UINT, typemax(UInt32)) == UInt8[0x1a, 0xff, 0xff, 0xff, 0xff]

        # 2^32 → 8-byte form
        @test _enc(MAJOR_UINT, UInt64(2)^32) ==
            UInt8[0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        @test _enc(MAJOR_UINT, 1_000_000_000_000) ==
            UInt8[0x1b, 0x00, 0x00, 0x00, 0xe8, 0xd4, 0xa5, 0x10, 0x00]
        @test _enc(MAJOR_UINT, typemax(UInt64)) ==
            UInt8[0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    end

    @testset "Negative int head (major 1)" begin
        # RFC §A: -1 → 0x20 (arg=0 means -1; arg = -1 - n)
        # Caller is responsible for the -1-n bias; here we just verify the
        # head emission given the already-biased unsigned arg.
        @test _enc(MAJOR_NINT, 0)   == UInt8[0x20]   # -1
        @test _enc(MAJOR_NINT, 9)   == UInt8[0x29]   # -10
        @test _enc(MAJOR_NINT, 23)  == UInt8[0x37]   # -24 (last immediate)
        @test _enc(MAJOR_NINT, 24)  == UInt8[0x38, 0x18]   # -25
        @test _enc(MAJOR_NINT, 99)  == UInt8[0x38, 0x63]   # -100
        @test _enc(MAJOR_NINT, 999) == UInt8[0x39, 0x03, 0xe7]  # -1000
    end

    @testset "String / bytes head" begin
        # Length-encoded heads; content tested at L2.
        @test _enc(MAJOR_BYTES, 0)  == UInt8[0x40]   # empty bytes
        @test _enc(MAJOR_BYTES, 4)  == UInt8[0x44]
        @test _enc(MAJOR_BYTES, 23) == UInt8[0x57]
        @test _enc(MAJOR_BYTES, 24) == UInt8[0x58, 0x18]

        @test _enc(MAJOR_TEXT, 0)  == UInt8[0x60]   # empty text
        @test _enc(MAJOR_TEXT, 1)  == UInt8[0x61]   # 1-char text
        @test _enc(MAJOR_TEXT, 4)  == UInt8[0x64]   # "IETF" head
        @test _enc(MAJOR_TEXT, 23) == UInt8[0x77]
        @test _enc(MAJOR_TEXT, 24) == UInt8[0x78, 0x18]
    end

    @testset "Array / map head" begin
        @test _enc(MAJOR_ARRAY, 0)   == UInt8[0x80]   # []
        @test _enc(MAJOR_ARRAY, 3)   == UInt8[0x83]   # [_,_,_]
        @test _enc(MAJOR_ARRAY, 23)  == UInt8[0x97]
        @test _enc(MAJOR_ARRAY, 25)  == UInt8[0x98, 0x19]
        @test _enc(MAJOR_ARRAY, 100) == UInt8[0x98, 0x64]

        @test _enc(MAJOR_MAP, 0) == UInt8[0xa0]   # {}
        @test _enc(MAJOR_MAP, 2) == UInt8[0xa2]
    end

    @testset "Tag head (major 6)" begin
        # SurrealDB-relevant tag heads
        @test _enc(MAJOR_TAG, 0)  == UInt8[0xc0]   # TAG_SPEC_DATETIME
        @test _enc(MAJOR_TAG, 6)  == UInt8[0xc6]   # TAG_NONE
        @test _enc(MAJOR_TAG, 7)  == UInt8[0xc7]   # TAG_TABLE
        @test _enc(MAJOR_TAG, 8)  == UInt8[0xc8]   # TAG_RECORDID
        @test _enc(MAJOR_TAG, 10) == UInt8[0xca]   # TAG_STRING_DECIMAL
        @test _enc(MAJOR_TAG, 12) == UInt8[0xcc]   # TAG_CUSTOM_DATETIME
        @test _enc(MAJOR_TAG, 14) == UInt8[0xce]   # TAG_CUSTOM_DURATION
        @test _enc(MAJOR_TAG, 23) == UInt8[0xd7]
        @test _enc(MAJOR_TAG, 24) == UInt8[0xd8, 0x18]
        @test _enc(MAJOR_TAG, 37) == UInt8[0xd8, 0x25]   # TAG_SPEC_UUID
        @test _enc(MAJOR_TAG, 49) == UInt8[0xd8, 0x31]   # TAG_RANGE
        @test _enc(MAJOR_TAG, 55) == UInt8[0xd8, 0x37]   # TAG_FILE
        @test _enc(MAJOR_TAG, 56) == UInt8[0xd8, 0x38]   # TAG_SET
        @test _enc(MAJOR_TAG, 88) == UInt8[0xd8, 0x58]   # TAG_GEOMETRY_POINT
        @test _enc(MAJOR_TAG, 94) == UInt8[0xd8, 0x5e]   # TAG_GEOMETRY_COLLECTION
    end

    @testset "Simple values + sentinels (major 7)" begin
        @test _enc_simple(AI_FALSE)     == UInt8[0xf4]
        @test _enc_simple(AI_TRUE)      == UInt8[0xf5]
        @test _enc_simple(AI_NULL)      == UInt8[0xf6]
        @test _enc_simple(AI_UNDEFINED) == UInt8[0xf7]
        @test _enc_simple(AI_INDEFINITE) == UInt8[0xff]   # break code
    end

    @testset "Reject reserved AI on encode" begin
        # Reserved major (>7)
        @test_throws CBORError write_head(IOBuffer(), UInt8(8), UInt64(0))
        # Reserved simple ai
        @test_throws CBORError write_simple_head(IOBuffer(), UInt8(0x20))
    end

    @testset "Read head — RFC §A round-trip" begin
        # Every byte sequence above should round-trip head structure.
        # Just check a representative set; the encoder tests above
        # established the byte mappings.

        # Immediate uint
        m, ai, arg = _dec(UInt8[0x00])
        @test (m, ai, arg) == (MAJOR_UINT, 0x00, UInt64(0))

        m, ai, arg = _dec(UInt8[0x17])
        @test (m, ai, arg) == (MAJOR_UINT, 0x17, UInt64(23))

        # 1-byte uint
        m, ai, arg = _dec(UInt8[0x18, 0x64])
        @test (m, ai, arg) == (MAJOR_UINT, 0x18, UInt64(100))

        # 2-byte uint
        m, ai, arg = _dec(UInt8[0x19, 0x03, 0xe8])
        @test (m, ai, arg) == (MAJOR_UINT, 0x19, UInt64(1000))

        # 4-byte uint
        m, ai, arg = _dec(UInt8[0x1a, 0x00, 0x0f, 0x42, 0x40])
        @test (m, ai, arg) == (MAJOR_UINT, 0x1a, UInt64(1_000_000))

        # 8-byte uint at typemax
        m, ai, arg = _dec(UInt8[0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        @test (m, ai, arg) == (MAJOR_UINT, 0x1b, typemax(UInt64))

        # Negative int
        m, ai, arg = _dec(UInt8[0x20])
        @test (m, ai, arg) == (MAJOR_NINT, 0x00, UInt64(0))   # -1

        m, ai, arg = _dec(UInt8[0x38, 0x63])
        @test (m, ai, arg) == (MAJOR_NINT, 0x18, UInt64(99))  # -100

        # String head
        m, ai, arg = _dec(UInt8[0x64])
        @test (m, ai, arg) == (MAJOR_TEXT, 0x04, UInt64(4))

        # Array head
        m, ai, arg = _dec(UInt8[0x83])
        @test (m, ai, arg) == (MAJOR_ARRAY, 0x03, UInt64(3))

        # Map head
        m, ai, arg = _dec(UInt8[0xa2])
        @test (m, ai, arg) == (MAJOR_MAP, 0x02, UInt64(2))

        # Tag head — small (immediate)
        m, ai, arg = _dec(UInt8[0xc0])
        @test (m, ai, arg) == (MAJOR_TAG, 0x00, UInt64(0))    # TAG_SPEC_DATETIME

        m, ai, arg = _dec(UInt8[0xc6])
        @test (m, ai, arg) == (MAJOR_TAG, 0x06, UInt64(6))    # TAG_NONE

        # Tag head — 1-byte form
        m, ai, arg = _dec(UInt8[0xd8, 0x25])
        @test (m, ai, arg) == (MAJOR_TAG, 0x18, UInt64(37))   # TAG_SPEC_UUID

        m, ai, arg = _dec(UInt8[0xd8, 0x5e])
        @test (m, ai, arg) == (MAJOR_TAG, 0x18, UInt64(94))   # TAG_GEOMETRY_COLLECTION

        # Major 7 sentinels
        m, ai, arg = _dec(UInt8[0xf4])
        @test (m, ai) == (MAJOR_SIMPLE, AI_FALSE)
        m, ai, arg = _dec(UInt8[0xf5])
        @test (m, ai) == (MAJOR_SIMPLE, AI_TRUE)
        m, ai, arg = _dec(UInt8[0xf6])
        @test (m, ai) == (MAJOR_SIMPLE, AI_NULL)
        m, ai, arg = _dec(UInt8[0xf7])
        @test (m, ai) == (MAJOR_SIMPLE, AI_UNDEFINED)

        # Indefinite-length open / break
        m, ai, arg = _dec(UInt8[0x7f])   # indefinite text open
        @test (m, ai, arg) == (MAJOR_TEXT, AI_INDEFINITE, UInt64(0))
        m, ai, arg = _dec(UInt8[0x9f])   # indefinite array open
        @test (m, ai, arg) == (MAJOR_ARRAY, AI_INDEFINITE, UInt64(0))
        m, ai, arg = _dec(UInt8[0xff])   # break
        @test (m, ai, arg) == (MAJOR_SIMPLE, AI_INDEFINITE, UInt64(0))
    end

    @testset "Float head — raw bits captured" begin
        # RFC §A float examples. read_head returns raw float bits as arg;
        # the L2 codec will reinterpret to Float16/32/64.

        # 0.0 (half) → 0xf9 0x00 0x00
        m, ai, arg = _dec(UInt8[0xf9, 0x00, 0x00])
        @test (m, ai) == (MAJOR_SIMPLE, AI_FLOAT16)
        @test reinterpret(Float16, UInt16(arg)) === Float16(0.0)

        # 1.0 (half) → 0xf9 0x3c 0x00
        m, ai, arg = _dec(UInt8[0xf9, 0x3c, 0x00])
        @test (m, ai) == (MAJOR_SIMPLE, AI_FLOAT16)
        @test reinterpret(Float16, UInt16(arg)) === Float16(1.0)

        # 100000.0 (single) → 0xfa 0x47 0xc3 0x50 0x00
        m, ai, arg = _dec(UInt8[0xfa, 0x47, 0xc3, 0x50, 0x00])
        @test (m, ai) == (MAJOR_SIMPLE, AI_FLOAT32)
        @test reinterpret(Float32, UInt32(arg)) === Float32(100000.0)

        # 1.1 (double) → 0xfb 0x3f 0xf1 0x99 0x99 0x99 0x99 0x99 0x9a
        m, ai, arg = _dec(UInt8[0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a])
        @test (m, ai) == (MAJOR_SIMPLE, AI_FLOAT64)
        @test reinterpret(Float64, arg) === 1.1

        # Infinity (half) → 0xf9 0x7c 0x00
        m, ai, arg = _dec(UInt8[0xf9, 0x7c, 0x00])
        @test reinterpret(Float16, UInt16(arg)) === Float16(Inf)

        # NaN (half) → 0xf9 0x7e 0x00
        m, ai, arg = _dec(UInt8[0xf9, 0x7e, 0x00])
        @test isnan(reinterpret(Float16, UInt16(arg)))
    end

    @testset "Reject reserved AI on decode" begin
        # ai 28, 29, 30 are reserved
        @test_throws CBORError _dec(UInt8[0x1c])  # major 0 + ai 28
        @test_throws CBORError _dec(UInt8[0x1d])  # major 0 + ai 29
        @test_throws CBORError _dec(UInt8[0x1e])  # major 0 + ai 30
        @test_throws CBORError _dec(UInt8[0xdc])  # major 6 + ai 28
    end

    @testset "Write→read identity over uniform corpus" begin
        # The shortest-form contract: for each (major, arg), encode then
        # decode and confirm we get back the same major + arg. Decoder
        # ignores ai differences; encoder picks shortest.
        for major in UInt8.(0:6)   # skip major 7 (different encoding)
            for arg in UInt64[0, 1, 23, 24, 100, 255, 256, 1000, 65535,
                               65536, 1_000_000, typemax(UInt32),
                               UInt64(2)^32, 1_000_000_000_000,
                               typemax(UInt64)]
                io = IOBuffer()
                write_head(io, major, arg)
                seekstart(io)
                m, _ai, a = read_head(io)
                @test (m, a) == (major, arg)
            end
        end
    end
end
