# SurrealDB record identifier. Wire-format Surreal type — lives under
# cbor/types/ per the substrate-isolation rule, alongside other Surreal
# wire types (Table, future Decimal/DateTime/Geometry/...). CBOR encode
# and decode handlers for TAG_RECORDID (8) land alongside this in a
# subsequent Phase 3 step.

"""
    RecordID(table, id)
    RecordID(s::AbstractString)

SurrealDB record identifier: `table:id`. `id` is any serializable value
(string, integer, vector, dict, ...). Equality + hashing follow the
struct fields, so `RecordID` is usable as a `Dict` key.

# Examples
```julia
RecordID("user", "abc123")     # table + string id
RecordID("user", 42)           # table + integer id
RecordID("user:abc123")        # parse `table:id` form
```
"""
struct RecordID
    table::String
    id::Any
end

function RecordID(s::AbstractString)
    parts = split(s, ":"; limit=2)
    length(parts) == 2 || throw(ArgumentError(
        "Invalid RecordID string: `$s`. Expected format `table:id`"))
    return RecordID(String(parts[1]), String(parts[2]))
end

Base.string(r::RecordID) = "$(r.table):$(r.id)"
Base.show(io::IO, r::RecordID) = print(io, "RecordID(\"$(r.table):$(r.id)\")")
Base.print(io::IO, r::RecordID) = print(io, r.table, ":", r.id)
Base.:(==)(a::RecordID, b::RecordID) = a.table == b.table && a.id == b.id
Base.hash(r::RecordID, h::UInt) = hash(r.id, hash(r.table, hash(:RecordID, h)))
