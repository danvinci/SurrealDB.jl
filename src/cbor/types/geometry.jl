# L3 — Geometry hierarchy (tags 88-94).
#
# Seven types sharing a recursive wire shape: each tag wraps an array of
# the next-level-down tag. Polygon is the exception — its array's first
# element is the exterior ring; the rest are interior holes.
#
# Ref: convert.rs:194-336 (decode), 457-509 (encode).
#
# Wire shapes:
#   Tag(88) Point        — [f64 x, f64 y]
#   Tag(89) Line         — array of Tag(88) (>= 2 elements, conventionally)
#   Tag(90) Polygon      — non-empty array of Tag(89); [0] exterior, [1..] interiors
#   Tag(91) MultiPoint   — array of Tag(88)
#   Tag(92) MultiLine    — array of Tag(89)
#   Tag(93) MultiPolygon — array of Tag(90)
#   Tag(94) Collection   — array of any Geometry tag

# ─── Types ──────────────────────────────────────────────────────────────

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

const _AnyGeometry = Union{GeometryPoint, GeometryLine, GeometryPolygon,
                           GeometryMultiPoint, GeometryMultiLine,
                           GeometryMultiPolygon, GeometryCollection}

_is_geometry(g) = g isa _AnyGeometry

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

# ─── Encode ─────────────────────────────────────────────────────────────

function encode(io::IO, p::GeometryPoint)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_POINT)
    return n + encode(io, Any[p.x, p.y])
end

function encode(io::IO, l::GeometryLine)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_LINE)
    return n + encode(io, l.points)
end

function encode(io::IO, poly::GeometryPolygon)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_POLYGON)
    rings = GeometryLine[poly.exterior; poly.interiors]
    return n + encode(io, rings)
end

function encode(io::IO, mp::GeometryMultiPoint)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_MULTIPOINT)
    return n + encode(io, mp.points)
end

function encode(io::IO, ml::GeometryMultiLine)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_MULTILINE)
    return n + encode(io, ml.lines)
end

function encode(io::IO, mp::GeometryMultiPolygon)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_MULTIPOLYGON)
    return n + encode(io, mp.polygons)
end

function encode(io::IO, gc::GeometryCollection)
    n = write_head(io, MAJOR_TAG, TAG_GEOMETRY_COLLECTION)
    return n + encode(io, gc.geometries)
end

# ─── Decode ─────────────────────────────────────────────────────────────

# Helper: assert payload is a Vector of the expected geometry tag.
function _check_geom_array(payload, expected_T, tag_label)
    payload isa AbstractVector || throw(CBORError(
        "$tag_label payload must be array; got $(typeof(payload))"))
    for (i, g) in enumerate(payload)
        g isa expected_T || throw(CBORError(
            "$tag_label[$i] must be $expected_T; got $(typeof(g))"))
    end
    return payload
end

function _decode_point(payload)
    payload isa AbstractVector && length(payload) == 2 || throw(CBORError(
        "TAG_GEOMETRY_POINT (88) payload must be 2-element array; got $(typeof(payload))"))
    x = payload[1]
    y = payload[2]
    (x isa Real && y isa Real) || throw(CBORError(
        "TAG_GEOMETRY_POINT (88) coords must be numeric; got ($(typeof(x)), $(typeof(y)))"))
    return GeometryPoint(x, y)
end

function _decode_line(payload)
    points = _check_geom_array(payload, GeometryPoint, "TAG_GEOMETRY_LINE (89)")
    return GeometryLine(Vector{GeometryPoint}(points))
end

function _decode_polygon(payload)
    lines = _check_geom_array(payload, GeometryLine, "TAG_GEOMETRY_POLYGON (90)")
    isempty(lines) && throw(CBORError(
        "TAG_GEOMETRY_POLYGON (90) array must be non-empty (>=1 exterior ring)"))
    return GeometryPolygon(lines[1], Vector{GeometryLine}(lines[2:end]))
end

function _decode_multipoint(payload)
    points = _check_geom_array(payload, GeometryPoint, "TAG_GEOMETRY_MULTIPOINT (91)")
    return GeometryMultiPoint(Vector{GeometryPoint}(points))
end

function _decode_multiline(payload)
    lines = _check_geom_array(payload, GeometryLine, "TAG_GEOMETRY_MULTILINE (92)")
    return GeometryMultiLine(Vector{GeometryLine}(lines))
end

function _decode_multipolygon(payload)
    polys = _check_geom_array(payload, GeometryPolygon, "TAG_GEOMETRY_MULTIPOLYGON (93)")
    return GeometryMultiPolygon(Vector{GeometryPolygon}(polys))
end

function _decode_collection(payload)
    payload isa AbstractVector || throw(CBORError(
        "TAG_GEOMETRY_COLLECTION (94) payload must be array; got $(typeof(payload))"))
    for (i, g) in enumerate(payload)
        _is_geometry(g) || throw(CBORError(
            "TAG_GEOMETRY_COLLECTION (94)[$i] must be a Geometry*; got $(typeof(g))"))
    end
    return GeometryCollection(payload)
end

_register_tag!(TAG_GEOMETRY_POINT,        _decode_point)
_register_tag!(TAG_GEOMETRY_LINE,         _decode_line)
_register_tag!(TAG_GEOMETRY_POLYGON,      _decode_polygon)
_register_tag!(TAG_GEOMETRY_MULTIPOINT,   _decode_multipoint)
_register_tag!(TAG_GEOMETRY_MULTILINE,    _decode_multiline)
_register_tag!(TAG_GEOMETRY_MULTIPOLYGON, _decode_multipolygon)
_register_tag!(TAG_GEOMETRY_COLLECTION,   _decode_collection)
