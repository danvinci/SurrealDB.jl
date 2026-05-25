# SurrealTypes — typed wire-format values for SurrealDB.
#
# Owned here so codec submodules (SurrealCBOR, future JSON-typed) extend
# `encode` (and any other dispatch surface) on these types without piracy.
# Substrate-isolated: no upward deps on SurrealDB.*. Stdlib only.
#
# Section order mirrors `src/cbor/types/*.jl` include order:
#   none, recordid, table, uuid, decimal, datetime, duration, file, set,
#   range, geometry.
#
# Files that wrap stdlib types only (uuid → Base.UUID, set → Base.Set,
# none → Base.Missing) have no struct to move; their CBOR encode/decode
# stays put in src/cbor/types/<name>.jl.

module SurrealTypes

using Dates
using UUIDs

export RecordID, StringRecordID, Table
export SurrealDecimal, SurrealDateTime, SurrealDuration, SurrealFile
export SurrealRange, BoundIncluded, BoundExcluded
export GeometryPoint, GeometryLine, GeometryPolygon,
       GeometryMultiPoint, GeometryMultiLine, GeometryMultiPolygon,
       GeometryCollection

# --- none ---
#
# NONE maps to Julia's `missing`. No custom type — Base.Missing covers it.
# CBOR encode/decode lives in src/cbor/types/none.jl.

# --- recordid ---

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

"""
    StringRecordID(s::AbstractString)

Opaque "raw string record id" wrapper. Holds `s` verbatim and ships it
to the server as a plain CBOR text string for server-side parsing. Use
when the id form is too complex for `RecordID(table, id)` (e.g. nested
objects, ranges, escaped characters) and you want the server's parser
to handle it. Mirrors `StringRecordId` in surrealdb.js / surrealdb.net.

For the common case prefer `RecordID(t, i)` or `rid"t:i"` — those go
through the typed CBOR path and round-trip on decode.

```julia
StringRecordID("users:42")
StringRecordID("posts:⟨2024-01-15, 'ulid'⟩")
```
"""
struct StringRecordID
    value::String
end

Base.string(s::StringRecordID) = s.value
Base.show(io::IO, s::StringRecordID) = print(io, "StringRecordID(\"", s.value, "\")")
Base.:(==)(a::StringRecordID, b::StringRecordID) = a.value == b.value
Base.hash(s::StringRecordID, h::UInt) = hash(s.value, hash(:StringRecordID, h))

# --- table ---

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
Base.:(==)(a::Table, b::Table) = a.name == b.name
Base.hash(t::Table, h::UInt) = hash(t.name, hash(:Table, h))

# --- uuid ---
#
# UUID maps to stdlib `UUIDs.UUID`. No custom type — the wire-format
# Julia type IS the stdlib type. CBOR encode/decode lives in
# src/cbor/types/uuid.jl.

# --- decimal ---

"""
    SurrealDecimal(s::AbstractString)

Wire-format wrapper for SurrealDB's Decimal. Stores the canonical
string form as emitted by the server. Construct from a literal string;
convert to `BigFloat` if arithmetic is needed (note: binary-radix
conversion is approximate).

```julia
SurrealDecimal("3.14159")
SurrealDecimal("-0.5")
BigFloat(SurrealDecimal("1.5"))   # 1.5 — exact in this case
```
"""
struct SurrealDecimal
    value::String
end

Base.string(d::SurrealDecimal) = d.value
Base.show(io::IO, d::SurrealDecimal) = print(io, "SurrealDecimal(\"", d.value, "\")")
Base.:(==)(a::SurrealDecimal, b::SurrealDecimal) = a.value == b.value
Base.hash(d::SurrealDecimal, h::UInt) = hash(d.value, hash(:SurrealDecimal, h))

Base.BigFloat(d::SurrealDecimal) = parse(BigFloat, d.value)

# --- datetime ---

"""
    SurrealDateTime(seconds::Int64, nanos::UInt32)

Wire-format datetime: seconds since the Unix epoch (1970-01-01 UTC) +
sub-second nanoseconds (`0..999_999_999`). UTC; no timezone offset is
stored (wire form always normalizes to UTC).

```julia
SurrealDateTime(1_716_423_296, UInt32(123_456_789))  # 2024-05-22T...
```

Convert to / from `Dates.DateTime`:

```julia
Dates.DateTime(SurrealDateTime(1_716_423_296, UInt32(123_000_000)))
# 2024-05-22T22:54:56.123 — sub-ms portion rounded
SurrealDateTime(Dates.DateTime(2024, 5, 22))
# SurrealDateTime(1716336000, 0x00000000)
```
"""
struct SurrealDateTime
    seconds::Int64
    nanos::UInt32
    function SurrealDateTime(seconds::Integer, nanos::Integer)
        0 <= nanos < 1_000_000_000 || throw(ArgumentError(
            "nanos must be in [0, 1_000_000_000), got $nanos"))
        new(Int64(seconds), UInt32(nanos))
    end
end

Base.:(==)(a::SurrealDateTime, b::SurrealDateTime) =
    a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(d::SurrealDateTime, h::UInt) =
    hash(d.nanos, hash(d.seconds, hash(:SurrealDateTime, h)))

function Base.show(io::IO, d::SurrealDateTime)
    print(io, "SurrealDateTime(", d.seconds, ", 0x",
          string(d.nanos; base=16, pad=8), ")")
end

# Conversion helpers. Stdlib DateTime is ms precision — sub-ms rounds.
const _UNIX_EPOCH = Dates.DateTime(1970, 1, 1)

function Base.convert(::Type{Dates.DateTime}, d::SurrealDateTime)
    ms_extra = round(Int, d.nanos / 1_000_000)
    return _UNIX_EPOCH + Dates.Second(d.seconds) + Dates.Millisecond(ms_extra)
end
Dates.DateTime(d::SurrealDateTime) = convert(Dates.DateTime, d)

function SurrealDateTime(dt::Dates.DateTime)
    ms_since_epoch = Dates.value(dt - _UNIX_EPOCH)
    seconds = fld(ms_since_epoch, 1000)
    nanos = UInt32(mod(ms_since_epoch, 1000) * 1_000_000)
    return SurrealDateTime(seconds, nanos)
end

# --- duration ---

"""
    SurrealDuration(seconds::Integer, nanos::Integer)

Wire-format duration: non-negative seconds + sub-second nanoseconds
(`0..999_999_999`). Server-canonical encode emits the shortest form:

- `(0, 0)`        → empty array
- `(s, 0)`        → `[s]`
- `(s, ns)`       → `[s, ns]`

```julia
SurrealDuration(0, 0)              # zero
SurrealDuration(3600, 0)           # 1h
SurrealDuration(0, 500_000_000)    # 0.5s
SurrealDuration(3600, 500_000_000) # 1h 0.5s
```
"""
struct SurrealDuration
    seconds::UInt64
    nanos::UInt32
    function SurrealDuration(seconds::Integer, nanos::Integer)
        seconds >= 0 || throw(ArgumentError(
            "seconds must be non-negative, got $seconds"))
        0 <= nanos < 1_000_000_000 || throw(ArgumentError(
            "nanos must be in [0, 1_000_000_000), got $nanos"))
        new(UInt64(seconds), UInt32(nanos))
    end
end

Base.:(==)(a::SurrealDuration, b::SurrealDuration) =
    a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(d::SurrealDuration, h::UInt) =
    hash(d.nanos, hash(d.seconds, hash(:SurrealDuration, h)))

function Base.show(io::IO, d::SurrealDuration)
    print(io, "SurrealDuration(", d.seconds, ", ", d.nanos, ")")
end

# --- file ---

"""
    SurrealFile(bucket::AbstractString, key::AbstractString)

Reference to a file in a SurrealDB-managed bucket. Both `bucket` and
`key` are opaque strings; SDK doesn't validate path syntax.

```julia
SurrealFile("avatars", "user_42/profile.png")
```
"""
struct SurrealFile
    bucket::String
    key::String
    SurrealFile(bucket::AbstractString, key::AbstractString) =
        new(String(bucket), String(key))
end

Base.:(==)(a::SurrealFile, b::SurrealFile) = a.bucket == b.bucket && a.key == b.key
Base.hash(f::SurrealFile, h::UInt) =
    hash(f.key, hash(f.bucket, hash(:SurrealFile, h)))

function Base.show(io::IO, f::SurrealFile)
    print(io, "SurrealFile(\"", f.bucket, "\", \"", f.key, "\")")
end

# --- set ---
#
# Set maps to Julia's `Set`. No custom type. CBOR encode/decode lives
# in src/cbor/types/set.jl.

# --- range ---

"""
    BoundIncluded(value)

Inclusive range bound (`[value, ...`). The wrapped value is any
serializable Julia value.
"""
struct BoundIncluded
    value::Any
end

"""
    BoundExcluded(value)

Exclusive range bound (`(value, ...`). The wrapped value is any
serializable Julia value.
"""
struct BoundExcluded
    value::Any
end

Base.:(==)(a::BoundIncluded, b::BoundIncluded) = a.value == b.value
Base.:(==)(a::BoundExcluded, b::BoundExcluded) = a.value == b.value
Base.hash(b::BoundIncluded, h::UInt) = hash(b.value, hash(:BoundIncluded, h))
Base.hash(b::BoundExcluded, h::UInt) = hash(b.value, hash(:BoundExcluded, h))

Base.show(io::IO, b::BoundIncluded) = print(io, "BoundIncluded(", b.value, ")")
Base.show(io::IO, b::BoundExcluded) = print(io, "BoundExcluded(", b.value, ")")

"""
    SurrealRange(start, stop)

Half-open or fully-bounded range. Each of `start` / `stop` is one of:

- [`BoundIncluded`](@ref) — inclusive bound
- [`BoundExcluded`](@ref) — exclusive bound
- `nothing` — unbounded side

```julia
SurrealRange(BoundIncluded(1), BoundExcluded(10))   # [1, 10)
SurrealRange(BoundIncluded(1), nothing)             # [1, ∞)
SurrealRange(nothing, BoundExcluded(0))             # (-∞, 0)
```
"""
struct SurrealRange
    start::Any
    stop::Any
    function SurrealRange(start, stop)
        _validate_bound(start, "start")
        _validate_bound(stop, "stop")
        new(start, stop)
    end
end

function _validate_bound(b, name)
    isnothing(b) || b isa BoundIncluded || b isa BoundExcluded || throw(ArgumentError(
        "SurrealRange $name must be BoundIncluded, BoundExcluded, or nothing; got $(typeof(b))"))
end

Base.:(==)(a::SurrealRange, b::SurrealRange) =
    a.start == b.start && a.stop == b.stop
Base.hash(r::SurrealRange, h::UInt) =
    hash(r.stop, hash(r.start, hash(:SurrealRange, h)))

function Base.show(io::IO, r::SurrealRange)
    print(io, "SurrealRange(", r.start, ", ", r.stop, ")")
end

# --- geometry ---

"""
    GeometryPoint(x::Real, y::Real)

2D point in lon/lat (or x/y) order. Both coordinates stored as
`Float64` — matches server's `f64` payload.
"""
struct GeometryPoint
    x::Float64
    y::Float64
    GeometryPoint(x::Real, y::Real) = new(Float64(x), Float64(y))
end

"""
    GeometryLine(points::Vector{GeometryPoint})

Open or closed line — array of points. SurrealDB doesn't enforce
minimum length here; an empty `Line` is technically representable
though semantically rare.
"""
struct GeometryLine
    points::Vector{GeometryPoint}
end

"""
    GeometryPolygon(exterior::GeometryLine, interiors::Vector{GeometryLine}=GeometryLine[])

Polygon with one outer ring and zero or more inner holes. Server requires
non-empty (at least one exterior).
"""
struct GeometryPolygon
    exterior::GeometryLine
    interiors::Vector{GeometryLine}
    GeometryPolygon(exterior::GeometryLine, interiors::Vector{GeometryLine}=GeometryLine[]) =
        new(exterior, interiors)
end

"""
    GeometryMultiPoint(points::Vector{GeometryPoint})

Collection of independent points.
"""
struct GeometryMultiPoint
    points::Vector{GeometryPoint}
end

"""
    GeometryMultiLine(lines::Vector{GeometryLine})

Collection of independent lines.
"""
struct GeometryMultiLine
    lines::Vector{GeometryLine}
end

"""
    GeometryMultiPolygon(polygons::Vector{GeometryPolygon})

Collection of independent polygons.
"""
struct GeometryMultiPolygon
    polygons::Vector{GeometryPolygon}
end

"""
    GeometryCollection(geometries::Vector{Any})

Heterogeneous collection — any mix of the Geometry types above.
Stored as `Vector{Any}` since the elements may differ per index.
"""
struct GeometryCollection
    geometries::Vector{Any}
    GeometryCollection(gs::AbstractVector) = new(Vector{Any}(gs))
end

# Equality + hash via field-wise comparison (Julia immutables already do
# this for ==; we override hash to be deterministic across sessions).
for T in (:GeometryPoint, :GeometryLine, :GeometryPolygon,
          :GeometryMultiPoint, :GeometryMultiLine,
          :GeometryMultiPolygon, :GeometryCollection)
    @eval Base.:(==)(a::$T, b::$T) =
        all(getfield(a, f) == getfield(b, f) for f in fieldnames($T))
    @eval function Base.hash(g::$T, h::UInt)
        for f in fieldnames($T)
            h = hash(getfield(g, f), h)
        end
        return hash($(QuoteNode(T)), h)
    end
end

end # module SurrealTypes
