# L3 — `StringRecordID`: opaque "raw string record id" carrier.
#
# Wire shape: bare CBOR text string (no tag). The server parses the string
# into a typed record id on receipt. One-way send only — decode emits
# `RecordID` via TAG_RECORDID, never `StringRecordID`. Mirrors
# `StringRecordId` in surrealdb.js / surrealdb.net.

# Type definition + Base.* overloads live in ../types/SurrealTypes.jl.

function encode(io::IO, s::StringRecordID)
    return encode(io, s.value)
end
