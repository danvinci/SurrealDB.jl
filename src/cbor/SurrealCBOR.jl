# SurrealCBOR — SurrealDB-flavored CBOR (RFC 8949) codec.
#
# Internal submodule of SurrealDB.jl. Stdlib only, plus sibling SurrealTypes
# for wire-format type definitions. No deps on transport / methods /
# connection layers — extraction path: SurrealTypes + SurrealCBOR as two
# packages, CBOR depending on Types.
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

# Sibling SurrealTypes: typed wire-format values whose encode methods
# this module extends. SurrealTypes itself has no upward deps.
using ..SurrealTypes: RecordID, Table,
    SurrealDecimal, SurrealDateTime, SurrealDuration, SurrealFile,
    SurrealRange, BoundIncluded, BoundExcluded,
    GeometryPoint, GeometryLine, GeometryPolygon,
    GeometryMultiPoint, GeometryMultiLine, GeometryMultiPolygon,
    GeometryCollection

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

# L3 tag handlers. Each file extends `encode` on the matching SurrealTypes
# struct (imported above), defines its `_decode_<thing>` helper, and calls
# `_register_tag!` to wire it into the decoder dispatch table. Struct
# definitions + Base.* overloads live in ../types/SurrealTypes.jl.
include("types/none.jl")
include("types/recordid.jl")
include("types/table.jl")
include("types/uuid.jl")
include("types/decimal.jl")
include("types/datetime.jl")
include("types/duration.jl")
include("types/file.jl")
include("types/set.jl")
include("types/range.jl")
include("types/geometry.jl")

export CBORError
export read_head, write_head
export MAJOR_UINT, MAJOR_NINT, MAJOR_BYTES, MAJOR_TEXT,
       MAJOR_ARRAY, MAJOR_MAP, MAJOR_TAG, MAJOR_SIMPLE
export AI_FALSE, AI_TRUE, AI_NULL, AI_UNDEFINED,
       AI_SIMPLE_1B, AI_FLOAT16, AI_FLOAT32, AI_FLOAT64, AI_INDEFINITE
export encode, decode, Tagged, Undefined, undefined
export TAG_NONE, TAG_TABLE, TAG_RECORDID, TAG_STRING_UUID, TAG_STRING_DECIMAL,
       TAG_CUSTOM_DATETIME, TAG_STRING_DURATION, TAG_CUSTOM_DURATION,
       TAG_SPEC_DATETIME, TAG_SPEC_UUID, TAG_RANGE, TAG_BOUND_INCLUDED,
       TAG_BOUND_EXCLUDED, TAG_FILE, TAG_SET,
       TAG_GEOMETRY_POINT, TAG_GEOMETRY_LINE, TAG_GEOMETRY_POLYGON,
       TAG_GEOMETRY_MULTIPOINT, TAG_GEOMETRY_MULTILINE,
       TAG_GEOMETRY_MULTIPOLYGON, TAG_GEOMETRY_COLLECTION

end # module
