# L1 — RFC 8949 §3 head byte mechanics.
#
# A CBOR head is an "initial byte" plus an optional "argument" of 1, 2, 4,
# or 8 bytes (big-endian). The initial byte packs:
#   - major type   (high 3 bits, values 0-7)
#   - additional info (low 5 bits, values 0-31)
#
# The "argument" is an unsigned integer with multiple meanings depending
# on major type:
#   major 0  uint           - value = arg
#   major 1  negative int   - value = -1 - arg
#   major 2  byte string    - arg = byte length
#   major 3  text string    - arg = byte length (utf-8)
#   major 4  array          - arg = element count
#   major 5  map            - arg = pair count
#   major 6  tag            - arg = tag number; next item is tagged
#   major 7  simple / float - arg interpretation depends on ai:
#       ai 20-23: false / true / null / undefined  (no follow-up bytes)
#       ai 24:    1-byte simple value
#       ai 25-27: half / single / double float     (raw float bits in arg)
#       ai 31:    break code (for indefinite-length sentinels)
#
# Argument encoding (RFC 8949 §3):
#   ai 0-23   - immediate; arg = ai
#   ai 24     - arg in next 1 byte
#   ai 25     - arg in next 2 bytes (big-endian)
#   ai 26     - arg in next 4 bytes
#   ai 27     - arg in next 8 bytes
#   ai 28-30  - reserved (decode error)
#   ai 31     - indefinite-length (no argument bytes; valid only for
#               majors 2, 3, 4, 5, 7)
#
# Canonical encoding (RFC 8949 §4.2.1): always use the shortest argument
# form. write_head enforces this for non-float arguments.

# --- Major type constants ---
const MAJOR_UINT::UInt8   = 0x00
const MAJOR_NINT::UInt8   = 0x01
const MAJOR_BYTES::UInt8  = 0x02
const MAJOR_TEXT::UInt8   = 0x03
const MAJOR_ARRAY::UInt8  = 0x04
const MAJOR_MAP::UInt8    = 0x05
const MAJOR_TAG::UInt8    = 0x06
const MAJOR_SIMPLE::UInt8 = 0x07

# --- Additional info constants for major 7 ---
const AI_FALSE::UInt8      = 0x14  # 20
const AI_TRUE::UInt8       = 0x15  # 21
const AI_NULL::UInt8       = 0x16  # 22
const AI_UNDEFINED::UInt8  = 0x17  # 23
const AI_SIMPLE_1B::UInt8  = 0x18  # 24 - simple value in next byte
const AI_FLOAT16::UInt8    = 0x19  # 25
const AI_FLOAT32::UInt8    = 0x1a  # 26
const AI_FLOAT64::UInt8    = 0x1b  # 27
const AI_INDEFINITE::UInt8 = 0x1f  # 31 - break / indefinite open

# --- Internal AI thresholds ---
const _AI_IMMEDIATE_MAX::UInt8 = 0x17  # 23
const _AI_ARG_1B::UInt8        = 0x18  # 24
const _AI_ARG_2B::UInt8        = 0x19  # 25
const _AI_ARG_4B::UInt8        = 0x1a  # 26
const _AI_ARG_8B::UInt8        = 0x1b  # 27

"""
    write_head(io::IO, major::UInt8, arg::Unsigned) -> Int

Emit a CBOR head: initial byte + canonical (shortest) argument encoding
(RFC 8949 §3 + §4.2.1). Returns the number of bytes written.

`major` must be in 0..7. `arg` is the unsigned argument interpretation
appropriate for `major` (length for strings/arrays/maps, tag number for
tags, value for uints, etc.). For negative integers (major 1), pass
`arg = -1 - n` (the caller handles the bias).

For major 7 sentinel values (false/true/null/undefined) and float
emission, use the dedicated head-byte helpers (`write_simple_head` /
`write_float_head`) rather than calling `write_head` directly — this
function only emits the integer-argument forms.
"""
function write_head(io::IO, major::UInt8, arg::Unsigned)
    major <= MAJOR_SIMPLE || throw(CBORError("major type out of range: $major"))
    a = UInt64(arg)
    if a < 0x18  # immediate
        return write(io, (major << 5) | UInt8(a))
    elseif a <= typemax(UInt8)
        return write(io, (major << 5) | _AI_ARG_1B) + write(io, UInt8(a))
    elseif a <= typemax(UInt16)
        return write(io, (major << 5) | _AI_ARG_2B) + write(io, hton(UInt16(a)))
    elseif a <= typemax(UInt32)
        return write(io, (major << 5) | _AI_ARG_4B) + write(io, hton(UInt32(a)))
    else
        return write(io, (major << 5) | _AI_ARG_8B) + write(io, hton(a))
    end
end

"""
    write_simple_head(io::IO, ai::UInt8) -> Int

Emit a single-byte major-7 head with no argument bytes. Use for the
sentinel constants `AI_FALSE`, `AI_TRUE`, `AI_NULL`, `AI_UNDEFINED`,
`AI_INDEFINITE` (break code), and for immediate simple values
(ai 0-19, 28-30 — though most are reserved). Returns 1.
"""
function write_simple_head(io::IO, ai::UInt8)
    ai <= 0x1f || throw(CBORError("simple ai out of range: $ai"))
    return write(io, (MAJOR_SIMPLE << 5) | ai)
end

"""
    read_head(io::IO) -> (major::UInt8, ai::UInt8, arg::UInt64)

Parse a CBOR head from `io` (RFC 8949 §3). Returns:

- `major` — major type, 0..7
- `ai`    — additional info, 0..31 (exact byte from the initial byte's
            low 5 bits; preserved for cases where it carries meaning
            beyond argument encoding — major 7 sentinels and floats).
- `arg`   — parsed unsigned argument.

For `major == MAJOR_SIMPLE` (7):
- `ai` in 20..23 → sentinel; `arg = ai` (caller dispatches on `ai`).
- `ai == 24`     → 1-byte simple value; `arg` holds it.
- `ai == 25/26/27` → half/single/double float; `arg` holds raw float
  bits (caller reinterprets via `Float16/32/64`).
- `ai == 31`     → break code; `arg = 0`. Only valid as a terminator
  inside indefinite-length collections — caller validates context.

For all other majors, `ai = 31` opens an indefinite-length collection;
`arg = 0`. The shortest-form encoding rule (§4.2.1) is NOT enforced on
read — non-canonical inputs from peer SDKs parse correctly.

Throws `CBORError` for reserved `ai` 28..30.
"""
function read_head(io::IO)
    initial = read(io, UInt8)
    major = initial >> 5
    ai = initial & 0x1f
    arg = if ai <= _AI_IMMEDIATE_MAX
        UInt64(ai)
    elseif ai == _AI_ARG_1B
        UInt64(read(io, UInt8))
    elseif ai == _AI_ARG_2B
        UInt64(ntoh(read(io, UInt16)))
    elseif ai == _AI_ARG_4B
        UInt64(ntoh(read(io, UInt32)))
    elseif ai == _AI_ARG_8B
        ntoh(read(io, UInt64))
    elseif ai == AI_INDEFINITE
        UInt64(0)
    else  # 28, 29, 30 — reserved
        throw(CBORError("reserved additional info: $ai"))
    end
    return (major, ai, arg)
end
