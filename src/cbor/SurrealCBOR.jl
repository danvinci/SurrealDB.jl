# SurrealCBOR — SurrealDB-flavored CBOR (RFC 8949) codec.
#
# Internal submodule of SurrealDB.jl. Designed for clean extraction as a
# standalone package later; do NOT import from parent SurrealDB modules.
#
# Layers (see _notes/_projects/_surrealdb/design-cbor-transport.md):
#   L1  io.jl       — RFC 8949 §3 head bytes (this module)
#   L2  codec.jl    — native Julia value encode/decode  (TBD)
#   L3  tags.jl     — SurrealDB tag handlers            (TBD)

module SurrealCBOR

# Stdlib only. Adding any non-stdlib dep here breaks the extraction path
# documented in the design doc; enforce via Aqua at the SurrealDB level.

using UUIDs
using Dates

"""
    CBORError(msg)

Raised by SurrealCBOR encode/decode when input is malformed, reserved, or
violates the spec. Not a subtype of `SurrealError` — this module is
substrate-isolated. Transport layer may wrap as a `SerializationError`.
"""
struct CBORError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CBORError) = print(io, "CBORError: ", e.msg)

include("io.jl")
include("registry.jl")
include("codec.jl")
include("tags.jl")

# L3 wire-format types (under cbor/types/, substrate-isolated). Each
# file may also register its tag decoder + define encode methods; some
# (Table) currently ship as type-only and grow CBOR methods alongside
# their Phase 3 tag work.
include("types/none.jl")
include("types/recordid.jl")
include("types/table.jl")
include("types/uuid.jl")
include("types/decimal.jl")
include("types/datetime.jl")
include("types/duration.jl")

export CBORError
export read_head, write_head
export MAJOR_UINT, MAJOR_NINT, MAJOR_BYTES, MAJOR_TEXT,
       MAJOR_ARRAY, MAJOR_MAP, MAJOR_TAG, MAJOR_SIMPLE
export AI_FALSE, AI_TRUE, AI_NULL, AI_UNDEFINED,
       AI_SIMPLE_1B, AI_FLOAT16, AI_FLOAT32, AI_FLOAT64, AI_INDEFINITE
export encode, decode, Tagged, Undefined, undefined
export RecordID, Table, SurrealDecimal, SurrealDateTime, SurrealDuration
export TAG_NONE, TAG_TABLE, TAG_RECORDID, TAG_STRING_UUID, TAG_STRING_DECIMAL,
       TAG_CUSTOM_DATETIME, TAG_STRING_DURATION, TAG_CUSTOM_DURATION,
       TAG_SPEC_DATETIME, TAG_SPEC_UUID, TAG_RANGE, TAG_BOUND_INCLUDED,
       TAG_BOUND_EXCLUDED, TAG_FILE, TAG_SET,
       TAG_GEOMETRY_POINT, TAG_GEOMETRY_LINE, TAG_GEOMETRY_POLYGON,
       TAG_GEOMETRY_MULTIPOINT, TAG_GEOMETRY_MULTILINE,
       TAG_GEOMETRY_MULTIPOLYGON, TAG_GEOMETRY_COLLECTION

end # module
