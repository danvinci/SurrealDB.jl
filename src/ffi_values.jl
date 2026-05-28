# FFI bridge value types for SurrealDB.jl

# SurrealValueKind and SurrealValue are the tagged union used at the embedded
# FFI boundary (libsurreal C interface). They are not wire-format types —
# those live in surreal_types.jl. Nothing outside the Embedded submodule
# constructs these directly; the codec layer owns the conversions.

# --- SurrealValue ---

@enum SurrealValueKind begin
    SR_NONE
    SR_NULL
    SR_BOOL
    SR_INT
    SR_FLOAT
    SR_DECIMAL
    SR_STRING
    SR_DATETIME
    SR_DURATION
    SR_UUID
    SR_ARRAY
    SR_OBJECT
    SR_BYTES
    SR_THING
    SR_GEOMETRY
end

"""
    SurrealValue(kind::SurrealValueKind, value)

A tagged union representing any SurrealDB value type. Used internally for
precision type handling when mapping to/from C FFI types in embedded mode.

Most users never construct one directly — `query` / `select` / etc. handle
the conversions automatically.
"""
struct SurrealValue
    kind::SurrealValueKind
    value::Any
end
