# Wire-format codec dispatch — single seam between transport layers and the
# JSON / CBOR encoders. Transport code (`transport_ws.jl`, `transport_http.jl`)
# calls `_wire_encode` / `_wire_decode` and stays codec-agnostic. Dispatch is
# on the `W` type parameter of `RemoteConnection{P, W}`, so the path is
# resolved at compile time — no `if conn.wire == :cbor` runtime branches.
#
# JSON path returns/accepts `String` payloads; CBOR path returns/accepts
# `Vector{UInt8}`. Both `HTTP.WebSockets.send` and `HTTP.post` infer the
# WebSocket frame type / HTTP body type from this Julia type, so callers just
# pass the payload through unchanged.

# --- Wire-typed channel factory ---
#
# WS writer drains a `Channel` whose element type matches the wire payload:
# `Channel{String}` for JSON, `Channel{Vector{UInt8}}` for CBOR. Concrete
# element types let `HTTP.WebSockets.send` pick TEXT vs BINARY frames
# without runtime branching.
_new_write_channel(::Val{:json}) = Channel{String}(32)
_new_write_channel(::Val{:cbor}) = Channel{Vector{UInt8}}(32)

# Connection-typed convenience: lift the wire param so callers say
# `_new_write_channel(conn)` instead of `_new_write_channel(Val(_wire(conn)))`.
_new_write_channel(::RemoteConnection{P, W}) where {P, W} = _new_write_channel(Val(W))

# Wire-format introspection: pull `W` back out of a typed connection.
_wire(::RemoteConnection{P, W}) where {P, W} = W

# --- Encode ---

"""
    _wire_encode(conn, msg) -> Union{String, Vector{UInt8}}

Encode a Julia RPC envelope (`Dict{String, Any}`) for transmission. JSON
returns a UTF-8 `String`; CBOR returns canonical bytes via `SurrealCBOR.encode`.
"""
_wire_encode(::RemoteConnection{P, :json}, msg) where {P} = JSON.json(msg)

function _wire_encode(::RemoteConnection{P, :cbor}, msg) where {P}
    try
        return SurrealCBOR.encode(msg)
    catch e
        e isa SurrealCBOR.CBORError || rethrow()
        throw(SerializationError("CBOR encode failed: $(e.msg)"))
    end
end

# --- Decode ---

"""
    _wire_decode(conn, raw) -> Any

Decode a wire payload into a Julia value (typically `Dict{String, Any}` for
RPC envelopes). JSON path accepts `String` or `Vector{UInt8}` (UTF-8); CBOR
accepts `Vector{UInt8}` (or `String`, coerced via `codeunits`).
"""
function _wire_decode(::RemoteConnection{P, :json}, raw) where {P}
    s = raw isa String ? raw : String(raw)
    return JSON.parse(s)
end

function _wire_decode(::RemoteConnection{P, :cbor}, raw) where {P}
    bytes = raw isa AbstractVector{UInt8} ? raw : Vector{UInt8}(codeunits(raw))
    try
        return SurrealCBOR.decode(bytes)
    catch e
        e isa SurrealCBOR.CBORError || rethrow()
        throw(SerializationError("CBOR decode failed: $(e.msg)"; is_deserialization=true))
    end
end

# --- Wire-format introspection ---

"""
    _wire_subprotocol(conn) -> String

WebSocket `Sec-WebSocket-Protocol` value for this wire format. Sent in the
upgrade request; server echoes back the selected subprotocol.
"""
_wire_subprotocol(::RemoteConnection{P, :json}) where {P} = "json"
_wire_subprotocol(::RemoteConnection{P, :cbor}) where {P} = "cbor"

"""
    _wire_content_type(conn) -> String

HTTP `Content-Type` / `Accept` value for this wire format.
"""
_wire_content_type(::RemoteConnection{P, :json}) where {P} = "application/json"
_wire_content_type(::RemoteConnection{P, :cbor}) where {P} = "application/cbor"

# --- JSON.lower hooks for typed Surreal values ---
#
# JSON has no Tag mechanism, so typed values must serialize to canonical
# wire shapes the server understands natively:
#
#   RecordID / Table  → bare strings ("user:alice", "user")
#   SurrealDecimal    → numeric string ("123.45") — preserves precision
#   SurrealDateTime   → ISO 8601 with nanosecond fractional seconds
#   SurrealDuration   → SurrealQL compact form ("1h30m500ns")
#   SurrealFile       → "bucket:key"
#   Geometry*         → GeoJSON object — universally accepted
#   SurrealRange      → {start, stop} object with inclusivity markers
#   Bound{In,Ex}clud  → {value, inclusive} object
#
# Lives at the wire seam, not in `cbor/types/`, because `cbor/` is
# substrate-isolated (no JSON dep). These lowers make `JSON.json(x)`
# correct wherever a typed value lands in a user payload — methods.jl
# passes typed values through untouched, the CBOR encoder gets full Tag
# fidelity via `encode(io, ::T)`, and the JSON wire gets the canonical
# string / GeoJSON shape via these hooks.
#
# JSON wire is fundamentally lossy on the timestamp / duration / decimal
# types (no type discriminator); the lowers emit the most faithful
# string representation. `wire=:cbor` is the lossless path.

JSON.lower(r::RecordID) = string(r)
JSON.lower(t::Table) = t.name

JSON.lower(d::SurrealDecimal) = d.value

# ISO 8601 with 9-digit fractional seconds. UTC; SurrealDB stores all
# datetimes in UTC and emits with a `Z` suffix on the JSON wire.
function JSON.lower(dt::SurrealDateTime)
    base = Dates.unix2datetime(dt.seconds)  # second precision
    head = Dates.format(base, "yyyy-mm-ddTHH:MM:SS")
    return string(head, ".", lpad(string(dt.nanos), 9, '0'), "Z")
end

# SurrealQL compact duration form: `<n>s<n>ns` covers all values losslessly.
# Empty duration emits `"0ns"` rather than `""` so server parses unambiguously.
function JSON.lower(d::SurrealDuration)
    if d.seconds == 0 && d.nanos == 0
        return "0ns"
    elseif d.nanos == 0
        return string(d.seconds, "s")
    elseif d.seconds == 0
        return string(d.nanos, "ns")
    else
        return string(d.seconds, "s", d.nanos, "ns")
    end
end

JSON.lower(f::SurrealFile) = string(f.bucket, ":", f.key)

# --- Geometry: GeoJSON shapes (RFC 7946) ---
#
# GeoJSON is the lingua franca; SurrealDB accepts it on the JSON wire.
# Coordinates are nested arrays — `_geojson_coords` rebuilds them from
# the typed geometry hierarchy without leaking nested `GeometryPoint`
# structs into the JSON output.

_geojson_coords(p::GeometryPoint) = [p.x, p.y]
_geojson_coords(l::GeometryLine) = [_geojson_coords(p) for p in l.points]
_geojson_coords(p::GeometryPolygon) =
    pushfirst!([_geojson_coords(r) for r in p.interiors], _geojson_coords(p.exterior))
_geojson_coords(mp::GeometryMultiPoint) = [_geojson_coords(p) for p in mp.points]
_geojson_coords(ml::GeometryMultiLine) = [_geojson_coords(l) for l in ml.lines]
_geojson_coords(mpg::GeometryMultiPolygon) = [_geojson_coords(p) for p in mpg.polygons]

JSON.lower(p::GeometryPoint)         = Dict("type" => "Point",           "coordinates" => _geojson_coords(p))
JSON.lower(l::GeometryLine)          = Dict("type" => "LineString",      "coordinates" => _geojson_coords(l))
JSON.lower(p::GeometryPolygon)       = Dict("type" => "Polygon",         "coordinates" => _geojson_coords(p))
JSON.lower(mp::GeometryMultiPoint)   = Dict("type" => "MultiPoint",      "coordinates" => _geojson_coords(mp))
JSON.lower(ml::GeometryMultiLine)    = Dict("type" => "MultiLineString", "coordinates" => _geojson_coords(ml))
JSON.lower(mpg::GeometryMultiPolygon)= Dict("type" => "MultiPolygon",    "coordinates" => _geojson_coords(mpg))
# GeometryCollection nests heterogeneous geoms; each gets lowered recursively
# when JSON.json walks the geometries vector.
JSON.lower(gc::GeometryCollection)   = Dict("type" => "GeometryCollection", "geometries" => gc.geometries)

# --- Range + bounds ---
#
# JSON has no native half-open range concept. Emit a structured object
# with explicit inclusivity flags so the server (or a peer SDK) can
# reconstruct the semantics. Unbounded sides land as JSON null.
JSON.lower(b::BoundIncluded) = Dict("value" => b.value, "inclusive" => true)
JSON.lower(b::BoundExcluded) = Dict("value" => b.value, "inclusive" => false)
JSON.lower(r::SurrealRange) = Dict("start" => r.start, "stop" => r.stop)
