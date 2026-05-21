# L3 — TAG_TABLE (7): SurrealDB table name.
#
# Wire shape: `Tag(7, text)`. Ref: convert.rs:188 (decode), 413-415 (encode).

"""
    Table(name)

SurrealDB table-name wrapper. Distinguishes "the table named X" from a
plain string in the API.

```julia
Table("stream")
```
"""
struct Table
    name::String
end

Base.string(t::Table) = t.name
Base.show(io::IO, t::Table) = print(io, "Table(\"$(t.name)\")")
Base.:(==)(a::Table, b::Table) = a.name == b.name
Base.hash(t::Table, h::UInt) = hash(t.name, hash(:Table, h))

# --- CBOR encode / decode ---

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
