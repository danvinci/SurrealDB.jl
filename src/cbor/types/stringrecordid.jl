# L3 — `StringRecordID`: opaque "raw string record id" carrier.
#
# Wire shape: `Tag(8, text)` — same TAG_RECORDID as `RecordID`, but with a
# text payload instead of a `[table, key]` array. Server runs its full
# SurrealQL parser on the string (handles complex ids: ranges, escaped
# colons, nested objects). One-way send only: `_decode_recordid` always
# materializes typed `RecordID`, never `StringRecordID`. Mirrors
# `StringRecordId` in surrealdb.js / surrealdb.net.

# Type definition + Base.* overloads live in ../types/SurrealTypes.jl.

function encode(io::IO, s::StringRecordID)
    n = write_head(io, MAJOR_TAG, TAG_RECORDID)
    return n + encode(io, s.value)
end
