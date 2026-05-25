# L3 — TAG_SET (56): SurrealDB Set type.
#
# Wire shape: `Tag(56, array)`. Server decodes via `BTreeSet::from(...)`
# so emitted order is its natural value-Ord. We emit in encoded-byte
# sort (deterministic, reproducible by the Rust fixture generator).
# Wire byte order may differ between us and the server for sets with
# mixed types or unusual values, but **semantic round-trip is preserved**
# — Set has no order; decode normalizes either way.
# Ref: convert.rs:353-358 (decode), 444-449 (encode).

# Wraps Julia's `Set` — no custom type. Decoded as `Set{Any}` since
# wire payloads may carry mixed element types.

function encode(io::IO, s::AbstractSet)
    # Pre-encode each element so we can sort deterministically by
    # encoded bytes, then concatenate.
    encoded = Vector{Vector{UInt8}}(undef, length(s))
    i = 1
    for v in s
        eio = IOBuffer(); encode(eio, v); encoded[i] = take!(eio)
        i += 1
    end
    sort!(encoded)
    n = write_head(io, MAJOR_TAG, TAG_SET)
    n += write_head(io, MAJOR_ARRAY, UInt64(length(encoded)))
    for bytes in encoded
        n += write(io, bytes)
    end
    return n
end

# --- CBOR decode ---

function _decode_set(payload)
    payload isa AbstractVector || throw(CBORError(
        "TAG_SET (56) payload must be array; got $(typeof(payload))"))
    return Set{Any}(payload)
end

_register_tag!(TAG_SET, _decode_set)
