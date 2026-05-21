# L3 — TAG_RECORDID (8): SurrealDB record identifier.
#
# Wire shape: `Tag(8, [table_text, key])` (server canonical), where `key`
# is an Integer / String / Array / Map / Tag(37 UUID) / Tag(49 Range).
# Server also accepts text form `Tag(8, "table:id")` on decode.
# Ref: convert.rs:157-186 (decode), convert.rs:416-434 (encode).

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

# --- CBOR encode / decode ---

# Encode: always emit server-canonical array form. Inner `id` recurses
# through L2 dispatch — Integer/String/Vector/Dict work today; UUID and
# Range will work once their tag handlers land.
function encode(io::IO, r::RecordID)
    n = write_head(io, MAJOR_TAG, TAG_RECORDID)
    return n + encode(io, Any[r.table, r.id])
end

# Decode accepts both forms per convert.rs:157.
function _decode_recordid(payload)
    if payload isa AbstractString
        # Peer-SDK / legacy text form. Simple `table:id` split — complex
        # SurrealQL key syntax (objects, ranges) is not parsed; users
        # hitting that should ensure their producer emits the array form.
        return RecordID(payload)
    elseif payload isa AbstractVector && length(payload) == 2
        table = payload[1]
        table isa AbstractString || throw(CBORError(
            "TAG_RECORDID (8): table must be string, got $(typeof(table))"))
        return RecordID(String(table), payload[2])
    end
    throw(CBORError(
        "TAG_RECORDID (8) payload must be text or 2-element array; got $(typeof(payload))"))
end

_register_tag!(TAG_RECORDID, _decode_recordid)
