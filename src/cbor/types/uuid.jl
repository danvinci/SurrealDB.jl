# L3 — UUID handlers.
#
# Two tags:
#   TAG_SPEC_UUID    (37) — 16 raw bytes (big-endian). Server emits this.
#                            Ref: convert.rs:114,407-409.
#   TAG_STRING_UUID  (9)  — text form. Decode-only (server never emits
#                            at top level; peer SDKs may).
#                            Ref: convert.rs:106-112.
#
# Julia mapping: stdlib `UUIDs.UUID`. No custom type — the wire-format
# Julia type IS the stdlib type. `using UUIDs` lives at SurrealCBOR
# module level so this file just defines methods.

# Bytes ↔ UInt128 (big-endian). 16 explicit shifts; clearer than
# reinterpret/hton dance and platform-independent.
function _uuid_to_bytes(u::UUID)
    v = u.value
    bytes = Vector{UInt8}(undef, 16)
    @inbounds for i in 0:15
        bytes[i + 1] = UInt8((v >> (8 * (15 - i))) & 0xff)
    end
    return bytes
end

function _uuid_from_bytes(bytes::AbstractVector{UInt8})
    length(bytes) == 16 || throw(CBORError(
        "TAG_SPEC_UUID (37) payload must be 16 bytes; got $(length(bytes))"))
    v = UInt128(0)
    for b in bytes
        v = (v << 8) | UInt128(b)
    end
    return UUID(v)
end

# --- Encode (canonical, always emits tag 37 / bytes form) ---

function encode(io::IO, u::UUID)
    n = write_head(io, MAJOR_TAG, TAG_SPEC_UUID)
    return n + encode(io, _uuid_to_bytes(u))
end

# --- Decode ---

# Tag 37: 16 raw bytes.
function _decode_uuid_bytes(payload)
    payload isa AbstractVector{UInt8} || throw(CBORError(
        "TAG_SPEC_UUID (37) payload must be bytes; got $(typeof(payload))"))
    return _uuid_from_bytes(payload)
end

# Tag 9 (decode-only): text form, parsed via UUIDs.UUID(::String).
function _decode_uuid_string(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_STRING_UUID (9) payload must be text; got $(typeof(payload))"))
    try
        return UUID(payload)
    catch e
        throw(CBORError("TAG_STRING_UUID (9): invalid UUID text `$payload` ($e)"))
    end
end

_register_tag!(TAG_SPEC_UUID,   _decode_uuid_bytes)
_register_tag!(TAG_STRING_UUID, _decode_uuid_string)
