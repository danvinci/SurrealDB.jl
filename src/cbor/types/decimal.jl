# L3 — TAG_STRING_DECIMAL (10): SurrealDB arbitrary-precision decimal.
#
# Wire shape: `Tag(10, text)` — server uses `rust_decimal` internally,
# emits / accepts the canonical string form. Ref: convert.rs:116-122
# (decode), 375-377 (encode).

function encode(io::IO, d::SurrealDecimal)
    n = write_head(io, MAJOR_TAG, TAG_STRING_DECIMAL)
    return n + encode(io, d.value)
end

function _decode_decimal(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_STRING_DECIMAL (10) payload must be text; got $(typeof(payload))"))
    return SurrealDecimal(String(payload))
end

_register_tag!(TAG_STRING_DECIMAL, _decode_decimal)
