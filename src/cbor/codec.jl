# L2 — native Julia value ↔ CBOR codec (RFC 8949 §3 + §4.2.1).
#
# Builds on L1 head primitives. Knows nothing about SurrealDB tags; tag
# values decode to a generic `Tagged(n, payload)` wrapper that L3 lifts
# into typed Surreal values via post-decode dispatch.
#
# Canonical-form rules enforced on encode:
#   - shortest argument form (already done by L1 write_head)
#   - map keys sorted bytewise-lexicographically by their encoded form
#     (RFC 8949 §4.2.1)
#   - floats emitted as Float64 (matches server's ciborium output;
#     RFC §4.2.2 shortest-float not implemented — Surreal server doesn't
#     emit shrunk floats either)
#   - no indefinite-length on output (decode tolerates them for peer-SDK
#     interop)

# === Generic-tag passthrough ===

"""
    Tagged(tag::UInt64, value::Any)

CBOR major-6 wrapper. L2 emits `Tagged(n, x)` as `Tag(n) + encode(x)`;
on decode, every tag value returns `Tagged(n, payload)` unless an L3
handler is registered (Phase 3+).
"""
struct Tagged
    tag::UInt64
    value::Any
end
Base.:(==)(a::Tagged, b::Tagged) = a.tag == b.tag && a.value == b.value
Base.hash(t::Tagged, h::UInt) = hash(t.value, hash(t.tag, hash(:Tagged, h)))

# === Undefined sentinel ===

"""
    Undefined

Singleton for CBOR's `undefined` simple value (major 7, ai 23). Distinct
from `nothing` (CBOR `null`, ai 22). Rare; surfaces when peer SDKs emit
explicit undefined.
"""
struct Undefined end
const undefined = Undefined()
Base.show(io::IO, ::Undefined) = print(io, "SurrealCBOR.undefined")

# === Encode dispatch ===

"""
    encode(value) -> Vector{UInt8}

Encode a Julia value to canonical CBOR bytes. Throws `CBORError` if
`value` has no encoder. L2 supports: `Bool`, `Nothing`, `Undefined`,
`Integer` (i64 / u64 range), `Float16/32/64`, `AbstractString`,
`Vector{UInt8}`, `AbstractVector`, `AbstractDict`, `Tagged`.

L3 tag handlers extend this via additional `encode(io::IO, ::T)`
methods for Surreal types.
"""
function encode(value)
    io = IOBuffer()
    encode(io, value)
    return take!(io)
end

# Major 7 sentinels
encode(io::IO, v::Bool) = write_simple_head(io, v ? AI_TRUE : AI_FALSE)
encode(io::IO, ::Nothing) = write_simple_head(io, AI_NULL)
encode(io::IO, ::Undefined) = write_simple_head(io, AI_UNDEFINED)

# Integers (i64 / u64 range)
function encode(io::IO, v::Integer)
    if v >= 0
        v <= typemax(UInt64) || throw(CBORError(
            "integer $v exceeds u64 range; bignum tags (2/3) not yet supported"))
        return write_head(io, MAJOR_UINT, UInt64(v))
    else
        # CBOR negative encoding: arg = -1 - n. Use Int128 to avoid
        # overflow at typemin(Int64).
        arg = Int128(-1) - Int128(v)
        arg <= typemax(UInt64) || throw(CBORError(
            "negative integer $v exceeds -1 - u64 range; bignum tags not yet supported"))
        return write_head(io, MAJOR_NINT, UInt64(arg))
    end
end

# Floats — emit at the precision passed (Float64 matches server)
function encode(io::IO, v::Float64)
    n = write_simple_head(io, AI_FLOAT64)
    return n + write(io, hton(reinterpret(UInt64, v)))
end
function encode(io::IO, v::Float32)
    n = write_simple_head(io, AI_FLOAT32)
    return n + write(io, hton(reinterpret(UInt32, v)))
end
function encode(io::IO, v::Float16)
    n = write_simple_head(io, AI_FLOAT16)
    return n + write(io, hton(reinterpret(UInt16, v)))
end

# Text (major 3, UTF-8 bytes)
function encode(io::IO, v::AbstractString)
    bytes = codeunits(v)
    n = write_head(io, MAJOR_TEXT, UInt64(length(bytes)))
    return n + write(io, bytes)
end

# Bytes (major 2). Vector{UInt8} only — distinct from generic Array path.
function encode(io::IO, v::Vector{UInt8})
    n = write_head(io, MAJOR_BYTES, UInt64(length(v)))
    return n + write(io, v)
end

# Array (major 4) — generic AbstractVector
function encode(io::IO, v::AbstractVector)
    n = write_head(io, MAJOR_ARRAY, UInt64(length(v)))
    for x in v
        n += encode(io, x)
    end
    return n
end

# Map (major 5) — keys sorted by encoded byte order (RFC §4.2.1)
function encode(io::IO, v::AbstractDict)
    # Encode each pair to per-pair buffers, then sort by key bytes.
    pairs = Vector{Tuple{Vector{UInt8}, Vector{UInt8}}}(undef, length(v))
    i = 1
    for (k, val) in v
        kio = IOBuffer(); encode(kio, k); kbytes = take!(kio)
        vio = IOBuffer(); encode(vio, val); vbytes = take!(vio)
        pairs[i] = (kbytes, vbytes)
        i += 1
    end
    sort!(pairs; by = first)
    n = write_head(io, MAJOR_MAP, UInt64(length(pairs)))
    for (kbytes, vbytes) in pairs
        n += write(io, kbytes)
        n += write(io, vbytes)
    end
    return n
end

# Tagged passthrough
function encode(io::IO, v::Tagged)
    n = write_head(io, MAJOR_TAG, v.tag)
    return n + encode(io, v.value)
end

# === Decode dispatch ===

"""
    decode(bytes::AbstractVector{UInt8}) -> Any
    decode(io::IO) -> Any

Parse one CBOR value. Tag values return `Tagged(n, payload)` wrappers;
L3 lifts these into typed Surreal values via post-decode dispatch.

Throws `CBORError` on malformed input or unsupported simple values.
Tolerates indefinite-length collections from peer SDKs.
"""
function decode(bytes::AbstractVector{UInt8})
    io = IOBuffer(bytes)
    v = decode(io)
    eof(io) || throw(CBORError("trailing bytes after decoded value"))
    return v
end

function decode(io::IO)
    major, ai, arg = read_head(io)
    if major == MAJOR_UINT
        return arg <= typemax(Int64) ? Int64(arg) : BigInt(arg)
    elseif major == MAJOR_NINT
        n = Int128(-1) - Int128(arg)
        return typemin(Int64) <= n <= typemax(Int64) ? Int64(n) : BigInt(n)
    elseif major == MAJOR_BYTES
        return ai == AI_INDEFINITE ? _read_indef_bytes(io) : read(io, Int(arg))
    elseif major == MAJOR_TEXT
        if ai == AI_INDEFINITE
            return _read_indef_text(io)
        end
        return String(read(io, Int(arg)))
    elseif major == MAJOR_ARRAY
        if ai == AI_INDEFINITE
            return _read_indef_array(io)
        end
        return Any[decode(io) for _ in 1:Int(arg)]
    elseif major == MAJOR_MAP
        if ai == AI_INDEFINITE
            return _read_indef_map(io)
        end
        out = Dict{Any,Any}()
        for _ in 1:Int(arg)
            k = decode(io); v = decode(io)
            out[k] = v
        end
        return out
    elseif major == MAJOR_TAG
        return Tagged(arg, decode(io))
    elseif major == MAJOR_SIMPLE
        return _decode_simple(ai, arg)
    end
    throw(CBORError("unreachable major type: $major"))
end

function _decode_simple(ai::UInt8, arg::UInt64)
    ai == AI_FALSE     && return false
    ai == AI_TRUE      && return true
    ai == AI_NULL      && return nothing
    ai == AI_UNDEFINED && return undefined
    ai == AI_FLOAT16   && return reinterpret(Float16, UInt16(arg))
    ai == AI_FLOAT32   && return reinterpret(Float32, UInt32(arg))
    ai == AI_FLOAT64   && return reinterpret(Float64, arg)
    ai == AI_INDEFINITE && throw(CBORError("unexpected break code outside indefinite-length collection"))
    # ai 0-19: immediate simple values (rarely used); ai 24: 1-byte simple
    throw(CBORError("unsupported simple value ai=$ai"))
end

# Indefinite-length collection readers (decode-side tolerance for peer SDKs)

function _read_indef_bytes(io::IO)
    out = UInt8[]
    while true
        m, a, n = read_head(io)
        m == MAJOR_SIMPLE && a == AI_INDEFINITE && return out
        m == MAJOR_BYTES || throw(CBORError("non-bytes chunk in indefinite bytes"))
        a == AI_INDEFINITE && throw(CBORError("nested indefinite bytes"))
        append!(out, read(io, Int(n)))
    end
end

function _read_indef_text(io::IO)
    parts = String[]
    while true
        m, a, n = read_head(io)
        m == MAJOR_SIMPLE && a == AI_INDEFINITE && return join(parts)
        m == MAJOR_TEXT || throw(CBORError("non-text chunk in indefinite text"))
        a == AI_INDEFINITE && throw(CBORError("nested indefinite text"))
        push!(parts, String(read(io, Int(n))))
    end
end

function _read_indef_array(io::IO)
    out = Any[]
    while !_at_break(io)
        push!(out, decode(io))
    end
    read(io, UInt8)  # consume break
    return out
end

function _read_indef_map(io::IO)
    out = Dict{Any,Any}()
    while !_at_break(io)
        k = decode(io); v = decode(io)
        out[k] = v
    end
    read(io, UInt8)  # consume break
    return out
end

# Peek next byte for break-code (0xff = major 7 ai 31)
_at_break(io::IO) = peek(io, UInt8) == 0xff
