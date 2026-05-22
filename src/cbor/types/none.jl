# L3 — TAG_NONE (6): SurrealDB NONE sentinel.
#
# Wire shape: `Tag(6, Null)` — 2 bytes `0xC6 0xF6`.
# Ref: surrealdb/core/src/rpc/format/cbor/convert.rs:104 (decode),
#      surrealdb/core/src/rpc/format/cbor/convert.rs:369 (encode).
#
# Julia mapping: `missing`. Distinct from `nothing` (CBOR `Null`,
# Surreal `Null` literal). Surreal semantics:
#   NONE = "field not set" → maps to Julia's `missing` (idiomatic
#                            "data not present in record")
#   Null = "field set to null literal" → `nothing`
# This pair-match matches Julia tabular conventions (DataFrames,
# Tables.jl) where `missing` propagates through ops.

# Encode: any `missing` value → Tag(6) + Null.
function encode(io::IO, ::Missing)
    n = write_head(io, MAJOR_TAG, TAG_NONE)
    return n + write_simple_head(io, AI_NULL)
end

# Decode: Tag(6) payload must be CBOR null (decoded to Julia `nothing`).
# Anything else is malformed.
function _decode_none(payload)
    isnothing(payload) || throw(CBORError(
        "TAG_NONE (6) payload must be null; got $(typeof(payload))"))
    return missing
end

_register_tag!(TAG_NONE, _decode_none)
