# C-compatible type mirrors for libsurreal FFI
# Internal use only — not exported as public API

# --- C numeric type (mirrors sr_number_t) ---

@enum CNumberTag::UInt32 begin
    C_NUMBER_INT
    C_NUMBER_FLOAT
    C_NUMBER_DECIMAL
end

Base.@kwdef mutable struct CNumber
    tag::CNumberTag
    int_val::Int64
    float_val::Float64
    decimal_val::String
end

# --- C geometry types (mirrors sr_sr_geometry etc.) ---

@enum CGeometryTag::UInt32 begin
    C_GEOM_POINT
    C_GEOM_LINESTRING
    C_GEOM_POLYGON
    C_GEOM_MULTIPOINT
    C_GEOM_MULTILINE
    C_GEOM_MULTIPOLYGON
    C_GEOM_COLLECTION
    C_GEOM_UNIMPLEMENTED
end

# --- C value tag (mirrors sr_value_t_Tag) ---

@enum CValueTag::UInt32 begin
    C_VALUE_NONE
    C_VALUE_NULL
    C_VALUE_BOOL
    C_VALUE_NUMBER
    C_VALUE_STRAND
    C_VALUE_DURATION
    C_VALUE_DATETIME
    C_VALUE_UUID
    C_VALUE_ARRAY
    C_VALUE_OBJECT
    C_VALUE_GEOMETRY
    C_VALUE_BYTES
    C_VALUE_THING
end

# --- Auth scopes (mirrors sr_credentials_scope) ---

@enum CScope::Cint begin
    C_SCOPE_ROOT = 0
    C_SCOPE_NAMESPACE = 1
    C_SCOPE_DATABASE = 2
    C_SCOPE_RECORD = 3
end

# --- Action type for live notifications (mirrors sr_action) ---

@enum CAction::UInt32 begin
    C_ACTION_CREATE
    C_ACTION_UPDATE
    C_ACTION_DELETE
    C_ACTION_KILLED
    C_ACTION_UNIMPLEMENTED
end

# ===================================================================
# SurrealValue <-> bare Julia value conversion
# ===================================================================

"""
    julia_to_surreal_value(val::Any)::SurrealValue

Convert a plain Julia value to the internal [`SurrealValue`](@ref) tagged union.

| Julia type                      | SurrealValueKind |
|---------------------------------|------------------|
| `nothing`                       | `SR_NONE`        |
| `missing`                       | `SR_NULL`        |
| `Bool`                          | `SR_BOOL`        |
| `Integer`                       | `SR_INT`         |
| `AbstractFloat`                 | `SR_FLOAT`       |
| `String`                        | `SR_STRING`      |
| `DateTime`                      | `SR_DATETIME`    |
| `UUID`                          | `SR_UUID`       |
| `AbstractDict`                  | `SR_OBJECT`      |
| `Vector{UInt8}`                 | `SR_BYTES`       |
| `Vector`                        | `SR_ARRAY`       |
| [`RecordID`](@ref)              | `SR_THING`       |
"""
function julia_to_surreal_value(val::Any)::SurrealValue
    if val === nothing
        return SurrealValue(SR_NONE, nothing)
    elseif val === missing
        return SurrealValue(SR_NULL, nothing)
    elseif val isa Bool
        return SurrealValue(SR_BOOL, val)
    elseif val isa Integer
        return SurrealValue(SR_INT, Int64(val))
    elseif val isa AbstractFloat
        return SurrealValue(SR_FLOAT, Float64(val))
    elseif val isa String
        return SurrealValue(SR_STRING, val)
    elseif val isa DateTime
        return SurrealValue(SR_DATETIME, val)
    elseif val isa UUIDs.UUID
        return SurrealValue(SR_UUID, val)
    elseif val isa AbstractDict
        return SurrealValue(SR_OBJECT, Dict{String, Any}((string(k) => v for (k, v) in val)))
    elseif val isa Vector{UInt8}
        return SurrealValue(SR_BYTES, val)
    elseif val isa AbstractVector
        return SurrealValue(SR_ARRAY, collect(Any, val))
    elseif val isa RecordID
        return SurrealValue(SR_THING, val)
    else
        throw(EmbeddedFFIError("julia_to_surreal_value", "Cannot convert $(typeof(val)) to SurrealValue"))
    end
end

"""
    surreal_value_to_julia(sv::SurrealValue)::Any

Unwrap a [`SurrealValue`](@ref) tagged union back to a plain Julia value.

| SurrealValueKind | Julia type              |
|------------------|-------------------------|
| `SR_NONE`        | `nothing`               |
| `SR_NULL`        | `missing`               |
| `SR_BOOL`        | `Bool`                  |
| `SR_INT`         | `Int64`                 |
| `SR_FLOAT`       | `Float64`              |
| `SR_DECIMAL`     | `String`                |
| `SR_STRING`      | `String`                |
| `SR_DATETIME`    | `DateTime`              |
| `SR_DURATION`    | `String`                |
| `SR_UUID`        | `UUID`                 |
| `SR_ARRAY`       | `Vector{Any}`           |
| `SR_OBJECT`      | `Dict{String, Any}`     |
| `SR_BYTES`       | `Vector{UInt8}`         |
| `SR_THING`       | [`RecordID`](@ref)      |
| `SR_GEOMETRY`    | passed through as-is    |
"""
function surreal_value_to_julia(sv::SurrealValue)::Any
    kind = sv.kind
    val = sv.value
    if kind == SR_NONE
        return nothing
    elseif kind == SR_NULL
        return missing
    elseif kind == SR_BOOL
        return Bool(val)
    elseif kind == SR_INT
        return Int64(val)
    elseif kind == SR_FLOAT
        return Float64(val)
    elseif kind == SR_DECIMAL
        return String(val)
    elseif kind == SR_STRING
        return String(val)
    elseif kind == SR_DATETIME
        return DateTime(val)
    elseif kind == SR_DURATION
        return String(val)
    elseif kind == SR_UUID
        return UUIDs.UUID(val)
    elseif kind == SR_ARRAY
        return Vector{Any}(val)
    elseif kind == SR_OBJECT
        return Dict{String, Any}(val)
    elseif kind == SR_BYTES
        return Vector{UInt8}(val)
    elseif kind == SR_THING
        return val::RecordID
    elseif kind == SR_GEOMETRY
        return val
    else
        throw(EmbeddedFFIError("surreal_value_to_julia", "Unknown SurrealValueKind: $kind"))
    end
end

# ===================================================================
# Julia value <-> C sr_value_t conversion
# ===================================================================

"""
    julia_to_c_value(val::Any)::Any

Convert a Julia value to a C-compatible representation suitable for passing
to `ccall` as a `sr_value_t*` parameter. Returns a [`NamedTuple`](@ref)
whose `tag` field is a [`CValueTag`](@ref) and whose remaining fields mirror
the active variant of the C tagged union.

| Julia type                      | CValueTag           |
|---------------------------------|---------------------|
| `nothing`                       | `C_VALUE_NONE`      |
| `missing`                       | `C_VALUE_NULL`      |
| `Bool`                          | `C_VALUE_BOOL`      |
| `Integer`                       | `C_VALUE_NUMBER` (`C_NUMBER_INT`)    |
| `AbstractFloat`                 | `C_VALUE_NUMBER` (`C_NUMBER_FLOAT`)  |
| `String` (datetime-like)        | `C_VALUE_DATETIME`  |
| `String`                        | `C_VALUE_STRAND`    |
| `DateTime`                      | `C_VALUE_DATETIME`  |
| `UUID`                          | `C_VALUE_UUID`     |
| `Dict{String, Any}`             | `C_VALUE_OBJECT`    |
| `Vector{UInt8}`                 | `C_VALUE_BYTES`     |
| `AbstractVector`                | `C_VALUE_ARRAY`     |
| [`RecordID`](@ref)              | `C_VALUE_THING`     |

Recursive structures (arrays, objects, Things) embed child
`julia_to_c_value` results directly rather than allocating native
`sr_value_t` structs.
"""
function julia_to_c_value(val::Any)::Any
    sv = julia_to_surreal_value(val)
    kind = sv.kind
    v = sv.value

    if kind == SR_NONE
        return (tag = C_VALUE_NONE,)
    elseif kind == SR_NULL
        return (tag = C_VALUE_NULL,)
    elseif kind == SR_BOOL
        return (tag = C_VALUE_BOOL, value = v)
    elseif kind == SR_INT
        return (tag = C_VALUE_NUMBER,
                number = CNumber(tag = C_NUMBER_INT, int_val = Int64(v),
                                 float_val = 0.0, decimal_val = ""))
    elseif kind == SR_FLOAT
        return (tag = C_VALUE_NUMBER,
                number = CNumber(tag = C_NUMBER_FLOAT, int_val = 0,
                                 float_val = Float64(v), decimal_val = ""))
    elseif kind == SR_DECIMAL
        return (tag = C_VALUE_NUMBER,
                number = CNumber(tag = C_NUMBER_DECIMAL, int_val = 0,
                                 float_val = 0.0, decimal_val = String(v)))
    elseif kind == SR_STRING
        s = String(v)
        if _looks_like_datetime(s)
            return (tag = C_VALUE_DATETIME, value = s)
        end
        return (tag = C_VALUE_STRAND, value = s)
    elseif kind == SR_DATETIME
        return (tag = C_VALUE_DATETIME, value = v)
    elseif kind == SR_DURATION
        return (tag = C_VALUE_DURATION, value = String(v))
    elseif kind == SR_UUID
        return (tag = C_VALUE_UUID, value = v)
    elseif kind == SR_ARRAY
        return (tag = C_VALUE_ARRAY,
                elements = [julia_to_c_value(x) for x in v])
    elseif kind == SR_OBJECT
        return (tag = C_VALUE_OBJECT,
                fields = Dict{String, Any}(k => julia_to_c_value(x) for (k, x) in v))
    elseif kind == SR_BYTES
        return (tag = C_VALUE_BYTES, value = v)
    elseif kind == SR_THING
        rid = v::RecordID
        return (tag = C_VALUE_THING, table = rid.table, id = julia_to_c_value(rid.id))
    elseif kind == SR_GEOMETRY
        return (tag = C_VALUE_GEOMETRY, value = v)
    else
        throw(EmbeddedFFIError("julia_to_c_value", "Unknown SurrealValueKind: $kind"))
    end
end

"""
    _looks_like_datetime(s::String)::Bool

Heuristic: returns true if `s` matches an ISO-8601 datetime pattern
(e.g. `"2024-01-15T10:30:00Z"`).
"""
function _looks_like_datetime(s::String)::Bool
    if length(s) < 19
        return false
    end
    c = codeunits(s)
    return (c[5] == UInt8('-') && c[8] == UInt8('-') && c[11] == UInt8('T') &&
            c[14] == UInt8(':') && c[17] == UInt8(':'))
end

"""
    c_value_to_julia(tag::CValueTag, data::Ptr{Cvoid})::Any

Convert a C `sr_value_t` (represented by a [`CValueTag`](@ref) enum +
opaque data pointer) back to a Julia value.

Pointer-bearing variants require libsurreal to be loaded; direct-pass options
(`C_VALUE_NONE`, `C_VALUE_NULL`) return immediately without touching the
pointer.

| CValueTag          | Return type                              |
|--------------------|------------------------------------------|
| `C_VALUE_NONE`     | `nothing`                                |
| `C_VALUE_NULL`     | `missing`                                |
| `C_VALUE_BOOL`     | `Bool`                                   |
| `C_VALUE_NUMBER`   | `Union{Int64, Float64, String}`          |
| `C_VALUE_STRAND`   | `String`                                 |
| `C_VALUE_DURATION` | `String`                                 |
| `C_VALUE_DATETIME` | `DateTime`                               |
| `C_VALUE_UUID`     | `UUID`                                   |
| `C_VALUE_ARRAY`    | `Vector{Any}`                            |
| `C_VALUE_OBJECT`   | `Dict{String, Any}`                      |
| `C_VALUE_BYTES`    | `Vector{UInt8}`                          |
| `C_VALUE_THING`    | [`RecordID`](@ref)                       |
| `C_VALUE_GEOMETRY` | Geometry struct                          |
"""
function c_value_to_julia(tag::CValueTag, data::Ptr{Cvoid})::Any
    err = "c_value_to_julia: Cannot deserialize from opaque pointer without libsurreal loaded. Install a compatible surrealdb native library and call `libsurreal_load!(path)`."

    if tag == C_VALUE_NONE
        return nothing
    elseif tag == C_VALUE_NULL
        return missing
    elseif tag == C_VALUE_BOOL
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_NUMBER
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_STRAND
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_DURATION
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_DATETIME
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_UUID
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_ARRAY
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_OBJECT
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_GEOMETRY
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_BYTES
        throw(EmbeddedFFIError("c_value_to_julia", err))
    elseif tag == C_VALUE_THING
        throw(EmbeddedFFIError("c_value_to_julia", err))
    else
        throw(EmbeddedFFIError("c_value_to_julia", "Unknown CValueTag: $tag"))
    end
end

# ===================================================================
# Public C-compatible type mirrors (for use in FFI)
# ===================================================================

"""
    SurrealThing

Mirrors SurrealDB's `sr_thing_t` — a record ID (table + id).
Equivalent to `RecordID` but named to match the C API convention.
"""
const SurrealThing = RecordID
