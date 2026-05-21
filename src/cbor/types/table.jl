# L3 — TAG_TABLE (7): SurrealDB table name.
#
# Wire shape: `Tag(7, text)`. Ref: convert.rs:188 (decode), 413 (encode).
#
# This file currently defines the Julia type only. The Tag 7 encode /
# decode handlers land alongside this in a subsequent Phase 3 step;
# locating the type under `cbor/types/` keeps the substrate boundary
# clean from the start.

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
