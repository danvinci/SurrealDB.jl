# L3 — TAG_TABLE (7): SurrealDB table name.
#
# Wire shape: `Tag(7, text)`. Ref: convert.rs:188 (decode), 413-415 (encode).

# Type definition + Base.* overloads live in ../types/SurrealTypes.jl.

function encode(io::IO, t::Table)
    n = write_head(io, MAJOR_TAG, TAG_TABLE)
    return n + encode(io, t.name)
end

function _decode_table(payload)
    payload isa AbstractString || throw(CBORError(
        "TAG_TABLE (7) payload must be text; got $(typeof(payload))"))
    return Table(String(payload))
end

_register_tag!(TAG_TABLE, _decode_table)
