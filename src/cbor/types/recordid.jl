# L3 — TAG_RECORDID (8): SurrealDB record identifier.
#
# Wire shape: `Tag(8, [table_text, key])` (server canonical), where `key`
# is an Integer / String / Array / Map / Tag(37 UUID) / Tag(49 Range).
# Server also accepts text form `Tag(8, "table:id")` on decode.
# Ref: convert.rs:157-186 (decode), convert.rs:416-434 (encode).

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
